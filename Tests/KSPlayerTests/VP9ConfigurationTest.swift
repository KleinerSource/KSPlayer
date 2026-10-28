@testable import KSPlayer
import libavcodec
import libavutil
import XCTest

final class VP9ConfigurationTest: XCTestCase {
    func testEightBitLimitedRangeConfiguration() throws {
        let pointer = try XCTUnwrap(avcodec_parameters_alloc())
        var owned: UnsafeMutablePointer<AVCodecParameters>? = pointer
        defer { avcodec_parameters_free(&owned) }
        pointer.pointee.format = AV_PIX_FMT_YUV420P.rawValue
        pointer.pointee.width = 1920
        pointer.pointee.height = 1080
        pointer.pointee.chroma_location = AVCHROMA_LOC_LEFT
        pointer.pointee.color_primaries = AVCOL_PRI_BT709
        pointer.pointee.color_trc = AVCOL_TRC_BT709
        pointer.pointee.color_space = AVCOL_SPC_BT709
        XCTAssertEqual(vp9Configuration(pointer.pointee), Data([1, 0, 0, 0, 0, 40, 128, 1, 1, 1, 0, 0]))
    }

    func testTenBitFullRangeAndExplicitLevel() throws {
        let pointer = try XCTUnwrap(avcodec_parameters_alloc())
        var owned: UnsafeMutablePointer<AVCodecParameters>? = pointer
        defer { avcodec_parameters_free(&owned) }
        pointer.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        pointer.pointee.level = 51
        pointer.pointee.color_range = AVCOL_RANGE_JPEG
        let bytes = try XCTUnwrap(vp9Configuration(pointer.pointee))
        XCTAssertEqual(bytes[4], 2)
        XCTAssertEqual(bytes[5], 51)
        XCTAssertEqual(bytes[6], 163)
        pointer.pointee.format = AV_PIX_FMT_NONE.rawValue
        XCTAssertNil(vp9Configuration(pointer.pointee))
    }
}
