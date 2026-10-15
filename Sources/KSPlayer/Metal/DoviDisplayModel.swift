import AVFoundation
import Metal
import simd

/// Frame-local Dolby Vision / HDR color processing, independent of geometry.
/// System sample-buffer rendering never uses this model.
final class DoviDisplayModel {
    private var pipelines = [String: MTLRenderPipelineState]()

    func pipeline(planeCount: Int, display: DisplayEnum, format: MTLPixelFormat) -> MTLRenderPipelineState {
        let name = planeCount == 3 ? "displayColorYUV" : (planeCount == 2 ? "displayColorNV12" : "displayColorRGB")
        let sphere = display != .plane
        let key = "\(name)-\(sphere)-\(format.rawValue)"
        if let state = pipelines[key] { return state }
        let state = MetalRender.makePipelineState(fragmentFunction: name, isSphere: sphere, pixelFormat: format)
        pipelines[key] = state
        return state
    }

    func set(frame: VideoVTBFrame, pixelBuffer: PixelBufferProtocol, hdrOutput: Bool, encoder: MTLRenderCommandEncoder) {
        var data = frame.doviMetadata?.shaderData ?? [SIMD4<Float>](repeating: .zero, count: 186)
        // CV P010 is MSB aligned; FFmpeg yuv420p10le is LSB aligned.
        // Normalize both to code/(2^depth-1), including the 65535/65472 factor.
        let depth = min(16, max(8, pixelBuffer.bitDepth))
        if pixelBuffer.planeCount > 1, depth > 8 {
            let codeMax = Float((UInt32(1) << depth) - 1)
            let shift = pixelBuffer.leftShift > 0 ? 0 : 16 - depth
            data[0].x = 65535 / (codeMax * Float(UInt32(1) << shift))
        } else {
            data[0].x = 1
        }
        if frame.doviMetadata == nil {
            data[0].y = pixelBuffer.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG ? 2 : 1
            data[1].x = 0.7518271 // PQ(1000 nits), default when no peak metadata
            if let peak = frame.contentPeakNits, peak > 0 { data[1].x = Self.pqEncode(peak / 10000) }
        }
        data[0].z = hdrOutput ? 1 : 0
        data[1].y = Self.pqEncode(0.01) // 100-nit SDR reference white
        data[1].z = pixelBuffer.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 || frame.doviMetadata != nil ? 1 : 0
        data[1].w = pixelBuffer.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 ? 2 :
            (pixelBuffer.yCbCrMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 ? 1 : 0)
        // Exact 8/10/12/16-bit legal-range offsets and scales, used only for
        // ordinary YCbCr. RPU matrices already contain their own range mapping.
        let codeMax = Float((UInt32(1) << depth) - 1)
        let factor = Float(UInt32(1) << max(0, depth - 8))
        data[2].w = pixelBuffer.isFullRangeVideo ? 0 : 16 * factor / codeMax
        data[3].w = 128 * factor / codeMax
        data[4].w = pixelBuffer.isFullRangeVideo ? 1 : codeMax / (219 * factor)
        data[5].w = pixelBuffer.isFullRangeVideo ? 1 : codeMax / (224 * factor)
        data.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress { encoder.setFragmentBytes(address, length: bytes.count, index: 3) }
        }
    }

    private static func pqEncode(_ value: Float) -> Float {
        let p = pow(max(0, value), 2610.0 / 16384.0)
        return pow((3424.0 / 4096.0 + 2413.0 / 128.0 * p) / (1 + 2392.0 / 128.0 * p), 2523.0 / 32.0)
    }
}
