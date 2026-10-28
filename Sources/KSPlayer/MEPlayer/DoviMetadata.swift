import Foundation
import libavutil
import simd

/// A value copy of the public FFmpeg 8.1 metadata. No AVFrame or RPU pointers
/// survive decoding; frame queues and seeking can release their source buffers.
struct DoviMetadata {
    let profile: Int
    let shaderData: [SIMD4<Float>]

    init?(frame: UnsafeMutablePointer<AVFrame>, profile: Int?) {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA)?.pointee,
              side.size >= MemoryLayout<AVDOVIMetadata>.size, let bytes = side.data
        else { return nil }
        let raw = UnsafeRawPointer(bytes)
        let metadata = raw.loadUnaligned(as: AVDOVIMetadata.self)
        func contains(_ offset: Int, _ size: Int) -> Bool {
            offset >= MemoryLayout<AVDOVIMetadata>.size && offset <= side.size && size <= side.size - offset
        }
        guard contains(metadata.header_offset, MemoryLayout<AVDOVIRpuDataHeader>.size),
              contains(metadata.mapping_offset, MemoryLayout<AVDOVIDataMapping>.size),
              contains(metadata.color_offset, MemoryLayout<AVDOVIColorMetadata>.size)
        else { return nil }
        let header = raw.advanced(by: metadata.header_offset).loadUnaligned(as: AVDOVIRpuDataHeader.self)
        let mapping = raw.advanced(by: metadata.mapping_offset).loadUnaligned(as: AVDOVIDataMapping.self)
        let color = raw.advanced(by: metadata.color_offset).loadUnaligned(as: AVDOVIColorMetadata.self)
        let guessedProfile: Int
        if header.vdr_rpu_profile == 0, header.bl_video_full_range_flag != 0 {
            guessedProfile = 5
        } else if header.vdr_rpu_profile == 1 {
            guessedProfile = header.el_spatial_resampling_filter_flag != 0 && header.disable_residual_flag == 0 ?
                (header.vdr_bit_depth == 12 ? 7 : 4) : 8
        } else { guessedProfile = 0 }
        let profile = profile ?? guessedProfile
        // FEL/NLQ composition requires a second decoded layer. Profile 7 uses BL.
        guard profile == 5 || profile == 8,
              header.bl_bit_depth >= 8, header.bl_bit_depth <= 16,
              header.coef_log2_denom <= 32
        else { return nil }
        let nonlinear = doviElements(color.ycc_to_rgb_matrix, AVRational.self)
        let linear = doviElements(color.rgb_to_lms_matrix, AVRational.self)
        let offset = doviElements(color.ycc_to_rgb_offset, AVRational.self)
        guard (nonlinear + linear + offset).allSatisfy({ $0.den != 0 }) else { return nil }
        func value(_ rational: AVRational) -> Float { Float(rational.num) / Float(rational.den) }
        func row(_ values: [AVRational], _ index: Int) -> SIMD4<Float> {
            SIMD4(value(values[index * 3]), value(values[index * 3 + 1]), value(values[index * 3 + 2]), 0)
        }
        // Uniforms are float4 rows (not Swift/C matrix structs). This keeps the
        // Metal layout identical on arm64 and x86_64 and below the 4 KiB limit.
        // Rows 0-1: processing flags/peaks; 2-4: nonlinear matrix; 5: offset;
        // 6-8: linear matrix; 9-185: 3 curves, each header + 2 pivot rows +
        // 8 pieces * 7 coefficient rows. w padding also carries YCbCr range.
        var data = [SIMD4<Float>](repeating: .zero, count: 186)
        data[0].y = 3 // Dolby IPT-PQ; 1 = ordinary PQ, 2 = HLG
        data[0].w = Float(color.source_min_pq) / 4095
        data[1].x = color.source_max_pq > color.source_min_pq ? Float(color.source_max_pq) / 4095 : 0.7518271
        for i in 0 ..< 3 {
            data[2 + i] = row(nonlinear, i)
            data[6 + i] = row(linear, i)
        }
        data[5] = SIMD4(value(offset[0]), value(offset[1]), value(offset[2]), 0)
        let denominator = Float(UInt64(1) << header.coef_log2_denom)
        let maxCode = Float((UInt32(1) << header.bl_bit_depth) - 1)
        for (component, curve) in doviElements(mapping.curves, AVDOVIReshapingCurve.self).enumerated() {
            let count = Int(curve.num_pivots)
            guard count >= 2, count <= 9 else { return nil }
            let pivots = doviElements(curve.pivots, UInt16.self).map { Float($0) / maxCode }
            guard zip(pivots.prefix(count - 1), pivots.dropFirst().prefix(count - 1)).allSatisfy({ $0.0 < $0.1 }) else { return nil }
            let base = 9 + component * 59
            data[base] = SIMD4(Float(count - 1), pivots[0], pivots[count - 1], 0)
            for i in 0 ..< 8 { data[base + 1 + i / 4][i % 4] = pivots[min(i + 1, count - 1)] }
            let methods = Array(tuple: curve.mapping_idc)
            let polyOrders = Array(tuple: curve.poly_order)
            let poly = doviElements(curve.poly_coef, Int64.self)
            let mmrOrders = Array(tuple: curve.mmr_order)
            let constants = Array(tuple: curve.mmr_constant)
            let mmr = doviElements(curve.mmr_coef, Int64.self)
            for i in 0 ..< count - 1 {
                let piece = base + 3 + i * 7
                if methods[i] == AV_DOVI_MAPPING_POLYNOMIAL {
                    guard polyOrders[i] >= 1, polyOrders[i] <= 2 else { return nil }
                    let coefficients = Array(poly[(i * 3) ..< (i * 3 + 3)])
                    data[piece] = SIMD4(Float(coefficients[0]) / denominator, Float(coefficients[1]) / denominator,
                                       polyOrders[i] == 2 ? Float(coefficients[2]) / denominator : 0, 0)
                } else if methods[i] == AV_DOVI_MAPPING_MMR {
                    let order = Int(mmrOrders[i])
                    guard order >= 1, order <= 3 else { return nil }
                    data[piece] = SIMD4(Float(constants[i]) / denominator, 0, 0, Float(order))
                    for j in 0 ..< order {
                        let start = i * 21 + j * 7
                        let c = mmr[start ..< start + 7].map { Float($0) / denominator }
                        data[piece + 1 + j * 2] = SIMD4(c[0], c[1], c[2], 0)
                        data[piece + 2 + j * 2] = SIMD4(c[3], c[4], c[5], c[6])
                    }
                } else { return nil }
            }
        }
        guard data.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else { return nil }
        self.profile = profile
        shaderData = data
    }
}

/// Imported C fixed arrays are Swift tuples, with the element stride defined
/// by the pinned FFmpeg headers. The returned array always owns its storage.
private func doviElements<Tuple, Element>(_ tuple: Tuple, _: Element.Type) -> [Element] {
    withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Element.self)) }
}
