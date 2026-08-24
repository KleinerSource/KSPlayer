import AVFoundation
import CoreVideo
import Foundation

enum DeterministicMediaFixture {
    static func videoURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KSPlayer-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 160,
            kCVPixelBufferHeightKey as String: 90,
        ])
        guard writer.canAdd(input) else { throw NSError(domain: "KSPlayerTests", code: 1) }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for index in 0 ..< 30 {
            while !input.isReadyForMoreMediaData {
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard let pixelBuffer else { throw NSError(domain: "KSPlayerTests", code: 2) }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                for y in 0 ..< 90 {
                    for x in 0 ..< 160 {
                        let offset = y * bytesPerRow + x * 4
                        bytes[offset] = UInt8((x + index * 3) % 255)
                        bytes[offset + 1] = UInt8((y + index * 5) % 255)
                        bytes[offset + 2] = UInt8((index * 7) % 255)
                        bytes[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else {
                throw writer.error ?? NSError(domain: "KSPlayerTests", code: 3)
            }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "KSPlayerTests", code: 4) }
        return url
    }
}
