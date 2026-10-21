import AVFoundation
import Libavformat
@testable import KSPlayer
import XCTest

final class AV1DecodeTest: XCTestCase {
    // Resources/av1-seek.ivf 是 libaom-av1 编码的三秒 32x32/6fps 测试图。
    // ffmpeg -f lavfi -i testsrc2=s=32x32:r=6:d=3 -c:v libaom-av1 -cpu-used 8 -crf 50 -g 6 -f ivf av1-seek.ivf
    func testAv1DecodesAfterRepeatedSeekFlush() throws {
        for _ in 0 ..< 2 {
            try withDecoder { context, asset, decoder in
                // 先读取完整文件建立索引，然后测试顺序不同的前后定位和续播。
                while let packet = readPacket(context: context, asset: asset) {
                    try decode(packet, with: decoder)
                }
                for seconds in [1.5, 0.2, 2.5, 1.0] {
                    XCTAssertGreaterThanOrEqual(av_seek_frame(context, -1, Int64(seconds * Double(AV_TIME_BASE)), AVSEEK_FLAG_BACKWARD), 0)
                    decoder.doFlushCodec()
                    var rendered = false
                    while let packet = readPacket(context: context, asset: asset), !rendered {
                        rendered = try decode(packet, with: decoder)
                    }
                    XCTAssertTrue(rendered, "AV1 在 \(seconds)s 定位后未恢复输出")
                }
            }
        }
    }

    func testAv1CanReopenAtSavedPositionWithoutDecodingFromStart() throws {
        for _ in 0 ..< 2 {
            try withDecoder { context, asset, decoder in
                // IVF 没有容器索引；仅建立解复用索引，不向新解码器发送开头帧。
                while readPacket(context: context, asset: asset) != nil {}
                XCTAssertGreaterThanOrEqual(av_seek_frame(context, -1, 1_500_000, AVSEEK_FLAG_BACKWARD), 0)
                decoder.doFlushCodec()
                var rendered = false
                while let packet = readPacket(context: context, asset: asset), !rendered {
                    rendered = try decode(packet, with: decoder)
                }
                XCTAssertTrue(rendered, "新 AV1 解码器未能从非零续播位置输出")
            }
        }
    }

    func testInvalidAv1PacketDoesNotPreventFollowingKeyFrame() throws {
        try withDecoder { context, asset, decoder in
            let broken = Packet()
            let core = try XCTUnwrap(broken.corePacket)
            XCTAssertEqual(av_new_packet(core, 1), 0)
            core.pointee.data[0] = 0xFF // forbidden_bit=1 的无效 OBU
            broken.assetTrack = asset
            XCTAssertFalse(try decode(broken, with: decoder))
            var rendered = false
            while let packet = readPacket(context: context, asset: asset), !rendered {
                rendered = try decode(packet, with: decoder)
            }
            XCTAssertTrue(rendered)
        }
    }

    private func withDecoder(_ body: (UnsafeMutablePointer<AVFormatContext>, FFmpegAssetTrack, FFmpegDecode) throws -> Void) throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "av1-seek", withExtension: "ivf"))
        var pointer: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&pointer, url.path, nil, nil), 0)
        defer { avformat_close_input(&pointer) }
        let context = try XCTUnwrap(pointer)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        let stream = try XCTUnwrap(context.pointee.streams[0])
        let asset = try XCTUnwrap(FFmpegAssetTrack(stream: stream))
        XCTAssertEqual(asset.naturalSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(asset.nominalFrameRate, 6, accuracy: 0.001)
        let options = KSOptions()
        options.hardwareDecode = false
        options.decoderOptions["threads"] = "1"
        options.codecLowDelay = true
        let decoder = FFmpegDecode(assetTrack: asset, options: options)
        defer { decoder.shutdown() }
        try body(context, asset, decoder)
    }

    private func readPacket(context: UnsafeMutablePointer<AVFormatContext>, asset: FFmpegAssetTrack) -> Packet? {
        let packet = Packet()
        guard av_read_frame(context, packet.corePacket) >= 0 else { return nil }
        packet.assetTrack = asset
        return packet
    }

    @discardableResult
    private func decode(_ packet: Packet, with decoder: FFmpegDecode) throws -> Bool {
        var rendered = false
        var error: Error?
        decoder.decodeFrame(from: packet) { result in
            switch result {
            case let .success(frame):
                rendered = (frame as? VideoVTBFrame)?.corePixelBuffer != nil
            case let .failure(failure):
                error = failure
            }
        }
        if let error { throw error }
        return rendered
    }
}
