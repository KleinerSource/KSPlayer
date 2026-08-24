@testable import KSPlayer
import XCTest

class KSMEPlayerTest: XCTestCase {
    @MainActor
    func testPlaying() throws {
        let url = try DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = KSMEPlayer(url: url, options: KSOptions())
        player.delegate = self
        XCTAssertEqual(player.isPlaying, false)
        player.play()
        XCTAssertEqual(player.isPlaying, true)
        player.pause()
        XCTAssertEqual(player.isPlaying, false)
    }

    @MainActor
    func testAutoPlay() throws {
        let url = try DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = KSMEPlayer(url: url, options: KSOptions())
        player.delegate = self
        XCTAssertEqual(player.isPlaying, false)
        player.play()
        XCTAssertEqual(player.isPlaying, true)
        player.pause()
        XCTAssertEqual(player.isPlaying, false)
    }
}

extension KSMEPlayerTest: MediaPlayerDelegate {
    func readyToPlay(player _: some KSPlayer.MediaPlayerProtocol) {}

    func changeLoadState(player _: some KSPlayer.MediaPlayerProtocol) {}

    func changeBuffering(player _: some KSPlayer.MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some KSPlayer.MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some KSPlayer.MediaPlayerProtocol, error _: Error?) {}
}
