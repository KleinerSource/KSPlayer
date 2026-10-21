@testable import KSPlayer
import FFmpegKit
import Libavutil
import XCTest

final class PlaybackRecoveryTest: XCTestCase {
    func testIODeadlineDoesNotTurnSuccessfulPacketsOrEOFIntoTimeout() {
        XCTAssertEqual(MEPlayerItem.completedIOResult(0, deadlineExpired: true), 0)
        XCTAssertEqual(MEPlayerItem.completedIOResult(AVError.eof.code, deadlineExpired: true), AVError.eof.code)
        XCTAssertEqual(MEPlayerItem.completedIOResult(AVError.invalidData.code, deadlineExpired: true), AVError.invalidData.code)
        XCTAssertEqual(MEPlayerItem.completedIOResult(AVError.exit.code, deadlineExpired: false), AVError.exit.code)
        XCTAssertEqual(MEPlayerItem.completedIOResult(AVError.exit.code, deadlineExpired: true), -Int32(ETIMEDOUT))
    }

    func testLogsRedactCredentialsAndStreamKeys() {
        let originalLogger = KSOptions.logger
        let originalLevel = KSOptions.logLevel
        defer { KSOptions.logger = originalLogger; KSOptions.logLevel = originalLevel }
        let logger = RecordingLog()
        KSOptions.logger = logger
        KSOptions.logLevel = .debug
        KSLog("srt://name:secret@example.invalid:9000?passphrase=private")
        KSLog("Sending play command for 'private-stream-key'")
        KSLog("Authorization: Basic private-token")
        XCTAssertEqual(logger.messages.count, 3)
        XCTAssertFalse(logger.messages.joined().contains("secret"))
        XCTAssertFalse(logger.messages.joined().contains("private"))
    }

    func testReconnectsHaveAFiniteIndependentBudget() {
        var recovery = PlaybackRecovery()
        let error = NSError(errorCode: .readFrame, avErrorCode: -Int32(ETIMEDOUT))
        XCTAssertEqual(recovery.next(error: error, streaming: true, hardware: true), .reconnect(1))
        XCTAssertEqual(recovery.next(error: error, streaming: true, hardware: true), .reconnect(2))
        XCTAssertEqual(recovery.next(error: error, streaming: true, hardware: true), .reconnect(4))
        XCTAssertNil(recovery.next(error: error, streaming: true, hardware: true))
        let hardware = NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: Int32(swift_AVERROR_EXTERNAL))
        XCTAssertEqual(recovery.next(error: hardware, streaming: true, hardware: true), .softwareDecode)
        XCTAssertNil(recovery.next(error: hardware, streaming: true, hardware: true))
    }

    func testFileAndAuthorizationFailuresAreNotRetried() {
        var recovery = PlaybackRecovery()
        XCTAssertNil(recovery.next(error: NSError(errorCode: .readFrame, avErrorCode: -Int32(ETIMEDOUT)),
                                   streaming: false, hardware: true))
        XCTAssertNil(recovery.next(error: NSError(errorCode: .formatOpenInput, avErrorCode: -Int32(EACCES)),
                                   streaming: true, hardware: true))
        XCTAssertNil(recovery.next(error: NSError(errorCode: .formatOpenInput, avErrorCode: Int32(swift_AVERROR_HTTP_UNAUTHORIZED)),
                                   streaming: true, hardware: true))
    }

    func testCorruptFramesDoNotConsumeHardwareRecovery() {
        var recovery = PlaybackRecovery()
        let corrupt = NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: -Int32(EINVAL))
        XCTAssertNil(recovery.next(error: corrupt, streaming: true, hardware: true))
        let terminal = NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: -12911)
        XCTAssertNil(recovery.next(error: terminal, streaming: false, hardware: false))
        XCTAssertEqual(recovery.next(error: terminal, streaming: false, hardware: true), .softwareDecode)
    }

    func testNetworkErrorsDoNotTriggerSoftwareDecode() {
        var recovery = PlaybackRecovery()
        let error = NSError(errorCode: .codecVideoReceiveFrame, avErrorCode: -Int32(ECONNRESET))
        XCTAssertNil(recovery.next(error: error, streaming: true, hardware: true))
    }

    func testStreamingDefaultsPreserveExplicitTransportAndSRTParameters() {
        let options = KSOptions()
        let rtsp = URL(string: "rtsp://example.invalid/live")!
        options.configureStreaming(url: rtsp)
        XCTAssertEqual(options.networkConnectTimeout, 5)
        XCTAssertEqual(options.networkReadTimeout, 10)
        XCTAssertEqual(options.formatContextOptions["rtsp_transport"] as? String, "tcp")
        options.formatContextOptions["rtsp_transport"] = "udp"
        options.networkConnectTimeout = 8
        options.configureStreaming(url: rtsp)
        XCTAssertEqual(options.networkConnectTimeout, 8)
        XCTAssertEqual(options.formatContextOptions["rtsp_transport"] as? String, "udp")
        XCTAssertTrue(KSOptions.isStreamingURL(URL(string: "srt://example.invalid:9000?mode=caller&latency=100000")!))
        XCTAssertTrue(KSOptions.isStreamingURL(URL(string: "rtmp://example.invalid/live/key")!))
        XCTAssertFalse(KSOptions.isStreamingURL(URL(string: "https://example.invalid/file.m3u8")!))
    }

    func testQueuedRPUOwnsItsBytes() throws {
        let frame = try XCTUnwrap(av_frame_alloc())
        defer {
            var pointer: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&pointer)
        }
        let side = try XCTUnwrap(av_frame_new_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER, 3))
        let bytes = try XCTUnwrap(side.pointee.data)
        bytes[0] = 1; bytes[1] = 2; bytes[2] = 3
        let copy = VideoDisplayMetadata(frame: frame, profile: 8)
        bytes[0] = 99
        XCTAssertEqual(copy.rpu, Data([1, 2, 3]))
    }

    @MainActor
    func testShutdownRejectsStaleCallbacksAndLiveSeek() {
        let url = URL(fileURLWithPath: "/unopened-fixture.mp4")
        let player = KSMEPlayer(url: url, options: KSOptions())
        let old = MEPlayerItem(url: url, options: KSOptions())
        player.pause()
        player.shutdown()
        player.sourceDidOpened(source: old)
        player.sourceDidChange(source: old, oldBitRate: 1, newBitrate: 2)
        XCTAssertFalse(player.isReadyToPlay)
        XCTAssertFalse(player.isPlaying)
        player.seek(time: 30) { XCTAssertFalse($0) }
        old.shutdown()
    }
}

private final class RecordingLog: LogHandler {
    var messages: [String] = []
    func log(level: LogLevel, message: CustomStringConvertible, file: String, function: String, line: UInt) {
        messages.append(message.description)
    }
}
