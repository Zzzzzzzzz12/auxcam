// AuxScale.h - plain C helpers for copying a NV12 frame into a camera buffer.
// Pure C on purpose, so it can be unit-tested on any machine.
//
// What it does differently from the old per-pixel code in Tweak.xm:
//   1. Range conversion (video <-> full) uses a 256-entry lookup table instead of arithmetic per pixel.
//   2. When the aspect ratios differ, it crops the centre of the source ("cover") instead of stretching.
//   3. The interleaved CbCr plane is scaled in PAIRS. The old code scaled it byte by byte,
//      which could swap Cb and Cr and corrupt colours whenever the sizes were different.
#ifndef AUX_SCALE_H
#define AUX_SCALE_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define AUX_SCALE_MAX_WIDTH 4096

// mode: 0 = same range, >0 = video range -> full range, <0 = full range -> video range
static inline uint8_t AuxConvertRange(uint8_t value, int chroma, int mode) {
    if (mode == 0) return value;
    int span = chroma ? 224 : 219;
    int result = mode > 0
        ? (((int)value - 16) * 255 + span / 2) / span
        : 16 + ((int)value * span + 127) / 255;
    if (result < 0) result = 0;
    if (result > 255) result = 255;
    return (uint8_t)result;
}

static inline void AuxBuildRangeLut(uint8_t lut[256], int chroma, int mode) {
    for (int i = 0; i < 256; i++) lut[i] = AuxConvertRange((uint8_t)i, chroma, mode);
}

// Find the centred region of the source (sw x sh) that has the same aspect ratio as the
// destination (dw x dh). All four numbers are even, as NV12 requires.
static inline void AuxComputeCover(int sw, int sh, int dw, int dh,
                                   int *cx, int *cy, int *cw, int *ch) {
    int w = sw, h = sh;
    if (sw > 0 && sh > 0 && dw > 0 && dh > 0) {
        long long a = (long long)sw * dh;   // compare sw/sh with dw/dh
        long long b = (long long)dw * sh;
        if (a > b)      w = (int)(((long long)sh * dw) / dh);   // source is wider: crop the sides
        else if (a < b) h = (int)(((long long)sw * dh) / dw);   // source is taller: crop top and bottom
    }
    if (w > sw) w = sw;
    if (h > sh) h = sh;
    w &= ~1; h &= ~1;
    if (w < 2) w = (sw >= 2) ? 2 : sw;
    if (h < 2) h = (sh >= 2) ? 2 : sh;
    *cw = w; *ch = h;
    *cx = ((sw - w) / 2) & ~1;
    *cy = ((sh - h) / 2) & ~1;
}

// Luma plane: scale the source region (cx,cy,cw,ch) to dw x dh, nearest neighbour sampled at pixel centres.
static inline int AuxCopyLuma(uint8_t *dst, size_t dstRow, int dw, int dh,
                              const uint8_t *src, size_t srcRow,
                              int cx, int cy, int cw, int ch, int rangeMode) {
    if (!dst || !src || dw <= 0 || dh <= 0 || cw <= 0 || ch <= 0 || dw > AUX_SCALE_MAX_WIDTH) return 0;
    if (dstRow < (size_t)dw || srcRow < (size_t)(cx + cw)) return 0;
    const uint8_t *s0 = src + (size_t)cy * srcRow + (size_t)cx;
    if (dw == cw && dh == ch && rangeMode == 0) {
        for (int y = 0; y < dh; y++) memcpy(dst + (size_t)y * dstRow, s0 + (size_t)y * srcRow, (size_t)dw);
        return 1;
    }
    uint8_t lut[256];
    AuxBuildRangeLut(lut, 0, rangeMode);
    int xmap[AUX_SCALE_MAX_WIDTH];
    for (int x = 0; x < dw; x++) xmap[x] = (int)(((uint64_t)(2 * x + 1) * (uint64_t)cw) / (uint64_t)(2 * dw));
    for (int y = 0; y < dh; y++) {
        int sy = (int)(((uint64_t)(2 * y + 1) * (uint64_t)ch) / (uint64_t)(2 * dh));
        const uint8_t *sp = s0 + (size_t)sy * srcRow;
        uint8_t *dp = dst + (size_t)y * dstRow;
        if (rangeMode == 0) { for (int x = 0; x < dw; x++) dp[x] = sp[xmap[x]]; }
        else                { for (int x = 0; x < dw; x++) dp[x] = lut[sp[xmap[x]]]; }
    }
    return 1;
}

