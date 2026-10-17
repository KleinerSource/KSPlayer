//
//  ThumbnailController.swift
//
//
//  Created by kintan on 12/27/23.
//

import AVFoundation
import Foundation
import Libavcodec
import Libavformat
#if canImport(UIKit)
import UIKit
#endif
public struct FFThumbnail {
    public let image: UIImage
    public let time: TimeInterval

    var cgImage: CGImage? {
        #if canImport(UIKit)
        image.cgImage
        #else
        var rect = CGRect.zero
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}

public protocol ThumbnailControllerDelegate: AnyObject {
    func didUpdate(thumbnails: [FFThumbnail], forFile file: URL, withProgress: Int)
}

public class ThumbnailController {
    public weak var delegate: ThumbnailControllerDelegate?
    private let thumbnailCount: Int
    public init(thumbnailCount: Int = 100) {
        self.thumbnailCount = max(1, thumbnailCount)
    }

    public func generateThumbnail(for url: URL, at time: TimeInterval? = nil, thumbWidth: Int32 = 240,
                                  onUpdate: (([FFThumbnail]) -> Void)? = nil) async throws -> [FFThumbnail]
    {
        if let time, !time.isFinite || time < 0 {
            throw NSError(description: "Invalid thumbnail time")
        }
        let cancellation = ThumbnailIOCancellation()
        let operation = Task {
            try await getPeeks(for: url, at: time, thumbWidth: thumbWidth, cancellation: cancellation, onUpdate: onUpdate)
        }
        return try await withTaskCancellationHandler(operation: {
            try await operation.value
        }, onCancel: {
            cancellation.cancel()
            operation.cancel()
        })
    }

    private func getPeeks(for url: URL, at time: TimeInterval?, thumbWidth: Int32,
                          cancellation: ThumbnailIOCancellation,
                          onUpdate: (([FFThumbnail]) -> Void)? = nil) async throws -> [FFThumbnail]
    {
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var thumbnails = [FFThumbnail]()
        var formatCtx = avformat_alloc_context()
        guard let input = formatCtx else { throw NSError(errorCode: .formatCreate) }
        input.pointee.interrupt_callback = AVIOInterruptCB(
            callback: { context in
                guard let context else { return 0 }
                return Unmanaged<ThumbnailIOCancellation>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
            },
            opaque: Unmanaged.passUnretained(cancellation).toOpaque()
        )
        defer {
            avformat_close_input(&formatCtx)
            withExtendedLifetime(cancellation) {}
        }
        var result = avformat_open_input(&formatCtx, urlString, nil, nil)
        guard result == 0, let formatCtx else {
            throw NSError(errorCode: .formatOpenInput, avErrorCode: result)
        }
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            throw NSError(errorCode: .formatFindStreamInfo, avErrorCode: result)
        }
        var videoStreamIndex = -1
        for i in 0 ..< Int32(formatCtx.pointee.nb_streams) {
            if formatCtx.pointee.streams[Int(i)]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                videoStreamIndex = Int(i)
                break
            }
        }
        guard videoStreamIndex >= 0, let videoStream = formatCtx.pointee.streams[videoStreamIndex] else {
            throw NSError(description: "No video stream")
        }

        let videoAvgFrameRate = videoStream.pointee.avg_frame_rate
        if videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0 {
            throw NSError(description: "Avg frame rate = 0, ignore")
        }
        var codecContext = try videoStream.pointee.codecpar.pointee.createContext(options: nil)
        defer {
            var codecContext: UnsafeMutablePointer<AVCodecContext>? = codecContext
            avcodec_free_context(&codecContext)
        }
        guard thumbWidth > 0, codecContext.pointee.width > 0, codecContext.pointee.height > 0 else {
            throw NSError(description: "Invalid video dimensions")
        }
        let thumbHeight = thumbWidth * codecContext.pointee.height / codecContext.pointee.width
        let reScale = VideoSwresample(dstWidth: thumbWidth, dstHeight: thumbHeight, isDovi: false)
        defer { reScale.shutdown() }
//        let duration = formatCtx.pointee.duration
        // 因为是针对视频流来进行seek。所以不能直接取formatCtx的duration
        guard formatCtx.pointee.duration > 0, videoStream.pointee.time_base.den != 0 else {
            throw NSError(description: "Invalid video duration")
        }
        let duration = av_rescale_q(formatCtx.pointee.duration,
                                    AVRational(num: 1, den: AV_TIME_BASE), videoStream.pointee.time_base)
        guard duration > 0 else {
            throw NSError(description: "Invalid video duration")
        }
        let sampleCount = time == nil ? max(1, min(thumbnailCount, Int(min(Int64(Int.max), duration)))) : 1
        let interval = max(1, duration / Int64(sampleCount))
        let startTime = videoStream.pointee.start_time == Int64.min ? 0 : videoStream.pointee.start_time
        let target = time.map {
            av_rescale_q(Int64(min(max(0, $0), Double(formatCtx.pointee.duration) / Double(AV_TIME_BASE)) * Double(AV_TIME_BASE)),
                         AVRational(num: 1, den: AV_TIME_BASE), videoStream.pointee.time_base) + startTime
        }
        var packet = AVPacket()
        defer { av_packet_unref(&packet) }
        let timeBase = Timebase(videoStream.pointee.time_base)
        var frame = av_frame_alloc()
        defer {
            av_frame_free(&frame)
        }
        guard let frame else {
            throw NSError(description: "can not av_frame_alloc")
        }
        for i in 0 ..< sampleCount {
            try Task.checkCancellation()
            let seek_pos = target ?? (interval * Int64(i) + startTime)
            avcodec_flush_buffers(codecContext)
            result = av_seek_frame(formatCtx, Int32(videoStreamIndex), seek_pos, AVSEEK_FLAG_BACKWARD)
            guard result == 0 else {
                return thumbnails
            }
            avcodec_flush_buffers(codecContext)
            while av_read_frame(formatCtx, &packet) >= 0 {
                defer { av_packet_unref(&packet) }
                try Task.checkCancellation()
                if packet.stream_index == Int32(videoStreamIndex) {
                    if avcodec_send_packet(codecContext, &packet) < 0 {
                        break
                    }
                    let ret = avcodec_receive_frame(codecContext, frame)
                    if ret < 0 {
                        if ret == -EAGAIN {
                            continue
                        } else {
                            break
                        }
                    }
                    let currentTimeStamp = frame.pointee.best_effort_timestamp
                    if let target, currentTimeStamp < target { continue }
                    let image = autoreleasepool {
                        reScale.transfer(frame: frame.pointee)?.cgImage().map { UIImage(cgImage: $0) }
                    }
                    if let image {
                        let thumbnail = FFThumbnail(image: image, time: timeBase.cmtime(for: currentTimeStamp).seconds)
                        thumbnails.append(thumbnail)
                        delegate?.didUpdate(thumbnails: thumbnails, forFile: url, withProgress: (i + 1) * 100 / sampleCount)
                        onUpdate?(thumbnails)
                    }
                    break
                }
            }
        }
        try Task.checkCancellation()
        return thumbnails
    }
}

private final class ThumbnailIOCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
