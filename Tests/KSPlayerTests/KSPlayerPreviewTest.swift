@testable import KSPlayer
import XCTest

@MainActor
final class KSPlayerPreviewTest: XCTestCase, MediaPlayerDelegate {
    private var readyExpectation: XCTestExpectation?

    func testAVPlayerPreviewFramesAreSorted() async throws {
        let url = try DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = KSAVPlayer(url: url, options: KSOptions())
        player.delegate = self
        readyExpectation = expectation(description: "AVPlayer ready")
        player.prepareToPlay()
        await fulfillment(of: [readyExpectation!], timeout: 10)
        let frames = try await player.generatePreviewThumbnails()
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames.map(\.time), frames.map(\.time).sorted())
        XCTAssertTrue(frames.allSatisfy { $0.image.width <= 240 })
        player.shutdown()
    }

    func testFFmpegPreviewFramesAreSorted() async throws {
        let url = try DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = KSMEPlayer(url: url, options: KSOptions())
        let frames = try await player.generatePreviewThumbnails()
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames.map(\.time), frames.map(\.time).sorted())
        XCTAssertTrue(frames.allSatisfy { $0.image.width <= 240 })
        player.shutdown()
    }

    func readyToPlay(player _: some MediaPlayerProtocol) {
        readyExpectation?.fulfill()
    }

    func changeLoadState(player _: some MediaPlayerProtocol) {}

    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some MediaPlayerProtocol, error _: Error?) {}
}
