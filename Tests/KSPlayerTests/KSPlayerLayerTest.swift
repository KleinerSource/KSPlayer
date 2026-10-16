@testable import KSPlayer
import XCTest

class KSPlayerLayerTest: XCTestCase {
    private var readyToPlayExpectation: XCTestExpectation?
    override func setUp() {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isSecondOpen = true
        KSOptions.isAccurateSeek = true
    }

    @MainActor
    func testPlayerLayer() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        await set(path: url.path)
    }

    @MainActor
    private func set(path: String) async {
        let options = KSOptions()
        let playerLayer = KSPlayerLayer(url: URL(fileURLWithPath: path), isAutoPlay: false, options: options)
        playerLayer.delegate = self
        let readyExpectation = expectation(description: "openVideo")
        readyToPlayExpectation = readyExpectation
        playerLayer.prepareToPlay()
        XCTAssertEqual(playerLayer.state, .preparing)
        await fulfillment(of: [readyExpectation], timeout: 15)
        XCTAssertTrue(playerLayer.player.isReadyToPlay)
        guard playerLayer.player.isReadyToPlay else {
            playerLayer.stop()
            return
        }
        XCTAssertEqual(playerLayer.state, .readyToPlay)
        playerLayer.play()
        playerLayer.pause()
        XCTAssertEqual(playerLayer.state, .paused)
        let seekExpectation = expectation(description: "seek")
        playerLayer.seek(time: 2, autoPlay: true) { finished in
            XCTAssertTrue(finished)
            seekExpectation.fulfill()
        }
        XCTAssertEqual(playerLayer.state, .buffering)
        await fulfillment(of: [seekExpectation], timeout: 30)
        playerLayer.finish(player: playerLayer.player, error: nil)
        XCTAssertEqual(playerLayer.state, .playedToTheEnd)
        playerLayer.stop()
        XCTAssertEqual(playerLayer.state, .initialized)
    }
}

extension KSPlayerLayerTest: KSPlayerLayerDelegate {
    func player(layer _: KSPlayerLayer, state: KSPlayerState) {
        if state == .readyToPlay {
            readyToPlayExpectation?.fulfill()
        }
    }

    func player(layer _: KSPlayerLayer, currentTime _: TimeInterval, totalTime _: TimeInterval) {}

    func player(layer _: KSPlayerLayer, finish _: Error?) {}
    func player(layer _: KSPlayerLayer, bufferedCount: Int, consumeTime _: TimeInterval) {
        if bufferedCount > 0 {
            XCTFail()
        }
    }
}