// Chroma plane (CbCr interleaved, one pair per 2x2 luma pixels). dw/dh and cx/cy/cw/ch are in LUMA pixels.
static inline int AuxCopyChroma(uint8_t *dst, size_t dstRow, int dw, int dh,
                                const uint8_t *src, size_t srcRow,
                                int cx, int cy, int cw, int ch, int rangeMode) {
    int dpw = dw / 2, dph = dh / 2, spw = cw / 2, sph = ch / 2;
    if (!dst || !src || dpw <= 0 || dph <= 0 || spw <= 0 || sph <= 0 || dpw > AUX_SCALE_MAX_WIDTH) return 0;
    if (dstRow < (size_t)dpw * 2 || srcRow < (size_t)(cx / 2 + spw) * 2) return 0;
    const uint8_t *s0 = src + (size_t)(cy / 2) * srcRow + (size_t)(cx / 2) * 2;
    if (dpw == spw && dph == sph && rangeMode == 0) {
        for (int y = 0; y < dph; y++) memcpy(dst + (size_t)y * dstRow, s0 + (size_t)y * srcRow, (size_t)dpw * 2);
        return 1;
    }
    uint8_t lut[256];
    AuxBuildRangeLut(lut, 1, rangeMode);
    int xmap[AUX_SCALE_MAX_WIDTH];
    for (int x = 0; x < dpw; x++) xmap[x] = (int)(((uint64_t)(2 * x + 1) * (uint64_t)spw) / (uint64_t)(2 * dpw));
    for (int y = 0; y < dph; y++) {
        int sy = (int)(((uint64_t)(2 * y + 1) * (uint64_t)sph) / (uint64_t)(2 * dph));
        const uint8_t *sp = s0 + (size_t)sy * srcRow;
        uint8_t *dp = dst + (size_t)y * dstRow;
        for (int x = 0; x < dpw; x++) {
            const uint8_t *p = sp + (size_t)xmap[x] * 2;   // always take Cb and Cr from the same source pair
            dp[2 * x]     = lut[p[0]];
            dp[2 * x + 1] = lut[p[1]];
        }
    }
    return 1;
}

// ---------------------------------------------------------------------------------------------
// Smooth (bilinear) versions. Same arguments and same meaning as AuxCopyLuma / AuxCopyChroma,
// but every output pixel blends the 4 nearest source pixels instead of picking one.
// Sample positions are pixel centres; weights are 8-bit; identical size + same range = exact copy.
// ---------------------------------------------------------------------------------------------
static inline void AuxBuildAxis(int dstN, int srcN, int16_t *i0, int16_t *i1, uint8_t *w) {
    for (int x = 0; x < dstN; x++) {
        long long pos = (((long long)(2 * x + 1) * srcN * 65536LL) / (2LL * dstN)) - 32768LL;
        if (pos < 0) pos = 0;
        long long ix = pos >> 16;
        if (ix > srcN - 1) ix = srcN - 1;
        long long ix1 = ix + 1 < srcN ? ix + 1 : srcN - 1;
        i0[x] = (int16_t)ix;
        i1[x] = (int16_t)ix1;
        w[x] = (uint8_t)((pos & 0xFFFF) >> 8);
    }
}

