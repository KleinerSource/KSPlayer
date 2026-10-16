//
//  FFmpegDecode.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//

import AVFoundation
import Foundation
import Libavcodec

class FFmpegDecode: DecodeProtocol {
    private let options: KSOptions
    private var coreFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var initializationError: Error?
    private var bestEffortTimestamp = Int64(0)
    private let frameChange: FrameChange
    private let filter: MEFilter
    private let seekByBytes: Bool
    required init(assetTrack: FFmpegAssetTrack, options: KSOptions) {
        self.options = options
        seekByBytes = assetTrack.seekByBytes
        do {
            codecContext = try assetTrack.createContext(options: options)
        } catch {
            initializationError = error
            KSLog(error as CustomStringConvertible)
        }
        codecContext?.pointee.time_base = assetTrack.timebase.rational
        filter = MEFilter(timebase: assetTrack.timebase, isAudio: assetTrack.mediaType == .audio, nominalFrameRate: assetTrack.nominalFrameRate, options: options)
        if assetTrack.mediaType == .video {
            frameChange = VideoSwresample(fps: assetTrack.nominalFrameRate, isDovi: assetTrack.dovi != nil)
        } else {
            frameChange = AudioSwresample(audioDescriptor: assetTrack.audioDescriptor!)
        }
    }

    func decodeFrame(from packet: Packet, completionHandler: @escaping (Result<MEFrame, Error>) -> Void) {
        guard let codecContext else {
            completionHandler(.failure(initializationError ?? NSError(errorCode: .codecContextCreate)))
            return
        }
        let sendResult = avcodec_send_packet(codecContext, packet.corePacket)
        updateDecoder(assetTrack: packet.assetTrack, context: codecContext)
        var retryPacket = sendResult == AVError.tryAgain.code
        if sendResult < 0, !retryPacket, sendResult != AVError.eof.code {
            completionHandler(.failure(NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: sendResult)))
            return
        }

        // 需要avcodec_send_packet之后，properties的值才会变成FF_CODEC_PROPERTY_CLOSED_CAPTIONS
        if packet.assetTrack.mediaType == .video {
            if Int32(codecContext.pointee.properties) & FF_CODEC_PROPERTY_CLOSED_CAPTIONS != 0, packet.assetTrack.closedCaptionsTrack == nil {
                var codecpar = AVCodecParameters()
                codecpar.codec_type = AVMEDIA_TYPE_SUBTITLE
                codecpar.codec_id = AV_CODEC_ID_EIA_608
                if let subtitleAssetTrack = FFmpegAssetTrack(codecpar: codecpar) {
                    subtitleAssetTrack.name = "Closed Captions"
                    subtitleAssetTrack.startTime = packet.assetTrack.startTime
                    subtitleAssetTrack.timebase = packet.assetTrack.timebase
                    let subtitle = SyncPlayerItemTrack<SubtitleFrame>(mediaType: .subtitle, frameCapacity: 255, options: options)
                    subtitleAssetTrack.subtitle = subtitle
                    packet.assetTrack.closedCaptionsTrack = subtitleAssetTrack
                    subtitle.decode()
                }
            }
        }

