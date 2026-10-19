// Metal source, compiled at runtime (no Xcode / metal toolchain required).
// Struct layouts must match `Uniforms` / `PresetParams` in Swift: floats only, same order.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct P {
    float zoom, zoomBeat, zoomExp, rot, rotBeat, warp, warpScale, warpSpeed;
    float swirl, dx, dy, decay, hueDrift, kaleido, mirror, cx, cy;
    float waveLine, waveCircle, spectrumRing, spectrumBars, sparkles, orbs;
    float waveScale, waveThick, hueSpread, saturation, echo, brightness;
};

struct U {
    float time, dt, resX, resY;
    float bass, mid, treb, bassAtt, midAtt, trebAtt;
    float loudness, kick, hat, onset, beat, beatPhase, rhythm, centroid, hue, flash, seed, rotSign;
    P p;
};

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vmain(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) { return vnoise(p) * 0.65 + vnoise(p * 2.03 + 7.1) * 0.35; }

static float2 curl(float2 p) {
    const float e = 0.07;
    float a = fbm(p + float2(0, e)), b = fbm(p - float2(0, e));
    float c = fbm(p + float2(e, 0)), d = fbm(p - float2(e, 0));
    return float2(a - b, -(c - d)) / (2.0 * e);
}

static float2 rot2(float2 v, float a) { float c = cos(a), s = sin(a); return float2(c * v.x - s * v.y, s * v.x + c * v.y); }

static float3 hsv2rgb(float h, float s, float v) {
    float3 k = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    return v * mix(float3(1.0), clamp(k - 1.0, 0.0, 1.0), s);
}

// Rotate hue by rotating around the grey axis (Rodrigues).
static float3 hueRotate(float3 c, float a) {
    const float3 k = float3(0.57735);
    float ca = cos(a);
    return c * ca + cross(k, c) * sin(a) + k * dot(k, c) * (1.0 - ca);
}

static float sampleArr(constant float* a, int n, float x) {
    float f = clamp(x, 0.0, 1.0) * float(n - 1);
    int i = int(f);
    int j = min(i + 1, n - 1);
    return mix(a[i], a[j], f - float(i));
}

