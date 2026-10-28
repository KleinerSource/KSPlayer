import Foundation
import libavutil

/// Copies frame properties before the decoder reuses an AVFrame. SMPTE ST
/// 2086 / CTA-861.3 payloads use the byte order and units required by CoreVideo.
struct VideoDisplayMetadata {
    let dovi: DoviMetadata?
    let rpu: Data?
    let edr: EDRMetaData
    let peakNits: Float?

    init(frame: UnsafeMutablePointer<AVFrame>, profile: Int?) {
        dovi = DoviMetadata(frame: frame, profile: profile)
        if let side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER)?.pointee, let bytes = side.data {
            rpu = Data(bytes: bytes, count: side.size)
        } else { rpu = nil }
        func get<T>(_ type: AVFrameSideDataType, _: T.Type) -> T? {
            guard let side = av_frame_get_side_data(frame, type)?.pointee,
                  side.size >= MemoryLayout<T>.size, let bytes = side.data
            else { return nil }
            return UnsafeRawPointer(bytes).loadUnaligned(as: T.self)
        }
        func scaled(_ value: AVRational, _ factor: Double) -> Double {
            value.den != 0 ? (Double(value.num) / Double(value.den) * factor).rounded() : 0
        }
        var display: MasteringDisplayMetadata?
        var content: ContentLightMetadata?
        var ambient: AmbientViewingEnvironment?
        var peak: Float?
        if let info = get(AV_FRAME_DATA_MASTERING_DISPLAY_METADATA, AVMasteringDisplayMetadata.self) {
            if info.has_primaries != 0, info.has_luminance != 0 {
                func chroma(_ value: AVRational) -> UInt16 { UInt16(max(0, min(65535, scaled(value, 50000)))).bigEndian }
                func luminance(_ value: AVRational) -> UInt32 { UInt32(max(0, min(Double(UInt32.max), scaled(value, 10000)))).bigEndian }
                display = MasteringDisplayMetadata(
                    display_primaries_g_x: chroma(info.display_primaries.1.0), display_primaries_g_y: chroma(info.display_primaries.1.1),
                    display_primaries_b_x: chroma(info.display_primaries.2.0), display_primaries_b_y: chroma(info.display_primaries.2.1),
                    display_primaries_r_x: chroma(info.display_primaries.0.0), display_primaries_r_y: chroma(info.display_primaries.0.1),
                    white_point_x: chroma(info.white_point.0), white_point_y: chroma(info.white_point.1),
                    maxLuminance: luminance(info.max_luminance), minLuminance: luminance(info.min_luminance))
            }
            if info.has_luminance != 0, info.max_luminance.den != 0 {
                peak = Float(info.max_luminance.num) / Float(info.max_luminance.den)
            }
        }
        if let info = get(AV_FRAME_DATA_CONTENT_LIGHT_LEVEL, AVContentLightMetadata.self) {
            content = ContentLightMetadata(MaxCLL: UInt16(clamping: info.MaxCLL).bigEndian, MaxFALL: UInt16(clamping: info.MaxFALL).bigEndian)
            if info.MaxCLL > 0 { peak = Float(info.MaxCLL) }
        }
        if let info = get(AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT, AVAmbientViewingEnvironment.self) {
            ambient = AmbientViewingEnvironment(
                ambient_illuminance: UInt32(max(0, min(Double(UInt32.max), scaled(info.ambient_illuminance, 10000)))).bigEndian,
                ambient_light_x: UInt16(max(0, min(65535, scaled(info.ambient_light_x, 50000)))).bigEndian,
                ambient_light_y: UInt16(max(0, min(65535, scaled(info.ambient_light_y, 50000)))).bigEndian)
        }
        edr = EDRMetaData(displayData: display, contentData: content, ambientViewingEnvironment: ambient)
        peakNits = peak
    }
}