        while true {
            let result = avcodec_receive_frame(codecContext, coreFrame)
            // Format negotiation can first happen inside receive_frame. Record
            // the selected backend even when that first hardware frame fails.
            updateDecoder(assetTrack: packet.assetTrack, context: codecContext)
            if result == 0, let inputFrame = coreFrame {
                if packet.assetTrack.mediaType == .video {
                    if inputFrame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                        packet.assetTrack.actualDecoder = "VideoToolbox (FFmpeg)"
                    } else if let name = codecContext.pointee.codec?.pointee.name {
                        packet.assetTrack.actualDecoder = String(cString: name)
                    }
                }
                let profile = packet.assetTrack.dovi.map { Int($0.dv_profile) }
                let inputMetadata = packet.assetTrack.mediaType == .video ? VideoDisplayMetadata(frame: inputFrame, profile: profile) : nil
                let inputPTS = inputFrame.pointee.pts

                // filter之后，side_data信息会丢失，所以放在这里
                if inputFrame.pointee.nb_side_data > 0 {
                    for i in 0 ..< inputFrame.pointee.nb_side_data {
                        if let sideData = inputFrame.pointee.side_data[Int(i)]?.pointee {
                            if sideData.type == AV_FRAME_DATA_A53_CC {
                                if let closedCaptionsTrack = packet.assetTrack.closedCaptionsTrack,
                                   let subtitle = closedCaptionsTrack.subtitle
                                {
                                    let closedCaptionsPacket = Packet()
                                    if let corePacket = packet.corePacket {
                                        closedCaptionsPacket.corePacket?.pointee.pts = corePacket.pointee.pts
                                        closedCaptionsPacket.corePacket?.pointee.dts = corePacket.pointee.dts
                                        closedCaptionsPacket.corePacket?.pointee.pos = corePacket.pointee.pos
                                        closedCaptionsPacket.corePacket?.pointee.time_base = corePacket.pointee.time_base
                                        closedCaptionsPacket.corePacket?.pointee.stream_index = corePacket.pointee.stream_index
                                    }
                                    closedCaptionsPacket.corePacket?.pointee.flags |= AV_PKT_FLAG_KEY
                                    closedCaptionsPacket.corePacket?.pointee.size = Int32(sideData.size)
                                    let buffer = av_buffer_ref(sideData.buf)
                                    closedCaptionsPacket.corePacket?.pointee.data = buffer?.pointee.data
                                    closedCaptionsPacket.corePacket?.pointee.buf = buffer
                                    closedCaptionsPacket.assetTrack = closedCaptionsTrack
                                    subtitle.putPacket(packet: closedCaptionsPacket)
                                }
                            } else if sideData.type == AV_FRAME_DATA_SEI_UNREGISTERED {
                                let size = sideData.size
                                if size > AV_UUID_LEN {
                                    let str = String(cString: sideData.data.advanced(by: Int(AV_UUID_LEN)))
                                    options.sei(string: str)
                                }
                            }
                        }
                    }
                }

                filter.filter(options: options, inputFrame: inputFrame) { avframe in
                    do {
                        var frame = try frameChange.change(avframe: avframe)
                        if let videoFrame = frame as? VideoVTBFrame, let pixelBuffer = videoFrame.corePixelBuffer {
                            // Use the filter's output AVFrame, not the most recent
                            // input frame: buffering filters may return older PTS.
                            let metadata = (avframe.pointee.pts == inputPTS ? inputMetadata : nil) ?? VideoDisplayMetadata(frame: avframe, profile: profile)
                            videoFrame.doviMetadata = metadata.dovi
                            videoFrame.doviProfile = profile ?? metadata.dovi?.profile
                            videoFrame.rpuData = metadata.rpu
                            videoFrame.edrMetaData = metadata.edr
                            videoFrame.contentPeakNits = metadata.peakNits
                            if videoFrame.doviProfile == 5, metadata.dovi == nil {
                                throw NSError(errorCode: .codecVideoReceiveFrame, userInfo: [NSLocalizedDescriptionKey: "Dolby Vision Profile 5 frame has no usable RPU metadata"])
                            }
                            pixelBuffer.yCbCrMatrix = avframe.pointee.colorspace.ycbcrMatrix ?? packet.assetTrack.codecpar.color_space.ycbcrMatrix
                            pixelBuffer.colorPrimaries = avframe.pointee.color_primaries.colorPrimaries ?? packet.assetTrack.codecpar.color_primaries.colorPrimaries
                            pixelBuffer.transferFunction = avframe.pointee.color_trc.transferFunction ?? packet.assetTrack.codecpar.color_trc.transferFunction
                            pixelBuffer.colorspace = KSOptions.colorSpace(ycbcrMatrix: pixelBuffer.yCbCrMatrix, transferFunction: pixelBuffer.transferFunction)
                            if let cv = pixelBuffer.cvPixelBuffer {
                                let fullRange = avframe.pointee.color_range == AVCOL_RANGE_JPEG ||
                                    (avframe.pointee.color_range == AVCOL_RANGE_UNSPECIFIED && packet.assetTrack.codecpar.color_range == AVCOL_RANGE_JPEG)
                                CVBufferSetAttachment(cv, kCMFormatDescriptionExtension_FullRangeVideo, NSNumber(value: fullRange), .shouldPropagate)
                                if var displayData = metadata.edr.displayData {
                                    let data = Data(bytes: &displayData, count: MemoryLayout<MasteringDisplayMetadata>.size)
                                    CVBufferSetAttachment(cv, kCVImageBufferMasteringDisplayColorVolumeKey, data as CFData, .shouldPropagate)
                                } else { CVBufferRemoveAttachment(cv, kCVImageBufferMasteringDisplayColorVolumeKey) }
                                if var contentData = metadata.edr.contentData {
                                    let data = Data(bytes: &contentData, count: MemoryLayout<ContentLightMetadata>.size)
                                    CVBufferSetAttachment(cv, kCVImageBufferContentLightLevelInfoKey, data as CFData, .shouldPropagate)
                                } else { CVBufferRemoveAttachment(cv, kCVImageBufferContentLightLevelInfoKey) }
                            }
                            if let pixelBuffer = pixelBuffer as? PixelBuffer {
                                pixelBuffer.formatDescription = packet.assetTrack.formatDescription
                            }
                        }
                        frame.timebase = filter.timebase
                        // frame.timebase = Timebase(avframe.pointee.time_base)
                        frame.size = packet.size
                        frame.position = packet.position
                        frame.duration = avframe.pointee.duration
                        if frame.duration == 0, avframe.pointee.sample_rate != 0, frame.timebase.num != 0 {
                            frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
                        }
                        var timestamp = avframe.pointee.best_effort_timestamp
                        if timestamp < 0 {
                            timestamp = avframe.pointee.pts
                        }
                        if timestamp < 0 {
                            timestamp = avframe.pointee.pkt_dts
                        }
                        if timestamp < 0 {
                            timestamp = bestEffortTimestamp
                        }
                        frame.timestamp = timestamp
                        bestEffortTimestamp = timestamp &+ frame.duration
                        completionHandler(.success(frame))
                    } catch {
                        completionHandler(.failure(error))
                    }
                }
            } else {
                if result == AVError.eof.code {
                    avcodec_flush_buffers(codecContext)
                    break
                } else if result == AVError.tryAgain.code {
                    if retryPacket {
                        retryPacket = false
                        let retryResult = avcodec_send_packet(codecContext, packet.corePacket)
                        updateDecoder(assetTrack: packet.assetTrack, context: codecContext)
                        if retryResult == 0 { continue }
                        if retryResult != AVError.tryAgain.code, retryResult != AVError.eof.code {
                            completionHandler(.failure(NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: retryResult)))
                        }
                    }
                    break
                } else {
                    let error = NSError(errorCode: packet.assetTrack.mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, avErrorCode: result)
                    KSLog(error)
                    completionHandler(.failure(error))
                    break
                }
            }
        }
    }

    private func updateDecoder(assetTrack: FFmpegAssetTrack, context: UnsafeMutablePointer<AVCodecContext>) {
        guard assetTrack.mediaType == .video else { return }
        if context.pointee.pix_fmt == AV_PIX_FMT_VIDEOTOOLBOX || context.pointee.hw_device_ctx != nil {
            // This fork only installs a VideoToolbox hardware-device context.
            // Do not infer hardware use from the user's preference: negotiation
            // may select a software format, or fail before producing any frame.
            assetTrack.actualDecoder = "VideoToolbox (FFmpeg)"
        } else if let name = context.pointee.codec?.pointee.name {
            assetTrack.actualDecoder = String(cString: name)
        }
    }

    func doFlushCodec() {
        bestEffortTimestamp = Int64(0)
        // seek之后要清空下，不然解码可能还会有缓存，导致返回的数据是之前seek的。
        avcodec_flush_buffers(codecContext)
    }

    func shutdown() {
        av_frame_free(&coreFrame)
        avcodec_free_context(&codecContext)
        frameChange.shutdown()
    }

    func decode() {
        bestEffortTimestamp = Int64(0)
        if codecContext != nil {
            avcodec_flush_buffers(codecContext)
        }
    }
}
