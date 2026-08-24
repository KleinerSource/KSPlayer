import AVFoundation
import CryptoKit
import Foundation

public enum KSPlayerMediaCacheState: Equatable, Sendable {
    case disabled
    case preparing
    case caching
    case completed
    case unsupported
    case failed
}

public struct KSPlayerMediaCacheStatus: Sendable {
    public let url: URL
    public let state: KSPlayerMediaCacheState
    public let downloadedBytes: Int64
    public let totalBytes: Int64?
    public let lastAccessDate: Date?
    public let errorDescription: String?

    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1)
    }
}

private struct KSPlayerMediaCacheMetadata: Codable {
    var totalBytes: Int64?
    var mimeType: String?
    var supportsRanges: Bool
    var ranges: [[Int64]]
    var lastAccessDate: Date
}

struct KSPlayerMediaCacheRange: Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { max(0, end - start) }
}

/// A small range cache shared by AVPlayer and FFmpeg.
///
/// Only HTTP(S) resources with a known length and a working byte range request
/// are cached. Partial files are intentionally retained without a completion
/// marker so a later player can continue the download safely.
public final class KSPlayerMediaCache: NSObject, @unchecked Sendable {
    public static let shared = KSPlayerMediaCache()

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("KSPlayer/Media", isDirectory: true)
    }

    public let directory: URL
    public var maximumCapacity: Int64 {
        get { lock.withLock { maximumCapacityValue } }
        set { lock.withLock { maximumCapacityValue = max(0, newValue) } }
    }

    private var maximumCapacityValue: Int64
    private let fileManager: FileManager
    private let lock = NSLock()
    private let session: URLSession
    private var activeKeys = [String: Int]()
    private var tasks = [String: [URLSessionDataTask]]()
    private var failures = [String: String]()

    public init(directory: URL = KSPlayerMediaCache.defaultDirectory,
                maximumCapacity: Int64 = 512 * 1024 * 1024,
                session: URLSession = .shared)
    {
        self.directory = directory
        maximumCapacityValue = max(0, maximumCapacity)
        fileManager = FileManager.default
        self.session = session
        super.init()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func key(for url: URL, headers: [String: String] = [:]) -> String {
        let headerText = headers.map { key, value in
            (key.lowercased(), value)
        }.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }.map { key, value in
            "\(key)=\(value)"
        }.joined(separator: "&")
        let source = "\(url.absoluteString)\n\(headerText)"
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func status(for url: URL, headers: [String: String] = [:]) -> KSPlayerMediaCacheStatus {
        let key = key(for: url, headers: headers)
        return lock.withLock {
            guard let metadata = loadMetadata(forKey: key) else {
                let failed = failures[key]
                return KSPlayerMediaCacheStatus(url: url,
                                                state: failed == nil ? (isCacheable(url) ? .preparing : .unsupported) : .failed,
                                                downloadedBytes: 0, totalBytes: nil, lastAccessDate: nil,
                                                errorDescription: failed)
            }
            let downloaded = metadata.ranges.reduce(Int64(0)) { $0 + max(0, $1[1] - $1[0]) }
            let complete = metadata.totalBytes.map { isCovered(metadata.ranges, range: KSPlayerMediaCacheRange(start: 0, end: $0)) } ?? false
            let state: KSPlayerMediaCacheState
            if let failure = failures[key] {
                state = .failed
                return KSPlayerMediaCacheStatus(url: url, state: state, downloadedBytes: downloaded,
                                                totalBytes: metadata.totalBytes, lastAccessDate: metadata.lastAccessDate,
                                                errorDescription: failure)
            } else if !metadata.supportsRanges {
                state = .unsupported
            } else if complete, fileManager.fileExists(atPath: completeURL(forKey: key).path) {
                state = .completed
            } else {
                state = .caching
            }
            return KSPlayerMediaCacheStatus(url: url, state: state, downloadedBytes: downloaded,
                                            totalBytes: metadata.totalBytes, lastAccessDate: metadata.lastAccessDate,
                                            errorDescription: nil)
        }
    }

    /// Performs the range capability probe used by AVPlayer and FFmpeg.
    @discardableResult
    public func prepare(url: URL, headers: [String: String] = [:]) async -> Bool {
        guard isCacheable(url) else { return false }
        let key = key(for: url, headers: headers)
        if let metadata = lock.withLock({ loadMetadata(forKey: key) }), metadata.supportsRanges,
           metadata.totalBytes ?? 0 > 0
        {
            if let total = metadata.totalBytes,
               isCovered(metadata.ranges, range: KSPlayerMediaCacheRange(start: 0, end: total))
            {
                lock.withLock {
                    if !fileManager.fileExists(atPath: completeURL(forKey: key).path) {
                        fileManager.createFile(atPath: completeURL(forKey: key).path, contents: Data())
                    }
                }
            }
            return true
        }
        do {
            let result = try await request(url: url, headers: headers, range: KSPlayerMediaCacheRange(start: 0, end: 256))
            guard result.response.statusCode == 206,
                  let total = contentRangeTotal(result.response), total > 0,
                  result.data.count > 0,
                  !isHLS(response: result.response, url: url, data: result.data)
            else {
                saveUnsupported(key: key)
                return false
            }
            store(data: result.data, at: contentRangeStart(result.response) ?? 0, key: key,
                  totalBytes: total, mimeType: result.response.mimeType)
            return true
        } catch {
            recordFailure(key: key, error: error)
            return false
        }
    }

    public func cancel(url: URL, headers: [String: String] = [:]) {
        let key = key(for: url, headers: headers)
        lock.withLock {
            tasks[key]?.forEach { $0.cancel() }
            tasks[key] = nil
        }
    }

    public func remove(url: URL, headers: [String: String] = [:]) {
        let key = key(for: url, headers: headers)
        lock.withLock { removeEntry(forKey: key) }
    }

    /// Removes all completed and partial media cache entries.
    public func removeAll() {
        cancelAllTasks()
        lock.withLock {
            guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            urls.forEach { try? fileManager.removeItem(at: $0) }
        }
    }

    public func clear() {
        removeAll()
    }

    public func clear(url: URL, headers: [String: String] = [:]) {
        remove(url: url, headers: headers)
    }

    /// Enforces the configured capacity using least-recently-used entries.
    public func purge() {
        lock.withLock { evictIfNeeded(excluding: []) }
    }

    internal func makeAVAsset(url: URL, headers: [String: String] = [:]) async -> (asset: AVURLAsset, loader: KSPlayerMediaCacheResourceLoader)? {
        guard await prepare(url: url, headers: headers) else { return nil }
        let key = key(for: url, headers: headers)
        let loader = KSPlayerMediaCacheResourceLoader(cache: self, url: url, headers: headers, key: key)
        guard let cacheURL = URL(string: "ksplayer-cache://\(key)") else { return nil }
        let asset = AVURLAsset(url: cacheURL)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "KSPlayer.MediaCache.\(key)"))
        return (asset, loader)
    }

    internal func makeFFmpegIOContext(url: URL, headers: [String: String] = [:]) -> KSPlayerMediaCacheIOContext? {
        guard isCacheable(url), prepareSync(url: url, headers: headers) else { return nil }
        let key = key(for: url, headers: headers)
        return KSPlayerMediaCacheIOContext(cache: self, url: url, headers: headers, key: key)
    }

    internal func read(url: URL, headers: [String: String], range: KSPlayerMediaCacheRange) async throws -> Data {
        guard range.length > 0 else { return Data() }
        guard await prepare(url: url, headers: headers) else { throw KSPlayerMediaCacheError.unsupported }
        let key = key(for: url, headers: headers)
        markActive(key: key, active: true)
        defer { markActive(key: key, active: false) }
        if let data = readCached(range: range, key: key) {
            touch(key: key)
            return data
        }
        let result: (data: Data, response: HTTPURLResponse)
        do {
            result = try await request(url: url, headers: headers, range: range)
        } catch {
            recordFailure(key: key, error: error)
            throw error
        }
        guard result.response.statusCode == 206 || (result.response.statusCode == 200 && range.start == 0) else {
            throw KSPlayerMediaCacheError.invalidRangeResponse
        }
        let offset = contentRangeStart(result.response) ?? 0
        store(data: result.data, at: offset, key: key, totalBytes: contentRangeTotal(result.response), mimeType: result.response.mimeType)
        let availableEnd = min(range.end, offset + Int64(result.data.count))
        guard offset <= range.start, availableEnd > range.start,
              let data = readCached(range: KSPlayerMediaCacheRange(start: range.start, end: availableEnd), key: key)
        else { throw KSPlayerMediaCacheError.readFailed }
        return data
    }

    internal func readSync(url: URL, headers: [String: String], range: KSPlayerMediaCacheRange) throws -> Data {
        guard range.length > 0 else { return Data() }
        guard prepareSync(url: url, headers: headers) else { throw KSPlayerMediaCacheError.unsupported }
        let key = key(for: url, headers: headers)
        markActive(key: key, active: true)
        defer { markActive(key: key, active: false) }
        if let data = readCached(range: range, key: key) {
            touch(key: key)
            return data
        }
        let result: (data: Data, response: HTTPURLResponse)
        do {
            result = try requestSync(url: url, headers: headers, range: range)
        } catch {
            recordFailure(key: key, error: error)
            throw error
        }
        guard result.response.statusCode == 206 || (result.response.statusCode == 200 && range.start == 0) else {
            throw KSPlayerMediaCacheError.invalidRangeResponse
        }
        let offset = contentRangeStart(result.response) ?? 0
        store(data: result.data, at: offset, key: key, totalBytes: contentRangeTotal(result.response), mimeType: result.response.mimeType)
        let availableEnd = min(range.end, offset + Int64(result.data.count))
        guard offset <= range.start, availableEnd > range.start,
              let data = readCached(range: KSPlayerMediaCacheRange(start: range.start, end: availableEnd), key: key)
        else { throw KSPlayerMediaCacheError.readFailed }
        return data
    }

    internal func read(url: URL, headers: [String: String], range: KSPlayerMediaCacheRange,
                       completion: @escaping (Result<Data, Error>) -> Void)
    {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            completion(Result { try self.readSync(url: url, headers: headers, range: range) })
        }
    }

    internal func metadata(forKey key: String) -> (totalBytes: Int64, mimeType: String?)? {
        lock.withLock {
            guard let metadata = loadMetadata(forKey: key), let total = metadata.totalBytes, total > 0 else { return nil }
            return (total, metadata.mimeType)
        }
    }

    internal func beginActivity(key: String) {
        markActive(key: key, active: true)
    }

    internal func endActivity(key: String) {
        markActive(key: key, active: false)
    }

    private func isCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        !url.path.lowercased().hasSuffix(".m3u8")
    }

    private func request(url: URL, headers: [String: String], range: KSPlayerMediaCacheRange) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(range.start)-\(range.end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return try await withCheckedThrowingContinuation { continuation in
            var task: URLSessionDataTask?
            task = session.dataTask(with: request) { [weak self] data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response = response as? HTTPURLResponse, let data {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: KSPlayerMediaCacheError.invalidResponse)
                }
                if let self, let task { self.unregister(task: task) }
            }
            if let task {
                register(task: task, key: key(for: url, headers: headers))
                task.resume()
            }
        }
    }

    private func requestSync(url: URL, headers: [String: String], range: KSPlayerMediaCacheRange) throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(range.start)-\(range.end - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>!
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error) }
            else if let response = response as? HTTPURLResponse, let data { result = .success((data, response)) }
            else { result = .failure(KSPlayerMediaCacheError.invalidResponse) }
        }
        register(task: task, key: key(for: url, headers: headers))
        task.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            task.cancel()
            throw KSPlayerMediaCacheError.invalidResponse
        }
        unregister(task: task)
        guard let result else { throw KSPlayerMediaCacheError.invalidResponse }
        return try result.get()
    }

    private func prepareSync(url: URL, headers: [String: String]) -> Bool {
        guard isCacheable(url) else { return false }
        let key = key(for: url, headers: headers)
        if let metadata = lock.withLock({ loadMetadata(forKey: key) }), metadata.supportsRanges, metadata.totalBytes ?? 0 > 0 {
            if let total = metadata.totalBytes,
               isCovered(metadata.ranges, range: KSPlayerMediaCacheRange(start: 0, end: total))
            {
                lock.withLock {
                    if !fileManager.fileExists(atPath: completeURL(forKey: key).path) {
                        fileManager.createFile(atPath: completeURL(forKey: key).path, contents: Data())
                    }
                }
            }
            return true
        }
        do {
            let result = try requestSync(url: url, headers: headers, range: KSPlayerMediaCacheRange(start: 0, end: 256))
            guard result.response.statusCode == 206, let total = contentRangeTotal(result.response), total > 0,
                  result.data.count > 0, !isHLS(response: result.response, url: url, data: result.data)
            else { saveUnsupported(key: key); return false }
            store(data: result.data, at: contentRangeStart(result.response) ?? 0, key: key, totalBytes: total, mimeType: result.response.mimeType)
            return true
        } catch {
            recordFailure(key: key, error: error)
            return false
        }
    }

    private func store(data: Data, at offset: Int64, key: String, totalBytes: Int64?, mimeType: String?) {
        guard !data.isEmpty, offset >= 0 else { return }
        lock.withLock {
            let part = partURL(forKey: key)
            if !fileManager.fileExists(atPath: part.path) { fileManager.createFile(atPath: part.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: part) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(offset))
            try? handle.write(contentsOf: data)
            var metadata = loadMetadata(forKey: key) ?? KSPlayerMediaCacheMetadata(totalBytes: totalBytes, mimeType: mimeType,
                                                                                     supportsRanges: true, ranges: [], lastAccessDate: Date())
            metadata.totalBytes = totalBytes ?? metadata.totalBytes
            metadata.mimeType = mimeType ?? metadata.mimeType
            metadata.supportsRanges = true
            metadata.ranges = merge(metadata.ranges, with: KSPlayerMediaCacheRange(start: offset, end: offset + Int64(data.count)))
            metadata.lastAccessDate = Date()
            saveMetadata(metadata, forKey: key)
            failures[key] = nil
            if let total = metadata.totalBytes,
               isCovered(metadata.ranges, range: KSPlayerMediaCacheRange(start: 0, end: total))
            {
                if !fileManager.fileExists(atPath: completeURL(forKey: key).path) { fileManager.createFile(atPath: completeURL(forKey: key).path, contents: Data()) }
            }
            evictIfNeeded(excluding: Set(activeKeys.keys))
        }
    }

    private func readCached(range: KSPlayerMediaCacheRange, key: String) -> Data? {
        lock.withLock {
            guard let metadata = loadMetadata(forKey: key), isCovered(metadata.ranges, range: range),
                  let handle = try? FileHandle(forReadingFrom: partURL(forKey: key))
            else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(range.start))
            let data = try? handle.read(upToCount: Int(min(range.length, Int64(Int.max))))
            return data ?? nil
        }
    }

    private func touch(key: String) {
        lock.withLock {
            guard var metadata = loadMetadata(forKey: key) else { return }
            metadata.lastAccessDate = Date()
            saveMetadata(metadata, forKey: key)
        }
    }

    private func markActive(key: String, active: Bool) {
        lock.withLock {
            if active {
                activeKeys[key, default: 0] += 1
            } else if let count = activeKeys[key], count > 1 {
                activeKeys[key] = count - 1
            } else {
                activeKeys[key] = nil
            }
        }
    }

    private func evictIfNeeded(excluding protectedKeys: Set<String>) {
        guard maximumCapacityValue > 0 else { return }
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        let keys = Set(urls.compactMap { $0.pathExtension == "json" ? $0.deletingPathExtension().lastPathComponent : nil })
        var sizes = keys.map { key -> (String, Int64, Date) in
            let values = try? partURL(forKey: key).resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = loadMetadata(forKey: key)?.lastAccessDate ?? .distantPast
            return (key, size, date)
        }
        var total = sizes.reduce(Int64(0)) { $0 + $1.1 }
        for entry in sizes.sorted(by: { $0.2 < $1.2 }) where total > maximumCapacityValue {
            guard !protectedKeys.contains(entry.0) else { continue }
            removeEntry(forKey: entry.0)
            total -= entry.1
        }
        sizes.removeAll()
    }

    private func saveUnsupported(key: String, error: Error? = nil) {
        lock.withLock {
            let metadata = KSPlayerMediaCacheMetadata(totalBytes: nil, mimeType: nil, supportsRanges: false,
                                                      ranges: [], lastAccessDate: Date())
            saveMetadata(metadata, forKey: key)
            failures[key] = nil
            if let error { KSLog("Media cache disabled for \(key): \(error)") }
        }
    }

    private func recordFailure(key: String, error: Error) {
        lock.withLock { failures[key] = error.localizedDescription }
    }

    private func cancelAllTasks() {
        lock.withLock {
            tasks.values.flatMap { $0 }.forEach { $0.cancel() }
            tasks.removeAll()
            failures.removeAll()
        }
    }

    private func register(task: URLSessionDataTask, key: String) {
        lock.withLock { tasks[key, default: []].append(task) }
    }

    private func unregister(task: URLSessionDataTask) {
        lock.withLock {
            for key in tasks.keys {
                tasks[key]?.removeAll { $0 === task }
                if tasks[key]?.isEmpty == true { tasks[key] = nil }
            }
        }
    }

    private func loadMetadata(forKey key: String) -> KSPlayerMediaCacheMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(KSPlayerMediaCacheMetadata.self, from: data)
    }

    private func saveMetadata(_ metadata: KSPlayerMediaCacheMetadata, forKey key: String) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataURL(forKey: key), options: .atomic)
    }

    private func removeEntry(forKey key: String) {
        try? fileManager.removeItem(at: partURL(forKey: key))
        try? fileManager.removeItem(at: metadataURL(forKey: key))
        try? fileManager.removeItem(at: completeURL(forKey: key))
        failures[key] = nil
    }

    private func partURL(forKey key: String) -> URL { directory.appendingPathComponent("\(key).part") }
    private func metadataURL(forKey key: String) -> URL { directory.appendingPathComponent("\(key).json") }
    private func completeURL(forKey key: String) -> URL { directory.appendingPathComponent("\(key).complete") }

    private func merge(_ ranges: [[Int64]], with newRange: KSPlayerMediaCacheRange) -> [[Int64]] {
        var result = [KSPlayerMediaCacheRange]()
        var pending = newRange
        for item in ranges where item.count == 2 {
            let range = KSPlayerMediaCacheRange(start: item[0], end: item[1])
            if range.end < pending.start || pending.end < range.start {
                result.append(range)
            } else {
                pending = KSPlayerMediaCacheRange(start: min(pending.start, range.start), end: max(pending.end, range.end))
            }
        }
        result.append(pending)
        return result.sorted { $0.start < $1.start }.map { [$0.start, $0.end] }
    }

    private func isCovered(_ ranges: [[Int64]], range: KSPlayerMediaCacheRange) -> Bool {
        ranges.contains { $0.count == 2 && $0[0] <= range.start && $0[1] >= range.end }
    }

    private func isHLS(response: HTTPURLResponse, url: URL, data: Data? = nil) -> Bool {
        let mime = response.mimeType?.lowercased() ?? ""
        if url.path.lowercased().hasSuffix(".m3u8") || mime.contains("mpegurl") || mime.contains("x-mpegurl") {
            return true
        }
        guard let data, let prefix = String(data: Data(data.prefix(256)), encoding: .utf8) else { return false }
        return prefix.contains("#EXTM3U")
    }

    private func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let values = value.replacingOccurrences(of: "bytes ", with: "").split(separator: "/")
        return values.first?.split(separator: "-").first.flatMap { Int64($0) }
    }

    private func contentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
        return value.split(separator: "/").last.flatMap { Int64($0) }
    }
}

