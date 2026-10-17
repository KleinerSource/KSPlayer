import AVFoundation
import Metal
@testable import KSPlayer
import XCTest

#if canImport(UIKit)
import UIKit

@MainActor
final class ImageSubtitleRenderingTest: XCTestCase {
    func testConsumedCueRemainsVisibleUntilItsEnd() throws {
        let (output, source) = try makeOutput()
        defer { output.invalidate() }
        output.readNextFrame()
        XCTAssertNotNil(output.pixelBuffer)
        let subtitleLayer = try XCTUnwrap(output.layer.sublayers?.last)
        let queue = CircularBuffer<SubtitleFrame>(initialCapacity: 4)
        let part = makePart(start: 1, end: 3)
        queue.push(SubtitleFrame(part: part, timebase: .defaultValue))
        var time = 1.0
        output.imageSubtitleProvider = {
            (time, queue.search { $0.part == time }.map(\.part))
        }

        output.updateImageSubtitles()
        XCTAssertEqual(queue.count, 0)
        let imageLayer = try XCTUnwrap(subtitleLayer.sublayers?.first)
        XCTAssertNotNil(imageLayer.contents)
        for tick in 1 ... 39 {
            time = 1 + Double(tick) * 0.05
            output.updateImageSubtitles()
            XCTAssertTrue(subtitleLayer.sublayers?.first === imageLayer)
        }
        time = 3.01
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)
        XCTAssertEqual(source.framesRequested, 1)
    }

    func testPgsClearCueEndsAnIndefiniteBitmap() throws {
        let (output, source) = try makeOutput()
        defer { output.invalidate() }
        output.readNextFrame()
        let subtitleLayer = try XCTUnwrap(output.layer.sublayers?.last)
        var parts = [makePart(start: 1, end: .infinity)]
        var time = 1.0
        output.imageSubtitleProvider = {
            let next = parts
            parts = []
            return (time, next)
        }
        output.updateImageSubtitles()
        XCTAssertEqual(subtitleLayer.sublayers?.count, 1)
        time = 20
        output.updateImageSubtitles()
        XCTAssertEqual(subtitleLayer.sublayers?.count, 1)

        parts = [SubtitlePart(21, .infinity, attributedString: nil)]
        time = 21
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)
        time = 22
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)
        XCTAssertEqual(source.framesRequested, 1)
    }

    func testClearingOrDisablingSubtitlesDropsTheCachedBitmap() throws {
        let (output, source) = try makeOutput()
        defer { output.invalidate() }
        output.readNextFrame()
        let subtitleLayer = try XCTUnwrap(output.layer.sublayers?.last)
        var parts = [makePart(start: 0, end: .infinity)]
        var enabled = true
        output.imageSubtitleProvider = {
            guard enabled else { return nil }
            let next = parts
            parts = []
            return (1, next)
        }
        output.updateImageSubtitles()
        XCTAssertEqual(subtitleLayer.sublayers?.count, 1)
        output.clearSubtitles()
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)

        parts = [makePart(start: 0, end: .infinity)]
        output.updateImageSubtitles()
        XCTAssertEqual(subtitleLayer.sublayers?.count, 1)
        enabled = false
        output.updateImageSubtitles()
        enabled = true
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)
        XCTAssertEqual(source.framesRequested, 1)
    }

    func testCueReceivedBeforeFirstVideoFrameIsRenderedLaterAndResized() throws {
        let (output, source) = try makeOutput()
        defer { output.invalidate() }
        let subtitleLayer = try XCTUnwrap(output.layer.sublayers?.last)
        var parts = [makePart(start: 0, end: .infinity)]
        output.imageSubtitleProvider = {
            let next = parts
            parts = []
            return (1, next)
        }
        output.updateImageSubtitles()
        XCTAssertTrue(subtitleLayer.sublayers?.isEmpty ?? true)
        output.readNextFrame()
        output.updateImageSubtitles()
        let first = try XCTUnwrap(subtitleLayer.sublayers?.first)
        XCTAssertEqual(first.frame, CGRect(x: 20, y: 40, width: 40, height: 20))

        output.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        output.updateImageSubtitles()
        let resized = try XCTUnwrap(subtitleLayer.sublayers?.first)
        XCTAssertEqual(resized.frame, CGRect(x: 10, y: 20, width: 20, height: 10))

        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 200, 100, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        source.pixelBuffer = try XCTUnwrap(pixelBuffer)
        output.readNextFrame()
        output.updateImageSubtitles()
        let reformatted = try XCTUnwrap(subtitleLayer.sublayers?.first)
        XCTAssertEqual(reformatted.frame, CGRect(x: 5, y: 60, width: 10, height: 5))
        XCTAssertGreaterThan(subtitleLayer.zPosition, output.displayView.layer.zPosition)
        XCTAssertEqual(source.framesRequested, 2)
    }

    private func makeOutput() throws -> (MetalPlayView, ImageSubtitleVideoSource) {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("MetalPlayView requires a Metal device")
        }
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 100, 100, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let source = ImageSubtitleVideoSource(pixelBuffer: try XCTUnwrap(pixelBuffer))
        let output = MetalPlayView(options: KSOptions())
        output.bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        output.contentMode = .scaleAspectFit
        output.renderSource = source
        return (output, source)
    }

    private func makePart(start: TimeInterval, end: TimeInterval) -> SubtitlePart {
        let part = SubtitlePart(start, end, attributedString: nil)
        part.origin = CGPoint(x: 5, y: 10)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        part.image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 5), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
        }
        return part
    }
}

private final class ImageSubtitleVideoSource: OutputRenderSourceDelegate {
    var pixelBuffer: CVPixelBuffer
    var framesRequested = 0

    init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }

    func getVideoOutputRender(force: Bool) -> VideoVTBFrame? {
        framesRequested += 1
        let frame = VideoVTBFrame(fps: 24, isDovi: false)
        frame.corePixelBuffer = pixelBuffer
        return frame
    }

    func getAudioOutputRender() -> AudioFrame? { nil }
    func setAudio(time: CMTime, position: Int64) {}
    func setVideo(time: CMTime, position: Int64) {}
}
#endif
