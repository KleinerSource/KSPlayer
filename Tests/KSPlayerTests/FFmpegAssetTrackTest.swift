//  FFmpegAssetTrackTest.swift
//  KSPlayerTests
//
//  Trap guard + regression tests for FFmpegAssetTrack.audioNominalFrameRate.
//

@testable import KSPlayer
import CoreMedia
import KSFFmpegBridge
import XCTest

final class FFmpegAssetTrackTest: XCTestCase {
    func testAv1UsesItsOwnSampleEntryAndConfigurationAtom() {
        XCTAssertEqual(AV_CODEC_ID_AV1.mediaSubType.rawValue, 0x61763031)
        XCTAssertEqual(FourCharCode(0x61763031).avc, "av1C")
    }

    func testAv1KeepsDimensionsAndRationalFrameRateWithoutSystemDecoder() throws {
        let context = avformat_alloc_context()
        defer { avformat_free_context(context) }
        let stream = try XCTUnwrap(avformat_new_stream(try XCTUnwrap(context), nil))
        let parameters = try XCTUnwrap(stream.pointee.codecpar)
        parameters.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        parameters.pointee.codec_id = AV_CODEC_ID_AV1
        parameters.pointee.width = 1920
        parameters.pointee.height = 1080
        parameters.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        stream.pointee.time_base = AVRational(num: 1001, den: 24000)
        stream.pointee.duration = 240
        stream.pointee.nb_frames = 240
        let track: any MediaPlayerTrack = try XCTUnwrap(FFmpegAssetTrack(stream: stream))
        XCTAssertEqual(track.naturalSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(track.nominalFrameRate, 24000.0 / 1001.0, accuracy: 0.001)

        stream.pointee.duration = 120
        let faster = try XCTUnwrap(FFmpegAssetTrack(stream: stream))
        XCTAssertEqual(faster.nominalFrameRate, 48000.0 / 1001.0, accuracy: 0.001)
        stream.pointee.duration = 0
        stream.pointee.avg_frame_rate = AVRational(num: 0, den: 1)
        stream.pointee.r_frame_rate = AVRational(num: 30000, den: 1001)
        let realRate = try XCTUnwrap(FFmpegAssetTrack(stream: stream))
        XCTAssertEqual(realRate.nominalFrameRate, 30000.0 / 1001.0, accuracy: 0.001)
    }

    func testDoviSideDataRejectsInvalidPointerFromPlaybackCrash() {
        let sideData = UnsafeMutablePointer<AVPacketSideData>(bitPattern: 0x1e5d35)
        XCTAssertNil(FFmpegAssetTrack.doviConfiguration(codedSideData: sideData, count: 24))
    }

    func testDoviSideDataRejectsMissingOrUnreasonableMetadata() {
        XCTAssertNil(FFmpegAssetTrack.doviConfiguration(codedSideData: nil, count: 24))
        let sideData = UnsafeMutablePointer<AVPacketSideData>(bitPattern: 0x1e5d35)
        XCTAssertNil(FFmpegAssetTrack.doviConfiguration(codedSideData: sideData, count: 257))
    }

    /// `AVCodecParameters.frame_size == 0` (left at 0 by most audio demuxers —
    /// AAC/MP3/Opus/FLAC/Vorbis — until the first frame is decoded): the old
    /// inline arithmetic on `FFmpegAssetTrack.swift:100` derived a fallback
    /// from `timebase.den / timebase.num`, which integer-divides to `0`
    /// whenever `den < num` (a valid `AVRational{num:3,den:1}`), so
    /// `sample_rate / 0` trapped with `Fatal error: Division by zero`. The
    /// helper must never trap; with `frame_size` unset it now falls back to
    /// codec-aware constants instead of timebase arithmetic.
    func testAudioNominalFrameRateFallbackDoesNotTrap() {
        // Non-TRUEHD codec: fallback frame size 1000 -> 48000 / 1000 == 48.
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: 48000,
            frameSize: 0,
            codecID: AV_CODEC_ID_AAC
        )
        XCTAssertEqual(rate, 48, accuracy: 0.001)
    }

    /// TRUEHD with `frame_size == 0` uses the codec-specific fallback 48
    /// (the maintainer's suggested constant): `48000 / 48 == 1000`.
    func testAudioNominalFrameRateTrueHDFallbackUses48() {
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: 48000,
            frameSize: 0,
            codecID: AV_CODEC_ID_TRUEHD
        )
        XCTAssertEqual(rate, 1000, accuracy: 0.001)
    }

    /// `sample_rate == 0` (also common pre-decode): must return the `48`
    /// floor rather than `0 / fallback`.
    func testAudioNominalFrameRateZeroSampleRate() {
        XCTAssertEqual(
            FFmpegAssetTrack.audioNominalFrameRate(sampleRate: 0, frameSize: 0, codecID: AV_CODEC_ID_AAC),
            48,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FFmpegAssetTrack.audioNominalFrameRate(sampleRate: 0, frameSize: 1024, codecID: AV_CODEC_ID_AAC),
            48,
            accuracy: 0.001
        )
    }

    /// Well-formed stream, unchanged from the pre-fix behaviour:
    /// `48000 / 1024 == 46` (Int32) -> `max(46, 48) == 48`. Regression guard.
    func testAudioNominalFrameRateWellFormedClampsToFloor() {
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: 48000,
            frameSize: 1024,
            codecID: AV_CODEC_ID_AAC
        )
        XCTAssertEqual(rate, 48, accuracy: 0.001)
    }

    /// Well-formed stream whose true rate is above the floor, using a
    /// non-evenly-dividing pair so the assertion pins INTEGER division
    /// (`48000 / 700 == 68` via Int32 truncation; a `Float / Float` refactor
    /// would yield ~68.57 and fail this assertion). Exercises the non-floor
    /// path and proves the arithmetic is byte-for-byte preserved.
    func testAudioNominalFrameRateAboveFloor() {
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: 48000,
            frameSize: 700,
            codecID: AV_CODEC_ID_MP3
        )
        XCTAssertEqual(rate, 68, accuracy: 0.001)
    }

    /// A zero `frame_size` on an arbitrary codec uses the generic fallback
    /// 1000: `44100 / 1000 == 44` -> floor `48`.
    func testAudioNominalFrameRateGenericFallbackClampsToFloor() {
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: 44100,
            frameSize: 0,
            codecID: AV_CODEC_ID_OPUS
        )
        XCTAssertEqual(rate, 48, accuracy: 0.001)
    }

    /// Negative `sample_rate` (corrupt/garbage input) maps to the `48` floor.
    /// Locks the `sampleRate > 0` guard against a future simplification.
    func testAudioNominalFrameRateNegativeSampleRate() {
        let rate = FFmpegAssetTrack.audioNominalFrameRate(
            sampleRate: -48000,
            frameSize: 960,
            codecID: AV_CODEC_ID_AAC
        )
        XCTAssertEqual(rate, 48, accuracy: 0.001)
    }

}