fragment float4 warpFrag(VOut in [[stage_in]],
                         constant U& u [[buffer(0)]],
                         constant float* wave [[buffer(1)]],
                         constant float* spec [[buffer(2)]],
                         texture2d<float> prev [[texture(0)]]) {
    constexpr sampler sm(address::mirrored_repeat, filter::linear);
    float aspect = u.resX / u.resY;
    float dt = u.dt;
    float2 p = in.uv - 0.5;
    p.x *= aspect;
    float2 c = float2(u.p.cx, u.p.cy) + 0.03 * float2(sin(u.time * 0.21 + u.seed), cos(u.time * 0.17 + u.seed * 2.0));
    float2 q = p - c;

    // ---- symmetry -------------------------------------------------------
    float2 qs = q;
    if (u.p.mirror > 0.5) qs.x = abs(qs.x);
    if (u.p.kaleido > 1.5) {
        float seg = 6.2831853 / floor(u.p.kaleido);
        float a = atan2(qs.y, qs.x) + u.time * 0.05 * u.rotSign;
        a = fmod(a + 100.0 * seg, seg);
        a = abs(a - seg * 0.5);
        qs = length(qs) * float2(cos(a), sin(a));
    }
    float r = length(qs);

    // ---- per-frame motion (MilkDrop-style warp of the previous frame) ----
    float z = u.p.zoom + u.p.zoomBeat * u.beat;
    z = pow(max(z, 0.5), pow(max(u.p.zoomExp, 0.05), r * 2.0 - 1.0));
    float2 src = qs / pow(z, dt);
    float ang = (u.p.rot * u.rotSign + u.p.rotBeat * u.beat * u.rotSign) * dt + u.p.swirl * dt * exp(-r * 3.0);
    src = rot2(src, ang);
    src += 0.01 * dt * u.p.warp * (0.6 + 0.6 * u.loudness)
         * curl(src * u.p.warpScale + float2(u.time * u.p.warpSpeed, u.seed));
    src -= 0.01 * dt * float2(u.p.dx, -u.p.dy);
    float2 suv = src + c;
    suv.x /= aspect;
    suv += 0.5;

    float3 col = prev.sample(sm, suv).rgb;
    col *= pow(u.p.decay, dt);
    col = max(col - 0.0015 * dt, 0.0);
    col = hueRotate(col, u.p.hueDrift * dt);

    // ---- new elements ---------------------------------------------------
    float3 add = float3(0);
    float hue = u.hue;
    float sat = u.p.saturation;
    float energy = 0.35 + 0.65 * u.loudness;
    float th = 0.0025 + 0.004 * u.p.waveThick;

    if (u.p.waveLine > 0.001) {
        float x = in.uv.x;
        float w = sampleArr(wave, 512, x) * 0.22 * u.p.waveScale * energy;
        float y = (u.p.mirror > 0.5) ? abs(q.y) - 0.12 : q.y;
        float d = abs(y - w);
        add += u.p.waveLine * hsv2rgb(hue + x * u.p.hueSpread, sat, 1.0) * exp(-d * d / (th * th)) * 0.9;
    }
    if (u.p.waveCircle > 0.001) {
        float a = atan2(q.y, q.x) / 6.2831853 + 0.5;
        float x = abs(a * 2.0 - 1.0);
        float rr = length(q);
        float R = 0.18 + 0.05 * u.bassAtt + 0.06 * u.beat + sampleArr(wave, 512, x) * 0.07 * u.p.waveScale * energy;
        float d = abs(rr - R);
        add += u.p.waveCircle * hsv2rgb(hue + x * u.p.hueSpread + 0.5 * u.p.hueSpread, sat, 1.0) * exp(-d * d / (th * th)) * 0.9;
    }
    if (u.p.spectrumRing > 0.001) {
        float a = atan2(q.y, q.x) / 6.2831853 + 0.5;
        float x = abs(a * 2.0 - 1.0);
        float s = sampleArr(spec, 64, x);
        float rr = length(q);
        float R0 = 0.28 + 0.03 * u.beat;
        float bar = smoothstep(0.5, 0.35, abs(fract(x * 48.0) - 0.5));
        float inside = smoothstep(R0 - 0.004, R0, rr) * smoothstep(R0 + s * s * 0.3 + 0.004, R0 + s * s * 0.3, rr);
        add += u.p.spectrumRing * inside * bar * hsv2rgb(hue + 0.3 + x * u.p.hueSpread, sat, 0.8);
    }
    if (u.p.spectrumBars > 0.001) {
        float x = abs(in.uv.x - 0.5) * 2.0;
        float s = sampleArr(spec, 64, x);
        float yy = abs(in.uv.y - 0.5) * 2.0;           // mirrored top & bottom
        float h = s * s * 0.6;
        float bar = smoothstep(0.5, 0.3, abs(fract(x * 64.0) - 0.5));
        float m = smoothstep(1.0 - h - 0.01, 1.0 - h, yy) * bar;
        add += u.p.spectrumBars * m * hsv2rgb(hue + 0.6 - x * u.p.hueSpread, sat, 0.6);
    }
    if (u.p.sparkles > 0.001) {
        float2 g = p * 34.0;
        float2 cell = floor(g);
        float h = hash21(cell + floor(u.time * 9.0) * 1.37 + u.seed);
        float chance = u.p.sparkles * (0.05 * u.hat + 0.04 * u.onset + 0.012 * u.treb);
        if (h < chance) {
            float2 f = fract(g) - 0.5;
            float sp = exp(-dot(f, f) * 40.0);
            add += sp * hsv2rgb(hue + hash21(cell) * 0.5, sat * 0.6, 1.4);
        }
    }
    if (u.p.orbs > 0.001) {
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float t = u.time * (0.11 + 0.05 * fi) + u.seed * (fi + 1.0);
            float2 op = float2(cos(t * 1.3 + fi), sin(t * 0.9 + fi * 2.1)) * float2(0.35 * aspect, 0.3);
            float d2 = dot(p - op, p - op);
            float size = 0.0006 * (1.0 + 2.5 * u.kick * u.rhythm + 1.5 * u.onset * (1.0 - u.rhythm) + u.loudness);
            add += u.p.orbs * hsv2rgb(hue + fi * 0.08 * (1.0 + u.p.hueSpread * 4.0), sat, 1.0) * size / (d2 + 0.0015);
        }
    }
    // Kick punch in the middle (only when the music has a pulse).
    add += hsv2rgb(hue + 0.1, sat * 0.7, 1.0) * u.kick * u.rhythm * exp(-length(q) * 12.0) * 0.15;

    col += add * u.p.brightness * min(dt, 2.0);
    return float4(clamp(col, 0.0, 4.0), 1.0);
}

fragment float4 compositeFrag(VOut in [[stage_in]],
                              constant U& u [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler sm(address::mirrored_repeat, filter::linear);
    float2 uv = in.uv;
    float2 dir = uv - 0.5;
    float ca = 0.006 * u.kick * u.rhythm + 0.01 * u.flash;
    float3 col;
    col.r = tex.sample(sm, uv + dir * ca).r;
    col.g = tex.sample(sm, uv).g;
    col.b = tex.sample(sm, uv - dir * ca).b;
    if (u.p.echo > 0.001) {
        // MilkDrop "video echo": a flipped, scaled copy blended over the frame.
        float2 euv = (uv - 0.5) / 1.35 + 0.5;
        euv.x = 1.0 - euv.x;
        float3 e = tex.sample(sm, euv).rgb;
        col = mix(col, max(col, e), u.p.echo * 0.6);
    }
    col = 1.0 - exp(-col * 1.4);                       // soft tonemap
    col += u.flash * 0.22 * float3(1.0, 0.95, 0.9);
    col *= 1.0 - 0.55 * dot(dir, dir);                  // vignette
    col += (hash21(uv * float2(u.resX, u.resY) + u.time) - 0.5) / 255.0;   // dither
    return float4(col, 1.0);
}
"""
