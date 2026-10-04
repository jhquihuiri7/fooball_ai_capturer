// El programa del maestro (IOS-41): compose_nv12 de libs/vision/gpu/compose.py y la
// mezcla de la costura de render_view, en una pasada sobre NV12.
//
// Entran la parte propia del maestro (ya reproyectada por reproject_part, IOS-40) y
// la del esclavo (decodificada), las dos NV12 1920×1080 con negro donde su cámara no
// llega. Por cada píxel: la costura con el peso recalculado desde la vista; encima,
// el gráfico RGBA SIN premultiplicar (Image.alpha_composite); en la franja, el
// anuncio premultiplicado con su alfa inversa (StripBlender); y NV12 BT.709 de rango
// limitado con los coeficientes exactos de compose_reference. Cada hilo, un 2×2.

#include <metal_stdlib>
using namespace metal;

// Los helpers van en su espacio de nombres: sin metallib, MetalContext compila todas
// las fuentes juntas y dos `sat8` chocarían.
namespace compose {

// compose_reference (tools/golden/evaluate_compose.py), sobre RGB 0–255.
constant float kYr = 0.182586f, kYg = 0.614231f, kYb = 0.062007f;
constant float kUr = -0.100644f, kUg = -0.338572f, kUb = 0.439216f;
constant float kVr = 0.439216f, kVg = -0.398942f, kVb = -0.040274f;

/// En este orden, como floats (ComposeProgramKernel.swift).
struct ComposeParams {
    float useMaster;
    float useSlave;
    float masterIsLeft;
    float hasGraphic;
    float stripTop;      // primera fila de la franja; ≥ alto si no hay anuncio
    float toRig[6];      // filas 0 y 2 de la pose de la vista
    float focal;
    float cx;
    float cy;
    float seamYaw;
    float feather;
};

static float sat8(float v) { return clamp(rint(v), 0.0f, 255.0f); }

/// RGB 0–255 de un píxel de una parte NV12 (la inversa de reproject_part).
static float3 part_rgb(texture2d<float, access::read> luma,
                       texture2d<float, access::read> chroma, uint2 px) {
    const float yn = (luma.read(px).r * 255.0f - 16.0f) / 219.0f;
    const float2 c = (chroma.read(px / 2).rg * 255.0f - 128.0f) / 224.0f;
    const float kr = 0.2126f, kb = 0.0722f;
    const float r = yn + 2.0f * (1.0f - kr) * c.y;
    const float b = yn + 2.0f * (1.0f - kb) * c.x;
    const float g = (yn - kr * r - kb * b) / (1.0f - kr - kb);
    return clamp(float3(r, g, b) * 255.0f, 0.0f, 255.0f);
}

/// El peso de la cámara izquierda en este píxel, como render_view.
static float left_weight(constant ComposeParams& p, float x, float y) {
    const float xc = (x - p.cx) / p.focal, yc = (y - p.cy) / p.focal;
    const float yaw = atan2(p.toRig[0] * xc + p.toRig[1] * yc + p.toRig[2],
                            p.toRig[3] * xc + p.toRig[4] * yc + p.toRig[5]);
    return clamp(0.5f - (yaw - p.seamYaw) / p.feather, 0.0f, 1.0f);
}

static float3 program_pixel(texture2d<float, access::read> mLuma,
                            texture2d<float, access::read> mChroma,
                            texture2d<float, access::read> sLuma,
                            texture2d<float, access::read> sChroma,
                            texture2d<float, access::read> graphic,
                            texture2d<float, access::read> stripPremul,
                            texture2d<float, access::read> stripInv,
                            constant ComposeParams& p, uint2 px) {
    float3 rgb = float3(0.0f);
    const bool master = p.useMaster > 0.5f, slave = p.useSlave > 0.5f;
    if (master && slave) {
        const float wl = left_weight(p, float(px.x), float(px.y));
        const float wm = p.masterIsLeft > 0.5f ? wl : 1.0f - wl;
        const float3 m = part_rgb(mLuma, mChroma, px), s = part_rgb(sLuma, sChroma, px);
        rgb = float3(sat8(wm * m.x + (1.0f - wm) * s.x), sat8(wm * m.y + (1.0f - wm) * s.y),
                     sat8(wm * m.z + (1.0f - wm) * s.z));
    } else if (master) {
        const float3 m = part_rgb(mLuma, mChroma, px);
        rgb = float3(sat8(m.x), sat8(m.y), sat8(m.z));
    } else if (slave) {
        const float3 s = part_rgb(sLuma, sChroma, px);
        rgb = float3(sat8(s.x), sat8(s.y), sat8(s.z));
    }
    if (p.hasGraphic > 0.5f) {
        const float4 g = graphic.read(px);
        const float3 grgb = g.rgb * 255.0f;
        rgb = float3(rint(grgb.x * g.a + rgb.x * (1.0f - g.a)),
                     rint(grgb.y * g.a + rgb.y * (1.0f - g.a)),
                     rint(grgb.z * g.a + rgb.z * (1.0f - g.a)));
    }
    if (float(px.y) >= p.stripTop) {
        const uint2 sp = uint2(px.x, px.y - uint(p.stripTop));
        const float3 premul = stripPremul.read(sp).rgb * 255.0f;
        const float3 inv = stripInv.read(sp).rgb * 255.0f;
        rgb = min(float3(rint(rgb.x * inv.x / 255.0f), rint(rgb.y * inv.y / 255.0f),
                         rint(rgb.z * inv.z / 255.0f)) + premul, 255.0f);
    }
    return rgb;
}

}  // namespace compose

kernel void compose_program(texture2d<float, access::read> mLuma [[texture(0)]],
                            texture2d<float, access::read> mChroma [[texture(1)]],
                            texture2d<float, access::read> sLuma [[texture(2)]],
                            texture2d<float, access::read> sChroma [[texture(3)]],
                            texture2d<float, access::read> graphic [[texture(4)]],
                            texture2d<float, access::read> stripPremul [[texture(5)]],
                            texture2d<float, access::read> stripInv [[texture(6)]],
                            texture2d<float, access::write> dstLuma [[texture(7)]],
                            texture2d<float, access::write> dstChroma [[texture(8)]],
                            constant compose::ComposeParams& params [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dstChroma.get_width() || gid.y >= dstChroma.get_height()) return;
    float3 suma = float3(0.0f);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 px = uint2(gid.x * 2 + dx, gid.y * 2 + dy);
            const float3 rgb = compose::program_pixel(mLuma, mChroma, sLuma, sChroma, graphic,
                                             stripPremul, stripInv, params, px);
            const float y = clamp(rint(16.0f + compose::kYr * rgb.x + compose::kYg * rgb.y + compose::kYb * rgb.z), 0.0f, 255.0f);
            dstLuma.write(float4(y / 255.0f), px);
            suma += rgb;
        }
    }
    const float3 m = suma / 4.0f;
    const float u = clamp(rint(128.0f + compose::kUr * m.x + compose::kUg * m.y + compose::kUb * m.z), 0.0f, 255.0f);
    const float v = clamp(rint(128.0f + compose::kVr * m.x + compose::kVg * m.y + compose::kVb * m.z), 0.0f, 255.0f);
    dstChroma.write(float4(u / 255.0f, v / 255.0f, 0.0f, 0.0f), gid);
}
