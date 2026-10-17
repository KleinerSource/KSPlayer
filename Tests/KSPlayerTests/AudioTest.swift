import AVFoundation
@testable import KSPlayer
import Libavutil
import XCTest

class AudioTest: XCTestCase {
    func testSpeakerDownmixesSpatialMultichannelToStereo() {
        for channels: AVAudioChannelCount in [6, 8] {
            XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: channels, maximumChannelCount: 2, spatialAudio: true, audioRenderer: false, builtInSpeaker: true), 2)
            XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: channels, maximumChannelCount: 8, spatialAudio: true, audioRenderer: true, builtInSpeaker: true), 2)
        }
    }

    func testSpatialAudioEngineRespectsPhysicalOutputChannels() {
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 8, maximumChannelCount: 2, spatialAudio: true, audioRenderer: false, builtInSpeaker: false), 2)
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 8, maximumChannelCount: 6, spatialAudio: false, audioRenderer: false, builtInSpeaker: false), 6)
    }

    func testSpatialRendererAndExternalMultichannelRemainAvailable() {
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 8, maximumChannelCount: 2, spatialAudio: true, audioRenderer: true, builtInSpeaker: false), 8)
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 8, maximumChannelCount: 8, spatialAudio: false, audioRenderer: false, builtInSpeaker: false), 8)
    }

    func testUnknownRouteFallsBackToValidStereoAndMonoRouteIsSupported() {
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 6, maximumChannelCount: 0, spatialAudio: false, audioRenderer: false, builtInSpeaker: false), 2)
        XCTAssertEqual(KSOptions.outputNumberOfChannels(channelCount: 6, maximumChannelCount: 1, spatialAudio: false, audioRenderer: false, builtInSpeaker: false), 1)
    }

    func testSurroundDownmixDoesNotClip() throws {
        for channels: Int32 in [6, 8] {
            let output = try convert(channels: channels, activeChannels: Array(0 ..< Int(channels)))
            for plane in output {
                XCTAssertLessThanOrEqual(plane.map { abs($0) }.max() ?? 0, 1.00001)
                XCTAssertGreaterThan(plane.map { abs($0) }.max() ?? 0, 0.5)
            }
        }
    }

    func testCenterDialogueIsMixedIntoBothSpeakers() throws {
        let output = try convert(channels: 6, activeChannels: [2])
        XCTAssertEqual(output[0][128], output[1][128], accuracy: 0.00001)
        XCTAssertGreaterThan(output[0][128], 0.1)
    }

    func testSurroundKeepsLeftAndRightSeparation() throws {
        let left = try convert(channels: 6, activeChannels: [4])
        let right = try convert(channels: 6, activeChannels: [5])
        XCTAssertGreaterThan(left[0][128], 0.1)
        XCTAssertEqual(left[1][128], 0, accuracy: 0.00001)
        XCTAssertEqual(right[0][128], 0, accuracy: 0.00001)
        XCTAssertGreaterThan(right[1][128], 0.1)
    }

    func testStereoAmplitudeIsUnchanged() throws {
        let output = try convert(channels: 2, activeChannels: [0, 1])
        XCTAssertEqual(output[0][128], 0.9, accuracy: 0.00001)
        XCTAssertEqual(output[1][128], 0.9, accuracy: 0.00001)
    }

    private func convert(channels: Int32, activeChannels: [Int]) throws -> [ContiguousArray<Float>] {
        var input: UnsafeMutablePointer<AVFrame>? = try XCTUnwrap(av_frame_alloc())
        defer { av_frame_free(&input) }
        let frame = try XCTUnwrap(input)
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = 48000
        frame.pointee.nb_samples = 1024
        av_channel_layout_default(&frame.pointee.ch_layout, channels)
        XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
        for channel in 0 ..< Int(channels) {
            let data = try XCTUnwrap(frame.pointee.extended_data[channel])
            data.withMemoryRebound(to: Float.self, capacity: 1024) { samples in
                for index in 0 ..< 1024 {
                    samples[index] = activeChannels.contains(channel) ? 0.9 : 0
                }
            }
        }
        let descriptor = AudioDescriptor(frame: frame.pointee)
        // CI 的模拟器输出为双声道，测试实际生产转换器而非另一份混音实现。
        XCTAssertEqual(descriptor.audioFormat.channelCount, 2)
        let converter = AudioSwresample(audioDescriptor: descriptor)
        defer { converter.shutdown() }
        let output = try XCTUnwrap(try converter.change(avframe: frame) as? AudioFrame)
        XCTAssertEqual(output.audioFormat.channelCount, 2)
        XCTAssertEqual(output.numberOfSamples, 1024)
        return output.toFloat().map { ContiguousArray($0.prefix(Int(output.numberOfSamples))) }
    }

    func testChannelLayout() {
        for (tag, mask) in layoutMapTuple {
            assert(tag: tag, mask: mask)
        }
    }

    private func assert(tag: AudioChannelLayoutTag, mask: UInt64) {
        let channelLayout = AVAudioChannelLayout(layout: tag.channelLayout)
        XCTAssertEqual(channelLayout.channelLayout().u.mask == mask, true)
    }

    private func assert(bitmap: AudioChannelBitmap, mask: UInt64) {
        let channelLayout = AVAudioChannelLayout(layout: bitmap.channelLayout)
        XCTAssertEqual(channelLayout.channelLayout().u.mask == mask, true)
    }
}
