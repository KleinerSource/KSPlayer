import CoreGraphics
import Libavcodec
@testable import KSPlayer
import XCTest

final class SubtitleDecodeTest: XCTestCase {
    func testPgsCanvasComesFromPresentationSegmentWhenContainerDimensionsAreMissing() throws {
        var parameters = AVCodecParameters()
        parameters.codec_type = AVMEDIA_TYPE_SUBTITLE
        parameters.codec_id = AV_CODEC_ID_HDMV_PGS_SUBTITLE
        let track = try XCTUnwrap(FFmpegAssetTrack(codecpar: parameters))
        let decoder = SubtitleDecode(assetTrack: track, options: KSOptions())
        defer { decoder.shutdown() }

        // 1920x1080 的 PGS 画布，在 (900, 1000) 显示一个 2x1 白色位图。
        let bytes: [UInt8] = [
            0x16, 0x00, 0x13,
            0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, 0x80, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00, 0x03, 0x84, 0x03, 0xE8,
            0x14, 0x00, 0x07, 0x00, 0x00, 0x01, 0xEB, 0x80, 0x80, 0xFF,
            0x15, 0x00, 0x0F,
            0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x08, 0x00, 0x02, 0x00, 0x01,
            0x01, 0x01, 0x00, 0x00,
            0x80, 0x00, 0x00,
        ]
        let packet = Packet()
        let core = try XCTUnwrap(packet.corePacket)
        XCTAssertEqual(av_new_packet(core, Int32(bytes.count)), 0)
        let data = try XCTUnwrap(core.pointee.data)
        bytes.withUnsafeBufferPointer { buffer in
            data.update(from: buffer.baseAddress!, count: buffer.count)
        }
        core.pointee.pts = 0
        packet.assetTrack = track
        var parts = [SubtitlePart]()
        decoder.decodeFrame(from: packet) { result in
            do {
                let frame = try XCTUnwrap(try result.get() as? SubtitleFrame)
                parts.append(frame.part)
            } catch {
                XCTFail("PGS 解码失败: \(error)")
            }
        }
        let part = try XCTUnwrap(parts.first)
        XCTAssertNotNil(part.image)
        XCTAssertEqual(part.imageCanvasSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(part.origin, CGPoint(x: 900, y: 1000))
    }
}
