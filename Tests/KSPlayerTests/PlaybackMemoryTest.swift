import AVFoundation
import Foundation
@testable import KSPlayer
import Libavutil
import Libavformat
import Metal
import XCTest

final class PlaybackMemoryTest: XCTestCase {
    func test4KTenBitPreviewRespectsRequestedSizeAndBoundsCachedImages() throws {
        var input: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&input) }
        let frame = try XCTUnwrap(input)
        frame.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        frame.pointee.width = 3840
        frame.pointee.height = 2160
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
        for plane in 0 ..< 3 {
            memset(Array(tuple: frame.pointee.data)[plane], 0,
                   Int(Array(tuple: frame.pointee.linesize)[plane]) * (plane == 0 ? 2160 : 1080))
        }
        let converter = VideoSwresample(dstWidth: 240, dstHeight: 135, isDovi: false)
        defer { converter.shutdown() }
        var images = [CGImage]()
        for _ in 0 ..< 100 {
            let image = try autoreleasepool { () throws -> CGImage in
                let buffer = try XCTUnwrap(converter.transfer(frame: frame.pointee))
                // Fail before generating a full-resolution cache on regression.
                guard buffer.width == 240, buffer.height == 135 else {
                    XCTFail("10-bit thumbnail resizing was bypassed: \(buffer.width)x\(buffer.height)")
                    throw NSError(domain: "KSPlayerTests", code: 10)
                }
                return try XCTUnwrap(buffer.cgImage())
            }
            images.append(image)
        }
        XCTAssertEqual(images.count, 100)
        XCTAssertLessThanOrEqual(images.reduce(0) { $0 + $1.bytesPerRow * $1.height }, 32 * 1024 * 1024)
    }

    func test4KSoftwareFramesReleaseMetalBuffersAfterQueueShutdown() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("The 4K software-frame converter requires Metal")
        }
        var input: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&input) }
        let frame = try XCTUnwrap(input)
        frame.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        frame.pointee.width = 3840
        frame.pointee.height = 2160
        frame.pointee.color_primaries = AVCOL_PRI_BT2020
        frame.pointee.colorspace = AVCOL_SPC_BT2020_NCL
        frame.pointee.color_trc = AVCOL_TRC_SMPTE2084
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
        for plane in 0 ..< 3 {
            let data = Array(tuple: frame.pointee.data)[plane]
            let stride = Array(tuple: frame.pointee.linesize)[plane]
            memset(data, 0, Int(stride) * (plane == 0 ? 2160 : 1080))
        }
        let converter = VideoSwresample(fps: 24, isDovi: false)
        defer { converter.shutdown() }
        let queue = CircularBuffer<VideoVTBFrame>(initialCapacity: 4, expanding: false)
        var references = [WeakVideoFrame]()
        for _ in 0 ..< 128 {
            try autoreleasepool {
                if queue.count == 3 { _ = queue.pop() }
                let output = try XCTUnwrap(try converter.change(avframe: frame) as? VideoVTBFrame)
                XCTAssertEqual(output.corePixelBuffer?.width, 3840)
                XCTAssertEqual(output.corePixelBuffer?.textures().count, 3)
                references.append(WeakVideoFrame(output))
                queue.push(output)
            }
            XCTAssertEqual(references.filter { $0.value != nil }.count, min(references.count, 3))
        }
        queue.shutdown()
        XCTAssertTrue(references.allSatisfy { $0.value == nil })
    }

    func test4KVideoToolboxFramesKeepOnlyQueuedPixelBufferReferences() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                         nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        var input: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&input) }
        let frame = try XCTUnwrap(input)
        frame.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        // Borrow the CV buffer just as FFmpeg exposes it in data[3]. The test
        // owns the original reference; only converted queued frames may add one.
        frame.pointee.data.3 = Unmanaged.passUnretained(buffer).toOpaque().assumingMemoryBound(to: UInt8.self)
        let baseline = CFGetRetainCount(buffer)
        let converter = VideoSwresample(fps: 24, isDovi: true)
        defer { converter.shutdown() }
        let queue = CircularBuffer<VideoVTBFrame>(initialCapacity: 4, expanding: false)
        for _ in 0 ..< 128 {
            try autoreleasepool {
                if queue.count == 3 { _ = queue.pop() }
                let output = try XCTUnwrap(try converter.change(avframe: frame) as? VideoVTBFrame)
                XCTAssertTrue(output.corePixelBuffer?.cvPixelBuffer === buffer)
                queue.push(output)
            }
            XCTAssertEqual(CFGetRetainCount(buffer), baseline + queue.count)
        }
        queue.shutdown()
        XCTAssertEqual(CFGetRetainCount(buffer), baseline)
    }

    @MainActor
    func testShutdownReleasesItemsEvenWhenNoReadOperationWasStarted() async {
        var references = [WeakPlayerItem]()
        for _ in 0 ..< 256 {
            autoreleasepool {
                let item = MEPlayerItem(url: URL(fileURLWithPath: "/unused-memory-fixture"), options: KSOptions())
                references.append(WeakPlayerItem(item))
                item.shutdown()
            }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while references.contains(where: { $0.value != nil }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(references.allSatisfy { $0.value == nil }, "shutdown must break the close-operation retain cycle")
    }

    @MainActor
    func testDisplayBackpressureStopsFrameConsumptionAndResumes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("MetalPlayView requires a Metal device; display enqueue is tested independently")
        }
        let output = MetalPlayView(options: KSOptions())
        defer { output.invalidate() }
        let display = MemoryDisplayView(frame: .zero)
        output.displayView = display
        let source = MemoryVideoSource(pixelBuffer: try makePixelBuffer())
        output.renderSource = source
        output.readNextFrame()
        XCTAssertEqual(source.framesRequested, 1)
        XCTAssertEqual(source.videoTimes.count, 1)
        XCTAssertEqual(display.testLayer.enqueuedCount, 1)

        display.testLayer.ready = false
        for _ in 0 ..< 1000 { output.readNextFrame() }
        XCTAssertEqual(source.framesRequested, 1)
        XCTAssertEqual(source.videoTimes.count, 1)
        XCTAssertEqual(display.testLayer.enqueuedCount, 1)

        display.testLayer.ready = true
        output.readNextFrame()
        XCTAssertEqual(source.framesRequested, 2)
        XCTAssertEqual(source.videoTimes.count, 2)
        XCTAssertEqual(display.testLayer.enqueuedCount, 2)
    }

    @MainActor
    func testBusyDisplayRejectsFramesAndRecoversBeforeCheckingReadiness() throws {
        let display = MemoryDisplayView(frame: .zero)
        let pixelBuffer = try makePixelBuffer()
        let format = try XCTUnwrap(pixelBuffer.formatDescription)
        display.testLayer.ready = false
        for _ in 0 ..< 1000 {
            XCTAssertFalse(display.enqueue(imageBuffer: pixelBuffer, formatDescription: format, time: .zero))
        }
        XCTAssertEqual(display.testLayer.enqueuedCount, 0)
        display.testLayer.needsFlush = true
        XCTAssertTrue(display.enqueue(imageBuffer: pixelBuffer, formatDescription: format, time: .zero))
        XCTAssertEqual(display.testLayer.flushedCount, 1)
        XCTAssertEqual(display.testLayer.enqueuedCount, 1)
    }

    func testAttachedColorSpaceReadsDoNotAccumulateReferences() throws {
        let pixelBuffer = try makePixelBuffer()
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        pixelBuffer.colorspace = colorSpace
        let baseline = CFGetRetainCount(colorSpace)
        for _ in 0 ..< 1000 {
            autoreleasepool {
                XCTAssertTrue(pixelBuffer.colorspace === colorSpace)
            }
        }
        XCTAssertEqual(CFGetRetainCount(colorSpace), baseline)
    }

    private func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testPacketBytesSurviveGrowthWrapAndRejectedPop() {
        let queue = CircularBuffer<MemoryItem>(initialCapacity: 2)
        queue.push(MemoryItem(size: 3))
        queue.push(MemoryItem(size: 5))
        XCTAssertEqual(queue.byteSize, 8)
        XCTAssertNil(queue.pop(where: { _, _ in false }))
        XCTAssertEqual(queue.byteSize, 8)
        XCTAssertEqual(queue.pop()?.size, 3)
        for _ in 0 ..< 100 { queue.push(MemoryItem(size: 7)) }
        XCTAssertEqual(queue.byteSize, 705)
        while queue.pop() != nil {}
        XCTAssertEqual(queue.byteSize, 0)
    }

    func testSubtitleSearchReleasesSkippedBytesAndObjects() {
        let queue = CircularBuffer<MemoryItem>(initialCapacity: 4)
        var skipped: MemoryItem? = MemoryItem(size: 10)
        weak var reference = skipped
        queue.push(skipped!)
        skipped = nil
        queue.push(MemoryItem(size: 20))
        queue.push(MemoryItem(size: 30))
        XCTAssertEqual(queue.search(where: { $0.size == 20 }).count, 1)
        XCTAssertNil(reference)
        XCTAssertEqual(queue.byteSize, 30)
        queue.flush()
        XCTAssertEqual(queue.byteSize, 0)
        queue.push(MemoryItem(size: 40))
        queue.shutdown()
        queue.push(MemoryItem(size: 50))
        XCTAssertEqual(queue.byteSize, 0)
    }

    func testPacketBudgetIncludesAudioVideoAndNextLoop() {
        let options = KSOptions()
        let audio = AsyncPlayerItemTrack<AudioFrame>(mediaType: .audio, frameCapacity: 4, options: options)
        let video = AsyncPlayerItemTrack<VideoVTBFrame>(mediaType: .video, frameCapacity: 4, options: options)
        func packet(_ size: Int32) -> Packet {
            let packet = Packet()
            packet.size = size
            return packet
        }
        audio.putPacket(packet: packet(100))
        video.putPacket(packet: packet(500))
        video.isLoopModel = true
        video.putPacket(packet: packet(700))
        XCTAssertEqual(audio.packetBufferSize + video.packetBufferSize, 1300)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for _ in 0 ..< 2 {
            audio.outputRenderQueue.push(AudioFrame(dataSize: 32, audioFormat: format))
            video.outputRenderQueue.push(VideoVTBFrame(fps: 24, isDovi: false))
        }
        options.preferredForwardBufferDuration = 100
        options.maxBufferSize = 1301
        XCTAssertFalse(options.playable(capacitys: [audio, video], isFirst: false, isSeek: true).isPlayable)
        options.maxBufferSize = 1300
        XCTAssertTrue(options.playable(capacitys: [audio, video], isFirst: false, isSeek: true).isPlayable)
        video.packetQueue.flush()
        XCTAssertEqual(video.packetBufferSize, 700)
    }

    func testFilterHardwareReferencesStayBoundedAcrossFramesAndReconfiguration() throws {
        var device: UnsafeMutablePointer<AVBufferRef>? = try XCTUnwrap(av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX))
        var frames: UnsafeMutablePointer<AVBufferRef>? = try XCTUnwrap(av_hwframe_ctx_alloc(device))
        defer {
            av_buffer_unref(&frames)
            av_buffer_unref(&device)
        }
        let context = UnsafeMutableRawPointer(try XCTUnwrap(frames?.pointee.data)).assumingMemoryBound(to: AVHWFramesContext.self)
        context.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        context.pointee.sw_format = AV_PIX_FMT_NV12
        context.pointee.width = 64
        context.pointee.height = 64
        let framesBaseline = av_buffer_get_ref_count(frames)
        let deviceBaseline = av_buffer_get_ref_count(device)
        let options = KSOptions()
        options.videoFilters = ["null"]
        var filter: MEFilter? = MEFilter(timebase: Timebase(num: 1, den: 24), isAudio: false, nominalFrameRate: 24, options: options)
        var stableReferences: Int32?
        for index in 0 ..< 100 {
            var frame: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
            defer { av_frame_free(&frame) }
            let input = try XCTUnwrap(frame)
            // A software image with a reference-counted context exercises the
            // filter's ownership without starting a platform decoder session.
            input.pointee.format = AV_PIX_FMT_NV12.rawValue
            input.pointee.width = index < 50 ? 64 : 32
            input.pointee.height = 64
            input.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)
            input.pointee.pts = Int64(index)
            XCTAssertEqual(av_frame_get_buffer(input, 0), 0)
            input.pointee.hw_frames_ctx = av_buffer_ref(frames)
            var outputCount = 0
            filter?.filter(options: options, inputFrame: input) { _ in outputCount += 1 }
            XCTAssertEqual(outputCount, 1)
            av_frame_unref(input)
            let count = av_buffer_get_ref_count(frames)
            if let stableReferences { XCTAssertEqual(count, stableReferences) }
            stableReferences = count
        }
        filter = nil
        XCTAssertEqual(av_buffer_get_ref_count(frames), framesBaseline)
        XCTAssertEqual(av_buffer_get_ref_count(device), deviceBaseline)
    }

    @MainActor
    func testVideoToolboxSubmissionWaitsForBlockedOutput() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try assertVideoToolboxBackpressure(url: url)
    }

    private func assertVideoToolboxBackpressure(url: URL) throws {
        var context: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&context, url.path, nil, nil), 0)
        defer { avformat_close_input(&context) }
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        let stream = try XCTUnwrap(context?.pointee.streams[0])
        let asset = try XCTUnwrap(FFmpegAssetTrack(stream: stream))
        let options = KSOptions()
        guard let session = DecompressionSession(assetTrack: asset, options: options) else {
            #if targetEnvironment(simulator)
            throw XCTSkip("The iOS Simulator has no VideoToolbox decoder for this fixture; run this test on a device")
            #else
            XCTFail("VideoToolbox could not create the fixture decoder")
            return
            #endif
        }
        let decoder = VideoToolboxDecode(options: options, session: session)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let formatContext = try XCTUnwrap(context)
        finished.enter()
        DispatchQueue.global().async {
            defer { finished.leave() }
            while true {
                let packet = Packet()
                guard av_read_frame(formatContext, packet.corePacket) >= 0 else { break }
                packet.assetTrack = asset
                decoder.decodeFrame(from: packet) { result in
                    if case .success = result {
                        entered.signal()
                        release.wait()
                        completed.signal()
                    }
                }
                if completed.wait(timeout: .now()) == .success { break }
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        // A callback blocked by a full frame queue must stop further submission.
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        // Release all potential callbacks even when testing the broken version.
        for _ in 0 ..< 30 { release.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        decoder.shutdown()
    }

    @MainActor
    func testReaderBudgetStillAppliesWhenMainThreadDoesNotRunCapacityTimer() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let options = KSOptions()
        options.hardwareDecode = false
        options.maxBufferSize = 1
        let item = MEPlayerItem(url: url, options: options)
        let delegate = MemoryDelegate()
        item.delegate = delegate
        defer { item.shutdown() }
        item.prepareToPlay()
        XCTAssertEqual(delegate.opened.wait(timeout: .now() + 5), .success)
        XCTAssertNil(delegate.error)
        assertReaderBackpressure(item: item)
        let completion = expectation(description: "budget wait can seek")
        item.seek(time: 0) { success in
            XCTAssertTrue(success)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 5)
    }

    private func assertReaderBackpressure(item: MEPlayerItem) {
        // No rendering consumes the 16 decoded frames. The reader must then
        // keep at most one compressed packet, even without the main-run-loop timer.
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            let buffered = item.packetBufferSize
            Thread.sleep(forTimeInterval: 0.2)
            if buffered > 0, item.packetBufferSize == buffered { return }
        }
        XCTFail("reader did not stop at its packet budget")
    }
}

