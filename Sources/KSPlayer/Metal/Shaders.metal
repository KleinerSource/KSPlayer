//
//  Shaders.metal
#include <metal_stdlib>
using namespace metal;

// ITU-R BT.2100 / SMPTE ST 2084, normalized 0..10000 nits. Keep the
// intermediate math in float: half overflows in the inverse PQ division.
float3 colorPQDecode(float3 signal) {
    float3 p = pow(clamp(signal, 0.0f, 1.0f), float3(32.0f / 2523.0f));
    return pow(max(p - 3424.0f / 4096.0f, 0.0f) /
               max(2413.0f / 128.0f - 2392.0f / 128.0f * p, 1e-6f), float3(16384.0f / 2610.0f));
}

float3 colorPQEncode(float3 linear) {
    float3 p = pow(max(linear, 0.0f), float3(2610.0f / 16384.0f));
    return pow((3424.0f / 4096.0f + 2413.0f / 128.0f * p) /
               (1.0f + 2392.0f / 128.0f * p), float3(2523.0f / 32.0f));
}

float3 colorRows(float3 v, constant float4 *rows) {
    return float3(dot(v, rows[0].xyz), dot(v, rows[1].xyz), dot(v, rows[2].xyz));
}

// Public FFmpeg AVDOVIReshapingCurve polynomial and MMR semantics (ETSI
// GS CCM 001). All three components use the unmodified source triplet.
float3 colorDoviReshape(float3 signal, constant float4 *data) {
    float3 result;
    signal = clamp(signal, 0.0f, 1.0f);
    for (uint component = 0; component < 3; component++) {
        constant float4 *curve = data + 9 + component * 59;
        uint pieces = uint(curve[0].x);
        uint piece = 0;
        for (uint i = 0; i + 1 < pieces; i++) {
            if (signal[component] >= curve[1 + i / 4][i % 4]) piece = i + 1;
        }
        constant float4 *coeff = curve + 3 + piece * 7;
        float value;
        if (coeff[0].w == 0) {
            float s = signal[component];
            value = (coeff[0].z * s + coeff[0].y) * s + coeff[0].x;
        } else {
            value = coeff[0].x;
            float3 terms = signal;
            float4 cross = float4(signal.x * signal.y, signal.x * signal.z,
                                 signal.y * signal.z, signal.x * signal.y * signal.z);
            float3 powers = terms;
            float4 crossPowers = cross;
            for (uint order = 0; order < uint(coeff[0].w); order++) {
                value += dot(coeff[1 + order * 2].xyz, powers) + dot(coeff[2 + order * 2], crossPowers);
                powers *= terms;
                crossPowers *= cross;
            }
        }
        result[component] = clamp(value, curve[0].y, curve[0].z);
    }
    return result;
}

// BT.2390 EETF, PQ-domain Hermite knee with a zero-nit target black point.
// The reference SDR target is 100 nits; preserve chromaticity in linear light.
float colorBT2390(float pq, float sourceMin, float sourceMax, float targetMax) {
    float range = max(sourceMax - sourceMin, 1e-6f);
    float maxLum = clamp((targetMax - sourceMin) / range, 0.0f, 1.0f);
    float x = clamp((pq - sourceMin) / range, 0.0f, 1.0f);
    float knee = 1.5f * maxLum - 0.5f;
    if (x > knee && knee < 1.0f) {
        float t = (x - knee) / (1.0f - knee);
        float t2 = t * t, t3 = t2 * t;
        x = (2 * t3 - 3 * t2 + 1) * knee + (t3 - 2 * t2 + t) * (1 - knee)
            + (-2 * t3 + 3 * t2) * maxLum;
    }
    return clamp(x * range + sourceMin, 0.0f, targetMax);
}

float3 colorYCbCr(float3 signal, constant float4 *data) {
    float y = (signal.x - data[2].w) * data[4].w;
    float2 cbcr = (signal.yz - data[3].w) * data[5].w;
    if (data[1].w == 2) { // BT.2020 non-constant luminance
        return float3(y + 1.4746f * cbcr.y, y - 0.164553f * cbcr.x - 0.571353f * cbcr.y, y + 1.8814f * cbcr.x);
    } else if (data[1].w == 1) { // BT.709
        return float3(y + 1.5748f * cbcr.y, y - 0.187324f * cbcr.x - 0.468124f * cbcr.y, y + 1.8556f * cbcr.x);
    }
    return float3(y + 1.402f * cbcr.y, y - 0.344136f * cbcr.x - 0.714136f * cbcr.y, y + 1.772f * cbcr.x);
}

