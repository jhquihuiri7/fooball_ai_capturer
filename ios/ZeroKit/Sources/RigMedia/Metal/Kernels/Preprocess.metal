// La entrada del detector de jugadores (IOS-21): compose_band_input de
// libs/vision/band.py en una pasada.
//
// Por cada píxel de la entrada 1920×576: su región del band.json, el rectángulo de
// fuente que le toca (el recorte redondeado, como la referencia) y la media por ÁREA
// de lo que cubre (INTER_AREA: a ×0,5 es la caja 2×2; en el mosaico, la escala que
// toque). Cada píxel de fuente se pasa antes a BGR redondeado, que es lo que hace la
// ruta de Python (Nv12ToBgr de convert.py, y luego cv2.resize). Lo que no cae en
// ninguna región sale negro. El móvil cabeza abajo lee su búfer crudo girado 180°.
//
// Dos lectores con el mismo núcleo: NV12 (producción, el FrameRing) y BGRA (el dorado
// de REF-14, que viaja en BGRA y es como lo ve Metal).

#include <metal_stdlib>
using namespace metal;

namespace preprocess {

constant int kMaxRegions = 4;

/// En este orden, como floats (DetectorInputBuilder.swift).
struct PreprocessParams {
    float regionCount;
    float flip;          // 1: el búfer crudo está girado 180°
    float srcWidth;      // tamaño del búfer de fuente (luma)
    float srcHeight;
    // BT.709 de rango limitado, coefficients() de convert.py
    float yScale;        // 255/219
    float cScale;        // 255/224
    float rV, gU, gV, bU;
    // por región: dstX, dstY, dstW, dstH, srcX, srcY, srcW, srcH (ya redondeados)
    float regions[kMaxRegions * 8];
};

static float sat8(float v) { return clamp(rint(v), 0.0f, 255.0f); }

/// Las coordenadas del búfer crudo de un píxel enderezado.
static int2 raw_of(constant PreprocessParams& p, int x, int y) {
    if (p.flip > 0.5f) return int2(int(p.srcWidth) - 1 - x, int(p.srcHeight) - 1 - y);
    return int2(x, y);
}

struct Nv12Reader {
    texture2d<float, access::read> luma;
    texture2d<float, access::read> chroma;

    float3 bgr(constant PreprocessParams& p, int x, int y) const {
        const int2 r = raw_of(p, x, y);
        const float l = (luma.read(uint2(r)).r * 255.0f - 16.0f) * p.yScale;
        const float2 c = chroma.read(uint2(r / 2)).rg * 255.0f;
        const float u = (c.x - 128.0f) * p.cScale, v = (c.y - 128.0f) * p.cScale;
        return float3(sat8(l + p.bU * u), sat8(l - p.gU * u - p.gV * v), sat8(l + p.rV * v));
    }
};

struct BgraReader {
    texture2d<float, access::read> image;

    float3 bgr(constant PreprocessParams& p, int x, int y) const {
        const float4 c = image.read(uint2(raw_of(p, x, y))) * 255.0f;
        return float3(c.b, c.g, c.r);
    }
};

/// Media por área del rectángulo de fuente que cubre el píxel de salida (INTER_AREA).
template <typename Reader>
float3 area_sample(Reader src, constant PreprocessParams& p, int region, int ox, int oy) {
    constant float* r = p.regions + region * 8;
    const float sx = r[6] / r[2], sy = r[7] / r[3];  // nativos por píxel de entrada
    const float x0 = r[4] + (float(ox) - r[0]) * sx, y0 = r[5] + (float(oy) - r[1]) * sy;
    const float x1 = x0 + sx, y1 = y0 + sy;
    float3 acc = float3(0.0f);
    for (int yy = int(floor(y0)); float(yy) < y1; ++yy) {
        const float wy = min(y1, float(yy + 1)) - max(y0, float(yy));
        if (wy <= 0.0f) continue;
        for (int xx = int(floor(x0)); float(xx) < x1; ++xx) {
            const float wx = min(x1, float(xx + 1)) - max(x0, float(xx));
            if (wx <= 0.0f) continue;
            acc += wx * wy * src.bgr(p, xx, yy);
        }
    }
    return acc / (sx * sy);
}

template <typename Reader>
void write_input(Reader src, constant PreprocessParams& p,
                 texture2d<float, access::write> out, uint2 gid) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    const int ox = int(gid.x), oy = int(gid.y);
    float3 bgr = float3(0.0f);
    for (int i = 0; i < int(p.regionCount) && i < kMaxRegions; ++i) {
        constant float* r = p.regions + i * 8;
        if (ox >= r[0] && ox < r[0] + r[2] && oy >= r[1] && oy < r[1] + r[3]) {
            bgr = area_sample(src, p, i, ox, oy);
            break;
        }
    }
    // La textura es bgra8Unorm: se escribe en orden lógico RGBA.
    out.write(float4(sat8(bgr.z), sat8(bgr.y), sat8(bgr.x), 255.0f) / 255.0f, gid);
}

}  // namespace preprocess

kernel void preprocess_nv12(texture2d<float, access::read> luma [[texture(0)]],
                            texture2d<float, access::read> chroma [[texture(1)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            constant preprocess::PreprocessParams& params [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    preprocess::write_input(preprocess::Nv12Reader{luma, chroma}, params, out, gid);
}

kernel void preprocess_bgra(texture2d<float, access::read> image [[texture(0)]],
                            texture2d<float, access::write> out [[texture(2)]],
                            constant preprocess::PreprocessParams& params [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    preprocess::write_input(preprocess::BgraReader{image}, params, out, gid);
}