private final class WeakVideoFrame {
    weak var value: VideoVTBFrame?
    init(_ value: VideoVTBFrame) { self.value = value }
}

private final class WeakPlayerItem {
    weak var value: MEPlayerItem?
    init(_ value: MEPlayerItem) { self.value = value }
}

@MainActor
private final class MemoryDisplayView: AVSampleBufferDisplayView {
    let testLayer = MemoryDisplayLayer()
    override var displayLayer: AVSampleBufferDisplayLayer { testLayer }
}

@MainActor
private final class MemoryDisplayLayer: AVSampleBufferDisplayLayer {
    var ready = true
    var needsFlush = false
    var enqueuedCount = 0
    var flushedCount = 0
    override var isReadyForMoreMediaData: Bool { ready }
    override var requiresFlushToResumeDecoding: Bool { needsFlush }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) { enqueuedCount += 1 }
    override func flush() {
        flushedCount += 1
        needsFlush = false
        ready = true
    }
}

private final class MemoryVideoSource: OutputRenderSourceDelegate {
    let pixelBuffer: CVPixelBuffer
    var framesRequested = 0
    var videoTimes = [CMTime]()

    init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        framesRequested += 1
        let frame = VideoVTBFrame(fps: 24, isDovi: false)
        frame.timebase = Timebase(num: 1, den: 24)
        frame.timestamp = Int64(framesRequested)
        frame.corePixelBuffer = pixelBuffer
        return frame
    }

    func getAudioOutputRender() -> AudioFrame? { nil }
    func setAudio(time: CMTime, position: Int64) {}
    func setVideo(time: CMTime, position: Int64) { videoTimes.append(time) }
}

private final class MemoryDelegate: MEPlayerDelegate {
    let opened = DispatchSemaphore(value: 0)
    var error: NSError?

    func sourceDidOpened(source: MEPlayerItem) { opened.signal() }
    func sourceDidFailed(source: MEPlayerItem, error: NSError?) {
        self.error = error
        opened.signal()
    }

    func sourceDidChange(source: MEPlayerItem, loadingState: LoadingState) {}
    func sourceDidFinished(source: MEPlayerItem) {}
    func sourceDidChange(source: MEPlayerItem, oldBitRate: Int64, newBitrate: Int64) {}
}

private final class MemoryItem: ObjectQueueItem {
    var timebase = Timebase(num: 1, den: 1)
    var timestamp: Int64 = 0
    var duration: Int64 = 0
    var position: Int64 = 0
    var size: Int32

    init(size: Int32) {
        self.size = size
    }
}
