import AVFoundation
import Foundation
@testable import KSPlayer
import Libavutil
import Libavformat
import XCTest

final class PlaybackMemoryTest: XCTestCase {
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
