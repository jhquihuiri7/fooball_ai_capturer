// La parte de una cámara en el programa (IOS-40): render_view de
// libs/vision/gpu/reproject.py, de un solo lado, sobre NV12.
//
// Por cada píxel del programa: p = H·(x, y, 1) lleva a la cámara; w ≤ 0 es que la
// cámara no lo ve; lo que cae en la franja del código de tiempo (con su margen) se
// lee fuera de la imagen, como mask_blind; y el resto se interpola bilineal con lo de
// fuera a NEGRO, como INTER_LINEAR con BORDER_CONSTANT sobre BGR. La interpolación se
// hace en RGB, toma a toma, porque el cero de la referencia es negro y en NV12 negro
// no es cero. Luego la ganancia por canal y de vuelta a NV12.
//
// Cada hilo pinta un bloque 2×2: cuatro lumas y la croma media de los cuatro.
// La costura no se pinta aquí: el maestro la recalcula desde la vista (IOS-41).

#include <metal_stdlib>
using namespace metal;

// BT.709 de rango limitado, el '420v' de la cámara y del codificador.
constant float kKr = 0.2126f;
constant float kKb = 0.0722f;
constant float kKg = 1.0f - kKr - kKb;
constant float kLumaOffset = 16.0f;
constant float kLumaRange = 219.0f;
constant float kChromaOffset = 128.0f;
constant float kChromaRange = 224.0f;

/// Parámetros por fotograma, empaquetados como floats en este orden (ver
/// ReprojectKernel.swift): la homografía por filas, la ganancia en el orden BGR de la
/// referencia, la zona ciega ya ensanchada y el tamaño de la luma de la fuente.
struct ReprojectParams {
    float h[9];
    float gainB;
    float gainG;
    float gainR;
    float blindX0;
    float blindY0;
    float blindX1;
    float blindY1;
    float srcWidth;
    float srcHeight;
};

static float sat8(float v) { return clamp(rint(v), 0.0f, 255.0f); }

/// Un texel de la fuente en RGB 0–255, sin redondear (la conversión es lineal).
static float3 texel_rgb(texture2d<float, access::read> luma,
                        texture2d<float, access::read> chroma,
                        int x, int y) {
    const float y8 = luma.read(uint2(x, y)).r * 255.0f;
    const float2 c8 = chroma.read(uint2(x / 2, y / 2)).rg * 255.0f;
    const float yn = (y8 - kLumaOffset) / kLumaRange;
    const float cb = (c8.x - kChromaOffset) / kChromaRange;
    const float cr = (c8.y - kChromaOffset) / kChromaRange;
    const float r = yn + 2.0f * (1.0f - kKr) * cr;
    const float b = yn + 2.0f * (1.0f - kKb) * cb;
    const float g = (yn - kKr * r - kKb * b) / kKg;
    return float3(r, g, b) * 255.0f;
}

/// Bilineal con lo de fuera a negro y saturado a entero, como `sample` de kernels.py.
static float3 sample_rgb(texture2d<float, access::read> luma,
                         texture2d<float, access::read> chroma,
                         int w, int h, float x, float y) {
    float3 acc = float3(0.0f);
    const float fx0 = floor(x), fy0 = floor(y);
    const int x0 = int(fx0), y0 = int(fy0);
    const float ax = x - fx0, ay = y - fy0;
    for (int dy = 0; dy < 2; ++dy) {
        const int yy = y0 + dy;
        if (yy < 0 || yy >= h) continue;
        const float wy = dy ? ay : 1.0f - ay;
        for (int dx = 0; dx < 2; ++dx) {
            const int xx = x0 + dx;
            if (xx < 0 || xx >= w) continue;
            const float wgt = wy * (dx ? ax : 1.0f - ax);
            acc += wgt * clamp(texel_rgb(luma, chroma, xx, yy), 0.0f, 255.0f);
        }
    }
    return float3(sat8(acc.x), sat8(acc.y), sat8(acc.z));
}

static float3 part_pixel(texture2d<float, access::read> luma,
                         texture2d<float, access::read> chroma,
                         constant ReprojectParams& p, float x, float y) {
    const float w = p.h[6] * x + p.h[7] * y + p.h[8];
    if (w <= 0.0f) return float3(0.0f);
    const float u = (p.h[0] * x + p.h[1] * y + p.h[2]) / w;
    const float v = (p.h[3] * x + p.h[4] * y + p.h[5]) / w;
    if (u >= p.blindX0 && u < p.blindX1 && v >= p.blindY0 && v < p.blindY1) {
        return float3(0.0f);
    }
    const float3 rgb = sample_rgb(luma, chroma, int(p.srcWidth), int(p.srcHeight), u, v);
    return float3(sat8(rgb.x * p.gainR), sat8(rgb.y * p.gainG), sat8(rgb.z * p.gainB));
}

static float luma8(float3 rgb) {
    const float yn = (kKr * rgb.x + kKg * rgb.y + kKb * rgb.z) / 255.0f;
    return kLumaOffset + kLumaRange * yn;
}

kernel void reproject_part(texture2d<float, access::read> srcLuma [[texture(0)]],
                           texture2d<float, access::read> srcChroma [[texture(1)]],
                           texture2d<float, access::write> dstLuma [[texture(2)]],
                           texture2d<float, access::write> dstChroma [[texture(3)]],
                           constant ReprojectParams& params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dstChroma.get_width() || gid.y >= dstChroma.get_height()) return;
    float3 suma = float3(0.0f);
    for (uint dy = 0; dy < 2; ++dy) {
        for (uint dx = 0; dx < 2; ++dx) {
            const uint2 px = uint2(gid.x * 2 + dx, gid.y * 2 + dy);
            const float3 rgb = part_pixel(srcLuma, srcChroma, params, float(px.x), float(px.y));
            dstLuma.write(float4(rint(luma8(rgb)) / 255.0f), px);
            suma += rgb;
        }
    }
    const float3 media = suma / 4.0f;
    const float yn = luma8(media);
    const float ynorm = (yn - kLumaOffset) / kLumaRange;
    const float cb = (media.z / 255.0f - ynorm) / (2.0f * (1.0f - kKb));
    const float cr = (media.x / 255.0f - ynorm) / (2.0f * (1.0f - kKr));
    dstChroma.write(float4(rint(kChromaOffset + kChromaRange * cb) / 255.0f,
                           rint(kChromaOffset + kChromaRange * cr) / 255.0f, 0.0f, 0.0f), gid);
}