private enum KSPlayerMediaCacheError: LocalizedError {
    case unsupported
    case invalidResponse
    case invalidRangeResponse
    case readFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return "The resource does not support byte-range caching."
        case .invalidResponse: return "The media cache received an invalid HTTP response."
        case .invalidRangeResponse: return "The media server ignored the requested byte range."
        case .readFailed: return "The media cache could not read the requested range."
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

internal final class KSPlayerMediaCacheResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let cache: KSPlayerMediaCache
    private let url: URL
    private let headers: [String: String]
    private let key: String

    init(cache: KSPlayerMediaCache, url: URL, headers: [String: String], key: String) {
        self.cache = cache
        self.url = url
        self.headers = headers
        self.key = key
        cache.beginActivity(key: key)
    }

    deinit {
        cache.endActivity(key: key)
    }

    func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let dataRequest = loadingRequest.dataRequest else {
            guard let info = loadingRequest.contentInformationRequest,
                  let metadata = cache.metadata(forKey: key)
            else { return false }
            info.contentType = metadata.mimeType?.contains("mp4") == true ? AVFileType.mp4.rawValue : "public.data"
            info.contentLength = metadata.totalBytes
            info.isByteRangeAccessSupported = true
            loadingRequest.finishLoading()
            return true
        }
        let start = max(0, dataRequest.requestedOffset)
        let requestedLength: Int
        if dataRequest.requestsAllDataToEndOfResource {
            guard let total = cache.metadata(forKey: key)?.totalBytes,
                  total > start,
                  total - start <= Int64(Int.max)
            else { return false }
            requestedLength = Int(total - start)
        } else {
            requestedLength = dataRequest.requestedLength
        }
        guard requestedLength > 0 else { return false }
        let range = KSPlayerMediaCacheRange(start: start, end: start + Int64(requestedLength))
        cache.read(url: url, headers: headers, range: range) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(data):
                if let info = loadingRequest.contentInformationRequest, let metadata = self.cache.metadata(forKey: self.key) {
                    info.contentType = metadata.mimeType?.contains("mp4") == true ? AVFileType.mp4.rawValue : "public.data"
                    info.contentLength = metadata.totalBytes
                    info.isByteRangeAccessSupported = true
                }
                dataRequest.respond(with: data)
                loadingRequest.finishLoading()
            case let .failure(error):
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(_: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        cache.cancel(url: url, headers: headers)
    }
}

