@testable import KSPlayer
import Libavcodec
import Libavformat
import Libavutil
import XCTest

final class FFmpegRuntimeTest: XCTestCase {
    func testMatchingRuntimeIsAccepted() {
        XCTAssertTrue(MEPlayerItem.isFFmpegRuntimeCompatible(formatVersion: avformat_version(),
                                                            codecVersion: avcodec_version(),
                                                            utilVersion: avutil_version()))
    }

    func testEachIncompatibleLibraryIsRejectedBeforeOpeningMedia() {
        let format = UInt32(LIBAVFORMAT_VERSION_MAJOR) << 16
        let codec = UInt32(LIBAVCODEC_VERSION_MAJOR) << 16
        let util = UInt32(LIBAVUTIL_VERSION_MAJOR) << 16
        XCTAssertTrue(MEPlayerItem.isFFmpegRuntimeCompatible(formatVersion: format, codecVersion: codec, utilVersion: util))
        XCTAssertFalse(MEPlayerItem.isFFmpegRuntimeCompatible(formatVersion: 60 << 16, codecVersion: codec, utilVersion: util))
        XCTAssertFalse(MEPlayerItem.isFFmpegRuntimeCompatible(formatVersion: format, codecVersion: 60 << 16, utilVersion: util))
        XCTAssertFalse(MEPlayerItem.isFFmpegRuntimeCompatible(formatVersion: format, codecVersion: codec, utilVersion: 58 << 16))
    }
}
