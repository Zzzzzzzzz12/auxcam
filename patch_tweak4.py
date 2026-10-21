# patch_tweak4.py -- (1) poll the shared frame every 1 ms instead of 4 ms, (2) reuse pixel buffers from a pool
#                       so the slot is held for less time and fewer frames are lost
# usage: python3 patch_tweak4.py path/to/Tweak.xm   (apply after patch_tweak3.py)
import sys
p = sys.argv[1]
raw = open(p, 'rb').read()
crlf = b'\r\n' in raw
s = raw.decode('utf-8').replace('\r\n', '\n')
if 'AUXPOOL' in s:
    print('already patched'); sys.exit(0)
helper = '''// AUXPOOL: reuse pixel buffers instead of allocating 2-3 MB of fresh memory for every received frame
static CVPixelBufferPoolRef gAuxPool = NULL;
static size_t gAuxPoolW = 0, gAuxPoolH = 0;
static CVReturn AuxCreateBuffer(size_t w, size_t h, CVPixelBufferRef *out) {
    if (!gAuxPool || gAuxPoolW != w || gAuxPoolH != h) {
        if (gAuxPool) { CVPixelBufferPoolRelease(gAuxPool); gAuxPool = NULL; }
        NSDictionary *bufferAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (id)kCVPixelBufferWidthKey: @(w),
            (id)kCVPixelBufferHeightKey: @(h)
        };
        NSDictionary *poolAttrs = @{ (id)kCVPixelBufferPoolMinimumBufferCountKey: @4 };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)poolAttrs,
                                    (__bridge CFDictionaryRef)bufferAttrs, &gAuxPool) != kCVReturnSuccess) gAuxPool = NULL;
        gAuxPoolW = w; gAuxPoolH = h;
    }
    if (gAuxPool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, gAuxPool, out) == kCVReturnSuccess && *out)
        return kCVReturnSuccess;
    return CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, out);
}

'''
marker = '// ---------- read the App\'s shared frames and replace the camera output ----------\n'
a1 = '''if (valid && CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &pb) == kCVReturnSuccess && pb &&'''
b1 = 'if (valid && AuxCreateBuffer(width, height, &pb) == kCVReturnSuccess && pb &&'
a2 = 'usleep(4 * 1000);'
b2 = 'usleep(1000);'
for a in (marker, a1, a2):
    assert s.count(a) == 1, 'pattern not found: ' + a[:60]
s = s.replace(marker, helper + marker).replace(a1, b1).replace(a2, b2)
if crlf: s = s.replace('\n', '\r\n')
open(p, 'wb').write(s.encode('utf-8'))
print('patched OK', p)
