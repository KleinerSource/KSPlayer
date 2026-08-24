@testable import KSPlayer
import Foundation
import XCTest

private final class KSPlayerCacheFixtureURLProtocol: URLProtocol {
    static let payload = Data((0 ..< 64).map(UInt8.init))
    static var requestCount = 0
    static var isAvailable = true
    static var supportsRange = true
    static var isHLS = false

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard Self.isAvailable else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        Self.requestCount += 1
        let payload = Self.isHLS ? Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8) : Self.payload
        if !Self.supportsRange {
            let headers = [
                "Content-Length": "\(payload.count)",
                "Content-Type": Self.isHLS ? "application/vnd.apple.mpegurl" : "video/mp4",
            ]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")?.replacingOccurrences(of: "bytes=", with: "") ?? "0-"
        let parts = range.split(separator: "-")
        let start = parts.first.flatMap { Int($0) } ?? 0
        let end = parts.count > 1 ? (Int(parts[1]) ?? (payload.count - 1)) : (payload.count - 1)
        let boundedStart = max(0, min(start, payload.count))
        let boundedEnd = max(boundedStart, min(end, payload.count - 1))
        let data = boundedStart < payload.count ? payload.subdata(in: boundedStart ..< boundedEnd + 1) : Data()
        let headers = [
            "Content-Range": "bytes \(boundedStart)-\(boundedStart + max(data.count - 1, 0))/\(payload.count)",
            "Content-Length": "\(data.count)",
            "Content-Type": Self.isHLS ? "application/vnd.apple.mpegurl" : "video/mp4",
        ]
        let response = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class KSPlayerMediaCacheTest: XCTestCase {
    func testRangeCacheResumesAndReadsOffline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KSPlayerCacheFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cache = KSPlayerMediaCache(directory: directory, maximumCapacity: 1024, session: session)
        let url = URL(string: "https://fixture.invalid/video.mp4")!

        KSPlayerCacheFixtureURLProtocol.requestCount = 0
        KSPlayerCacheFixtureURLProtocol.isAvailable = true
        KSPlayerCacheFixtureURLProtocol.supportsRange = true
        KSPlayerCacheFixtureURLProtocol.isHLS = false
        let first = try cache.readSync(url: url, headers: ["Cookie": "fixture=1"], range: KSPlayerMediaCacheRange(start: 0, end: 8))
        XCTAssertEqual(first, KSPlayerCacheFixtureURLProtocol.payload.subdata(in: 0 ..< 8))
        let second = try cache.readSync(url: url, headers: ["Cookie": "fixture=1"], range: KSPlayerMediaCacheRange(start: 8, end: 16))
        XCTAssertEqual(second, KSPlayerCacheFixtureURLProtocol.payload.subdata(in: 8 ..< 16))

        _ = try cache.readSync(url: url, headers: ["Cookie": "fixture=1"], range: KSPlayerMediaCacheRange(start: 0, end: 64))
        XCTAssertEqual(cache.status(for: url, headers: ["Cookie": "fixture=1"]).state, .completed)
        let requestCount = KSPlayerCacheFixtureURLProtocol.requestCount
        KSPlayerCacheFixtureURLProtocol.isAvailable = false
        let offline = try cache.readSync(url: url, headers: ["Cookie": "fixture=1"], range: KSPlayerMediaCacheRange(start: 16, end: 24))
        XCTAssertEqual(offline, KSPlayerCacheFixtureURLProtocol.payload.subdata(in: 16 ..< 24))
        XCTAssertEqual(KSPlayerCacheFixtureURLProtocol.requestCount, requestCount)
        XCTAssertNotEqual(cache.key(for: url, headers: ["Cookie": "fixture=1"]), cache.key(for: url, headers: ["Cookie": "fixture=2"]))
        KSPlayerCacheFixtureURLProtocol.isAvailable = true
        KSPlayerCacheFixtureURLProtocol.supportsRange = true
        cache.removeAll()
    }

    func testNonRangeResourceFallsBackWithoutCaching() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KSPlayerCacheFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cache = KSPlayerMediaCache(directory: directory, session: session)
        let url = URL(string: "https://fixture.invalid/no-range.mp4")!
        KSPlayerCacheFixtureURLProtocol.isAvailable = true
        KSPlayerCacheFixtureURLProtocol.supportsRange = false
        KSPlayerCacheFixtureURLProtocol.isHLS = false
        defer {
            KSPlayerCacheFixtureURLProtocol.isAvailable = true
            KSPlayerCacheFixtureURLProtocol.supportsRange = true
            cache.removeAll()
        }

        XCTAssertThrowsError(try cache.readSync(url: url, headers: [:], range: KSPlayerMediaCacheRange(start: 0, end: 8)))
        XCTAssertEqual(cache.status(for: url).state, .unsupported)
    }

    func testHLSResourceFallsBackWithoutCaching() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KSPlayerCacheFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cache = KSPlayerMediaCache(directory: directory, session: session)
        let url = URL(string: "https://fixture.invalid/playlist")!
        KSPlayerCacheFixtureURLProtocol.isAvailable = true
        KSPlayerCacheFixtureURLProtocol.supportsRange = true
        KSPlayerCacheFixtureURLProtocol.isHLS = true
        defer {
            KSPlayerCacheFixtureURLProtocol.isHLS = false
            KSPlayerCacheFixtureURLProtocol.isAvailable = true
            KSPlayerCacheFixtureURLProtocol.supportsRange = true
            cache.removeAll()
        }

        XCTAssertThrowsError(try cache.readSync(url: url, headers: [:], range: KSPlayerMediaCacheRange(start: 0, end: 8)))
        XCTAssertEqual(cache.status(for: url).state, .unsupported)
    }

    func testActiveEntryIsProtectedFromPurge() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KSPlayerCacheFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let cache = KSPlayerMediaCache(directory: directory, maximumCapacity: 1, session: session)
        let url = URL(string: "https://fixture.invalid/active.mp4")!
        KSPlayerCacheFixtureURLProtocol.isAvailable = true
        KSPlayerCacheFixtureURLProtocol.supportsRange = true
        KSPlayerCacheFixtureURLProtocol.isHLS = false
        defer { cache.removeAll() }

        _ = try cache.readSync(url: url, headers: [:], range: KSPlayerMediaCacheRange(start: 0, end: 64))
        let key = cache.key(for: url)
        cache.beginActivity(key: key)
        cache.purge()
        XCTAssertEqual(cache.status(for: url).state, .completed)
        cache.endActivity(key: key)
        cache.purge()
        XCTAssertEqual(cache.status(for: url).state, .preparing)
    }

    func testMediaCacheIsExplicitlyDisabledByDefault() {
        XCTAssertFalse(KSOptions().mediaCacheEnabled)
    }
}
