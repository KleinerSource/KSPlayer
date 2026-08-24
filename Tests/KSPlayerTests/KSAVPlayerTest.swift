@testable import KSPlayer
import XCTest

class KSAVPlayerTest: XCTestCase {
    private var readyToPlayExpectation: XCTestExpectation?
    @MainActor
    func testPlayer() throws {
        let url = try DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        set(path: url.path)
    }

    @MainActor
    func set(path: String) {
        let play = KSAVPlayer(url: URL(fileURLWithPath: path), options: KSOptions())
        play.delegate = self
        play.prepareToPlay()
        readyToPlayExpectation = expectation(description: "openVideo")
        waitForExpectations(timeout: 10) { _ in
            if play.isReadyToPlay {
                play.play()
            }
            play.shutdown()
        }
    }
}

extension KSAVPlayerTest: MediaPlayerDelegate {
    func readyToPlay(player _: some MediaPlayerProtocol) {
        readyToPlayExpectation?.fulfill()
    }

    func changeLoadState(player _: some MediaPlayerProtocol) {}

    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some MediaPlayerProtocol, error: Error?) {
        if error != nil {
            readyToPlayExpectation?.fulfill()
        }
    }
}
