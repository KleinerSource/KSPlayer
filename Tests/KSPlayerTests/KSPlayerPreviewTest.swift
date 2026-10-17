@testable import KSPlayer
import Network
import XCTest

@MainActor
final class KSPlayerPreviewTest: XCTestCase, MediaPlayerDelegate {
    private var readyExpectation: XCTestExpectation?

    func testRequestedTimeProducesOnlyOneSmallFrame() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = try await ThumbnailController().generateThumbnail(for: url, at: 0.5)
        XCTAssertEqual(frames.count, 1)
        XCTAssertGreaterThanOrEqual(frames.first?.time ?? 0, 0.5)
        XCTAssertLessThanOrEqual(frames.first?.cgImage?.width ?? 0, 240)
    }

    func testSinglePreviewDoesNotGenerateTheWholeTimeline() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let originalType = KSOptions.firstPlayerType
        defer { KSOptions.firstPlayerType = originalType }
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: KSOptions())
        defer { layer.stop() }
        layer.player.delegate = self
        readyExpectation = expectation(description: "single preview ready")
        layer.player.prepareToPlay()
        await fulfillment(of: [readyExpectation!], timeout: 10)
        let image = await layer.previewImage(at: 0.5)
        XCTAssertNotNil(image)
        XCTAssertLessThanOrEqual(image?.width ?? 0, 240)
        XCTAssertTrue(layer.previewFrames.isEmpty, "A single hover must not generate 100 timeline thumbnails")
    }

    func testCancellingPreviewInterruptsAStalledHTTPRead() async throws {
        let ready = expectation(description: "HTTP listener ready")
        let requested = expectation(description: "HTTP request received")
        let finished = expectation(description: "cancelled preview finished")
        let server = try StalledPreviewHTTPServer(ready: ready, requested: requested)
        defer { server.close() }
        server.start()
        await fulfillment(of: [ready], timeout: 3)
        let task = Task {
            _ = try? await ThumbnailController().generateThumbnail(for: server.url)
            finished.fulfill()
        }
        await fulfillment(of: [requested], timeout: 3)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        // Also release the blocked original implementation after the assertion.
        server.close()
        _ = await task.result
    }

    func testAVPlayerPreviewFramesAreSorted() async throws {
        let url = try await DeterministicMediaFixture.videoURL()
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
        let url = try await DeterministicMediaFixture.videoURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let player = KSMEPlayer(url: url, options: KSOptions())
        defer { player.shutdown() }
        player.delegate = self
        readyExpectation = expectation(description: "FFmpeg player ready")
        player.prepareToPlay()
        await fulfillment(of: [readyExpectation!], timeout: 10)
        let frames = try await player.generatePreviewThumbnails()
        XCTAssertFalse(frames.isEmpty)
        XCTAssertEqual(frames.map(\.time), frames.map(\.time).sorted())
        XCTAssertTrue(frames.allSatisfy { $0.image.width <= 240 })
    }

    func readyToPlay(player _: some MediaPlayerProtocol) {
        readyExpectation?.fulfill()
    }

    func changeLoadState(player _: some MediaPlayerProtocol) {}

    func changeBuffering(player _: some MediaPlayerProtocol, progress _: Int) {}

    func playBack(player _: some MediaPlayerProtocol, loopCount _: Int) {}

    func finish(player _: some MediaPlayerProtocol, error _: Error?) {}
}

private final class StalledPreviewHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections = [NWConnection]()

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/preview.mkv")! }

    init(ready: XCTestExpectation, requested: XCTestExpectation) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            self.connections.append(connection)
            self.lock.unlock()
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                if data?.isEmpty == false { requested.fulfill() }
                // Keep the socket open without returning HTTP headers or data.
            }
        }
    }

    func start() { listener.start(queue: .global()) }

    func close() {
        listener.cancel()
        lock.lock()
        let active = connections
        connections.removeAll()
        lock.unlock()
        active.forEach { $0.cancel() }
    }
}
