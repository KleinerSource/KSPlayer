import Foundation
import libavcodec
import libavutil

/// ISO vpcC payload (including FullBox version/flags), using public codec data.
func vp9Configuration(_ parameters: AVCodecParameters) -> Data? {
    let format = AVPixelFormat(rawValue: parameters.format)
    guard let descriptor = av_pix_fmt_desc_get(format) else { return nil }
    let depth = descriptor.pointee.comp.0.depth
    guard [8, 10, 12].contains(depth) else { return nil }
    var horizontal: Int32 = 0
    var vertical: Int32 = 0
    guard av_pix_fmt_get_chroma_sub_sample(format, &horizontal, &vertical) == 0 else { return nil }
    let chroma: UInt8
    switch (horizontal, vertical) {
    case (1, 1): chroma = parameters.chroma_location == AVCHROMA_LOC_LEFT ? 0 : 1
    case (1, 0): chroma = 2
    case (0, 0): chroma = 3
    default: return nil
    }
    let profile = parameters.profile == AV_PROFILE_UNKNOWN
        ? Int32((chroma < 2 ? 0 : 1) + (depth == 8 ? 0 : 2)) : parameters.profile
    guard (0 ... 3).contains(profile) else { return nil }
    // Like the previous no-bitstream path, infer the level from picture size
    // when the demuxer has not supplied one (no frame rate is available here).
    let pictureSize = Int64(parameters.width) * Int64(parameters.height)
    let levels: [(Int64, Int32)] = [
        (36864, 10), (73728, 11), (122880, 20), (245760, 21),
        (552960, 30), (983040, 31), (2228224, 40), (8912896, 50), (35651584, 60),
    ]
    let inferred = pictureSize > 0 ? levels.first(where: { pictureSize <= $0.0 })?.1 ?? 0 : 0
    let level = parameters.level == AV_LEVEL_UNKNOWN ? inferred : parameters.level
    guard (0 ... 255).contains(level) else { return nil }
    let range: UInt8 = parameters.color_range == AVCOL_RANGE_JPEG ? 1 : 0
    return Data([1, 0, 0, 0, UInt8(profile), UInt8(level),
                 UInt8(depth << 4) | chroma << 1 | range,
                 UInt8(truncatingIfNeeded: parameters.color_primaries.rawValue),
                 UInt8(truncatingIfNeeded: parameters.color_trc.rawValue),
                 UInt8(truncatingIfNeeded: parameters.color_space.rawValue), 0, 0])
}
