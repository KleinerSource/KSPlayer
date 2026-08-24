import AVFoundation
import CoreGraphics
import Foundation

/// A frame generated for the progress-bar preview.
public struct KSPlayerPreviewFrame: @unchecked Sendable, Identifiable {
    public let time: TimeInterval
    public let image: CGImage

    public init(time: TimeInterval, image: CGImage) {
        self.time = time
        self.image = image
    }

    public var id: TimeInterval { time }
}

public enum KSPlayerPreviewError: Error {
    case noVideoTrack
    case invalidDuration
}

extension AVAsset {
    func loadKSPlayerPreviewValues() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
                for key in ["tracks", "duration"] {
                    var error: NSError?
                    switch self.statusOfValue(forKey: key, error: &error) {
                    case .loaded:
                        continue
                    case .failed, .cancelled:
                        continuation.resume(throwing: error ?? KSPlayerPreviewError.invalidDuration)
                        return
                    default:
                        continuation.resume(throwing: KSPlayerPreviewError.invalidDuration)
                        return
                    }
                }
                continuation.resume()
            }
        }
    }
}

final class KSPlayerPreviewGenerationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var state: KSPlayerPreviewGenerationState?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ state: KSPlayerPreviewGenerationState) {
        lock.lock()
        self.state = state
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            state.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let state = self.state
        lock.unlock()
        state?.cancel()
    }
}

final class KSPlayerPreviewImageState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false

    func set(_ continuation: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: nil)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ image: CGImage?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}

func scaledKSPlayerPreviewImage(_ image: CGImage, width: Int = 240) -> CGImage {
    guard width > 0, image.width > width else { return image }
    let height = max(1, Int(CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return image }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}

final class KSPlayerPreviewGenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = [KSPlayerPreviewFrame]()
    private var remaining: Int
    private var finished = false
    private let completion: (Result<[KSPlayerPreviewFrame], Error>) -> Void
    private let update: ([KSPlayerPreviewFrame]) -> Void

    init(count: Int, update: @escaping ([KSPlayerPreviewFrame]) -> Void = { _ in },
         completion: @escaping (Result<[KSPlayerPreviewFrame], Error>) -> Void)
    {
        remaining = count
        self.update = update
        self.completion = completion
    }

    func append(_ frame: KSPlayerPreviewFrame?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let frame { frames.append(frame) }
        remaining -= 1
        if remaining <= 0 {
            finished = true
            let result = frames.sorted { $0.time < $1.time }
            lock.unlock()
            update(result)
            completion(.success(result))
        } else {
            let result = frames.sorted { $0.time < $1.time }
            lock.unlock()
            update(result)
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion(.failure(CancellationError()))
    }
}