internal final class KSPlayerMediaCacheIOContext: AbstractAVIOContext, @unchecked Sendable {
    private let cache: KSPlayerMediaCache
    private let url: URL
    private let headers: [String: String]
    private let key: String
    private var position: Int64 = 0

    init(cache: KSPlayerMediaCache, url: URL, headers: [String: String], key: String) {
        self.cache = cache
        self.url = url
        self.headers = headers
        self.key = key
        super.init()
        cache.beginActivity(key: key)
    }

    override func close() {
        if !closed {
            closed = true
            cache.endActivity(key: key)
        }
    }

    private var closed = false

    deinit {
        close()
    }

    override func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        do {
            let data = try cache.readSync(url: url, headers: headers, range: KSPlayerMediaCacheRange(start: position, end: position + Int64(size)))
            data.copyBytes(to: UnsafeMutablePointer(mutating: buffer), count: data.count)
            position += Int64(data.count)
            return Int32(data.count)
        } catch {
            return 0
        }
    }

    override func seek(offset: Int64, whence: Int32) -> Int64 {
        switch whence & 0xFFFF {
        case 0: position = offset
        case 1: position += offset
        case 2:
            if let total = cache.metadata(forKey: key)?.totalBytes { position = total + offset } else { return -1 }
        default: return -1
        }
        position = max(0, position)
        return position
    }

    override func fileSize() -> Int64 {
        cache.metadata(forKey: key)?.totalBytes ?? -1
    }
}