float3 colorHDR(float3 signal, constant float4 *data, bool rgbInput = false) {
    signal *= data[0].x;
    float3 linear;
    if (data[0].y == 3) {
        signal = colorDoviReshape(signal, data);
        float3 lmsPQ = colorRows(signal - data[5].xyz, data + 2);
        float3 lms = colorRows(colorPQDecode(lmsPQ), data + 6);
        // BT.2020-referred Hunt-Pointer-Estevez LMS without crosstalk.
        linear = float3(dot(lms, float3(3.06441879f, -2.16597676f, 0.10155818f)),
                        dot(lms, float3(-0.65612108f, 1.78554118f, -0.12943749f)),
                        dot(lms, float3(0.01736321f, -0.04725154f, 1.03004253f)));
    } else {
        float3 rgb = max(rgbInput ? signal : colorYCbCr(signal, data), 0.0f);
        if (data[0].y == 2) { // BT.2100 HLG inverse OETF and nominal 1000-nit OOTF
            float3 scene = select(rgb * rgb / 3.0f, (exp((rgb - 0.55991073f) / 0.17883277f) + 0.28466892f) / 12.0f, rgb > 0.5f);
            float luminance = dot(scene, float3(0.2627f, 0.6780f, 0.0593f));
            linear = scene * pow(max(luminance, 0.0f), 0.2f) * 0.1f;
        } else {
            linear = colorPQDecode(rgb);
        }
    }
    linear = max(linear, 0.0f);
    if (data[0].z != 0) return colorPQEncode(linear); // HDR layer handles display mapping
    float3 weights = data[1].z != 0 ? float3(0.2627f, 0.6780f, 0.0593f) : float3(0.2126f, 0.7152f, 0.0722f);
    float luminance = dot(linear, weights);
    float pq = colorPQEncode(float3(luminance)).x;
    float mapped = colorBT2390(pq, data[0].w, data[1].x, data[1].y);
    float target = colorPQDecode(float3(mapped)).x;
    linear *= luminance > 1e-8f ? target / luminance * 100.0f : 0.0f;
    if (data[1].z != 0) { // BT.2020 -> BT.709, linear D65
        linear = float3(dot(linear, float3(1.660491f, -0.587641f, -0.072850f)),
                        dot(linear, float3(-0.124550f, 1.132900f, -0.008349f)),
                        dot(linear, float3(-0.018151f, -0.100579f, 1.118730f)));
    }
    linear = clamp(linear, 0.0f, 1.0f);
    return select(12.92f * linear, 1.055f * pow(linear, float3(1.0f / 2.4f)) - 0.055f, linear > 0.0031308f);
}

struct VertexIn
{
    float4 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
};

vertex VertexOut mapTexture(VertexIn input [[stage_in]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

vertex VertexOut mapSphereTexture(VertexIn input [[stage_in]], constant float4x4& uniforms [[ buffer(2) ]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = uniforms * input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

fragment half4 displayColorYUV(VertexOut in [[stage_in]], texture2d<float> y [[texture(0)]],
                                texture2d<float> u [[texture(1)]], texture2d<float> v [[texture(2)]],
                                sampler s [[sampler(0)]], constant float4 *data [[buffer(3)]]) {
    float2 uv = in.textureCoordinate;
    return half4(half3(colorHDR(float3(y.sample(s, uv).r, u.sample(s, uv).r, v.sample(s, uv).r), data)), 1);
}

fragment half4 displayColorNV12(VertexOut in [[stage_in]], texture2d<float> y [[texture(0)]],
                                 texture2d<float> cbcr [[texture(1)]], sampler s [[sampler(0)]],
                                 constant float4 *data [[buffer(3)]]) {
    float2 uv = in.textureCoordinate;
    return half4(half3(colorHDR(float3(y.sample(s, uv).r, cbcr.sample(s, uv).rg), data)), 1);
}

fragment half4 displayColorRGB(VertexOut in [[stage_in]], texture2d<float> rgb [[texture(0)]],
                                sampler s [[sampler(0)]], constant float4 *data [[buffer(3)]]) {
    return half4(half3(colorHDR(rgb.sample(s, in.textureCoordinate).rgb, data, true)), 1);
}

fragment half4 displayTexture(VertexOut mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

fragment half4 displayYUVTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> yTexture [[ texture(0) ]],
                                  texture2d<half> uTexture [[ texture(1) ]],
                                  texture2d<half> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    return half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
}


fragment half4 displayNV12Texture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 yuv;
    yuv.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    return half4(half3x3(yuvToBGRMatrix)*(yuv*half3(leftShift)+half3(colorOffset)), 1);
}

half3 shaderLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(4096.0/(2523 * 128)));
    rgb = max(rgb - half3(3424./4096), 0.0) / (half3(2413./4096 * 32) - half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(4096.0 * 4 / 2610));
    return rgb;
}

half3 shaderDeLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(2610./4096 / 4));
    rgb = (half3(3424./4096) - half3(2413./4096 * 32) * rgb) / (half3(1.0) + half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(2523./4096 * 128));
    return rgb;
}

fragment half4 displayYCCTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToBGRMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]],
                                  constant uchar3& leftShift [[ buffer(2) ]])
{
    half3 ipt;
    ipt.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    ipt.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
//    half3x3 ipt2lms = half3x3{{1, 0.1952, 0.4104}, {1, -0.2278, 0.2264}, {1, 0.0652, -1.3538}};
//    half3x3 lms2rgb = half3x3{{3.238998, -0.719461, -0.002862}, {-2.272734, 1.874998, -0.268066}, {0.086733, -0.158947, 1.074494}};
    half3x3 ipt2lms = half3x3{{1, 799/8192, 1681/8192}, {1, -933/8192, 1091/8192}, {1, 267/8192, -5545/8192}};
    half3x3 lms2rgb = half3x3{{3.43661, -0.79133, -0.0259499}, {-2.50645, 1.98360, -0.0989137}, {0.06984, -0.192271, 1.12486}};
    half3 lms = ipt2lms*ipt;
    lms = shaderLinearize(lms);
    half3 rgb = lms2rgb*lms;
    rgb = shaderDeLinearize(rgb);
    return half4(rgb, 1);
}