static inline int AuxScaleLuma(uint8_t *dst, size_t dstRow, int dw, int dh,
                               const uint8_t *src, size_t srcRow,
                               int cx, int cy, int cw, int ch, int rangeMode) {
    if (!dst || !src || dw <= 0 || dh <= 0 || cw <= 0 || ch <= 0 || dw > AUX_SCALE_MAX_WIDTH || cw > AUX_SCALE_MAX_WIDTH) return 0;
    if (dstRow < (size_t)dw || srcRow < (size_t)(cx + cw)) return 0;
    if (dw == cw && dh == ch) return AuxCopyLuma(dst, dstRow, dw, dh, src, srcRow, cx, cy, cw, ch, rangeMode);
    uint8_t lut[256];
    AuxBuildRangeLut(lut, 0, rangeMode);
    int16_t xi0[AUX_SCALE_MAX_WIDTH], xi1[AUX_SCALE_MAX_WIDTH];
    uint8_t xw[AUX_SCALE_MAX_WIDTH];
    AuxBuildAxis(dw, cw, xi0, xi1, xw);
    const uint8_t *s0 = src + (size_t)cy * srcRow + (size_t)cx;
    for (int y = 0; y < dh; y++) {
        long long pos = (((long long)(2 * y + 1) * ch * 65536LL) / (2LL * dh)) - 32768LL;
        if (pos < 0) pos = 0;
        int iy = (int)(pos >> 16);
        if (iy > ch - 1) iy = ch - 1;
        int iy1 = iy + 1 < ch ? iy + 1 : ch - 1;
        unsigned wy = (unsigned)((pos & 0xFFFF) >> 8);
        const uint8_t *r0 = s0 + (size_t)iy * srcRow;
        const uint8_t *r1 = s0 + (size_t)iy1 * srcRow;
        uint8_t *dp = dst + (size_t)y * dstRow;
        for (int x = 0; x < dw; x++) {
            unsigned wx = xw[x];
            unsigned top = r0[xi0[x]] * (256 - wx) + r0[xi1[x]] * wx;
            unsigned bot = r1[xi0[x]] * (256 - wx) + r1[xi1[x]] * wx;
            dp[x] = lut[(top * (256 - wy) + bot * wy + 32768) >> 16];
        }
    }
    return 1;
}

static inline int AuxScaleChroma(uint8_t *dst, size_t dstRow, int dw, int dh,
                                 const uint8_t *src, size_t srcRow,
                                 int cx, int cy, int cw, int ch, int rangeMode) {
    int dpw = dw / 2, dph = dh / 2, spw = cw / 2, sph = ch / 2;
    if (!dst || !src || dpw <= 0 || dph <= 0 || spw <= 0 || sph <= 0 || dpw > AUX_SCALE_MAX_WIDTH || spw > AUX_SCALE_MAX_WIDTH) return 0;
    if (dstRow < (size_t)dpw * 2 || srcRow < (size_t)(cx / 2 + spw) * 2) return 0;
    if (dpw == spw && dph == sph) return AuxCopyChroma(dst, dstRow, dw, dh, src, srcRow, cx, cy, cw, ch, rangeMode);
    uint8_t lut[256];
    AuxBuildRangeLut(lut, 1, rangeMode);
    int16_t xi0[AUX_SCALE_MAX_WIDTH], xi1[AUX_SCALE_MAX_WIDTH];
    uint8_t xw[AUX_SCALE_MAX_WIDTH];
    AuxBuildAxis(dpw, spw, xi0, xi1, xw);
    const uint8_t *s0 = src + (size_t)(cy / 2) * srcRow + (size_t)(cx / 2) * 2;
    for (int y = 0; y < dph; y++) {
        long long pos = (((long long)(2 * y + 1) * sph * 65536LL) / (2LL * dph)) - 32768LL;
        if (pos < 0) pos = 0;
        int iy = (int)(pos >> 16);
        if (iy > sph - 1) iy = sph - 1;
        int iy1 = iy + 1 < sph ? iy + 1 : sph - 1;
        unsigned wy = (unsigned)((pos & 0xFFFF) >> 8);
        const uint8_t *r0 = s0 + (size_t)iy * srcRow;
        const uint8_t *r1 = s0 + (size_t)iy1 * srcRow;
        uint8_t *dp = dst + (size_t)y * dstRow;
        for (int x = 0; x < dpw; x++) {
            unsigned wx = xw[x];
            const uint8_t *a = r0 + (size_t)xi0[x] * 2, *b = r0 + (size_t)xi1[x] * 2;
            const uint8_t *c = r1 + (size_t)xi0[x] * 2, *d = r1 + (size_t)xi1[x] * 2;
            for (int k = 0; k < 2; k++) {   // k=0 Cb, k=1 Cr, both from the same four source pairs
                unsigned top = a[k] * (256 - wx) + b[k] * wx;
                unsigned bot = c[k] * (256 - wx) + d[k] * wx;
                dp[2 * x + k] = lut[(top * (256 - wy) + bot * wy + 32768) >> 16];
            }
        }
    }
    return 1;
}

#endif
