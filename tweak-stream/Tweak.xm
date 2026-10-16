// AuxCamStream v3 —— 逐帧直灌
// 电脑把 H.264 裸流持续写进 /var/mobile/Media/DCIM/stream.h264（每段开头都带 SPS/PPS+IDR）
// 本插件在相机进程里持续读新字节 → 硬解 → 把最新一帧直接塞进相机帧。
// 不换文件、不重启播放器：卡顿归零，延迟 = 解码一帧的时间。
// 配置: /var/mobile/Media/DCIM/stream.cfg  active=1 才干活；active=0 完全放行真相机。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>

static NSString *const kConfPath = @"/var/mobile/Media/DCIM/stream.cfg";
static NSString *const kESPath  = @"/var/mobile/Media/DCIM/stream.h264";
static NSString *const kBeatPath = @"/var/mobile/Media/DCIM/.auxcam-stream-heartbeat";
static NSString *const kLogPath  = @"/var/mobile/Media/DCIM/.auxcam-stream.log";

static BOOL gActive = NO;
static CVPixelBufferRef gLast = NULL;
static int gFrames = 0, gCopied = 0, gDecoded = 0;

static VTDecompressionSessionRef gVT = NULL;
static CMVideoFormatDescriptionRef gFmt = NULL;
static NSMutableData *gPend = nil;
static int gFmtReady = 0;

static void SLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (f) {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
        fputs(line.UTF8String, f);
        fclose(f);
    }
}

static void LoadConf(void) {
    NSString *txt = [NSString stringWithContentsOfFile:kConfPath encoding:NSUTF8StringEncoding error:nil];
    BOOL act = NO;
    if (txt) {
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([t hasPrefix:@"active"] && [t rangeOfString:@"="].location != NSNotFound) {
                NSString *v = [[t componentsSeparatedByString:@"="] lastObject];
                v = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                act = ([v isEqualToString:@"1"] || [v caseInsensitiveCompare:@"on"] == NSOrderedSame ||
                       [v caseInsensitiveCompare:@"yes"] == NSOrderedSame);
            }
        }
    }
    if (!act && gActive) {
        SLog(@"切回正常相机（放行）");
        gActive = NO;
        if (gLast) { CVPixelBufferRelease(gLast); gLast = NULL; }
    } else if (act && !gActive) {
        SLog(@"进入逐帧直灌模式");
        gActive = YES;
    }
}

static void DecoderReset(void) {
    if (gVT) { VTDecompressionSessionInvalidate(gVT); gVT = NULL; }
    if (gFmt) { CFRelease(gFmt); gFmt = NULL; }
    gFmtReady = 0;
    gPend = [NSMutableData data];
}

static void TryBuildFormat(void) {
    if (gFmtReady || !gPend.length) return;
    const uint8_t *b = (const uint8_t *)gPend.bytes;
    NSUInteger n = gPend.length;
    NSData *sps = nil, *pps = nil;
    for (NSUInteger i = 4; i + 4 < n; i++) {
        BOOL sc3 = (b[i-4]==0 && b[i-3]==0 && b[i-2]==0 && b[i-1]==1);
        BOOL sc2 = (b[i-3]==0 && b[i-2]==0 && b[i-1]==1);
        if (!sc3 && !sc2) continue;
        int t = b[i] & 0x1f;
        NSUInteger j = i;
        while (j + 3 < n) {
            if ((b[j]==0 && b[j+1]==0 && b[j+2]==1) || (b[j]==0 && b[j+1]==0 && b[j+2]==0 && b[j+3]==1)) break;
            j++;
        }
        if (j - i > 512) continue;
        NSData *d = [NSData dataWithBytes:b+i length:j-i];
        if (t == 7 && !sps) sps = d;
        if (t == 8 && !pps) pps = d;
        if (sps && pps) break;
    }
    if (!sps || !pps) return;
    const uint8_t *ps[2] = { (const uint8_t *)sps.bytes, (const uint8_t *)pps.bytes };
    size_t ls[2] = { sps.length, pps.length };
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ps, ls, 4, &gFmt);
    if (st == noErr) {
        gFmtReady = 1;
        SLog(@"格式已建立");
    }
}

static void GotFrame(void *opaque, void *srcFrame, OSStatus st, VTDecodeInfoFlags flags,
                     CVImageBufferRef img, CMTime pts, CMTime dur) {
    if (st != noErr || !img) return;
    if (gLast) CVPixelBufferRelease(gLast);
    gLast = CVPixelBufferRetain(img);
    gDecoded++;
}

static void Feed(NSData *chunk) {
    if (!gPend) gPend = [NSMutableData data];
    [gPend appendData:chunk];
    TryBuildFormat();
    if (!gFmtReady) {
        if (gPend.length > (2 << 20)) gPend = [NSMutableData data];
        return;
    }
    if (!gVT) {
        NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                                 (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
        VTDecompressionOutputCallbackRecord cb = { (VTDecompressionOutputCallback)GotFrame, NULL };
        VTDecompressionSessionCreate(kCFAllocatorDefault, gFmt, NULL, (__bridge CFDictionaryRef)attrs, &cb, &gVT);
        if (!gVT) return;
    }
    const uint8_t *b = (const uint8_t *)gPend.bytes;
    NSUInteger n = gPend.length;
    NSUInteger lastCut = 0;
    NSUInteger p = 0;
    while (p + 3 < n) {
        NSUInteger hdr = 0;
        if (b[p]==0 && b[p+1]==0 && b[p+2]==1) hdr = 3;
        else if (p+3 < n && b[p]==0 && b[p+1]==0 && b[p+2]==0 && b[p+3]==1) hdr = 4;
        if (!hdr) { p++; continue; }
        if (lastCut && p > lastCut) {
            NSUInteger len = p - lastCut - 3;   // 去掉头
            if (len > 0 && len < (4 << 20)) {
                CMBlockBufferRef bb = NULL;
                if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL, 0, len, 0, &bb) == kCMBlockBufferNoErr) {
                    char *dst = NULL;
                    CMBlockBufferGetDataPointer(bb, 0, NULL, NULL, &dst);
                    if (dst) memcpy(dst, b + lastCut + 3, len);
                    uint8_t hb[4] = { (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len };
                    CMBlockBufferRef hd = NULL;
                    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, 4, kCFAllocatorDefault, NULL, 0, 4, 0, &hd);
                    char *hdst = NULL;
                    CMBlockBufferGetDataPointer(hd, 0, NULL, NULL, &hdst);
                    if (hdst) memcpy(hdst, hb, 4);
                    CMBlockBufferRef cat = NULL;
                    CMBlockBufferCreateContiguous(kCFAllocatorDefault, hd, kCFAllocatorDefault, NULL, 0, 4, 0, &cat);
                    CMBlockBufferAppendBufferReference(cat, bb, 0, len, 0);
                    CMSampleBufferRef sb = NULL;
                    CMSampleBufferCreateReady(kCFAllocatorDefault, cat, gFmt, 1, 0, NULL, 0, NULL, &sb);
                    if (sb) {
                        VTDecompressionSessionDecodeFrame(gVT, sb, 0, NULL, NULL);
                        CFRelease(sb);
                    }
                    CFRelease(cat);
                    CFRelease(hd);
                    CFRelease(bb);
                }
            }
        }
        lastCut = p;
        p += hdr;
    }
    if (lastCut > 0 && n - lastCut < (4 << 20)) {
        [gPend setData:[NSData dataWithBytes:b+lastCut length:n-lastCut]];
    } else if (n > (4 << 20)) {
        gPend = [NSMutableData data];
    }
}

// ---------- 像素搬运 ----------
static void CopyPlane(UInt8 *d, size_t dRow, int dx, int dy, int dw, int dh,
                      UInt8 *s, size_t sRow, int sw, int sh, int planeW, int planeH) {
    for (int y = 0; y < dh; y++) {
        int sy = (int)((float)y * sh / dh);
        if (sy < 0) sy = 0; if (sy >= sh) sy = sh - 1;
        UInt8 *dp = d + (size_t)(y + dy) * dRow + dx;
        UInt8 *sp = s + (size_t)sy * sRow;
        for (int x = 0; x < dw; x++) {
            int sx = (int)((float)x * sw / dw);
            if (sx < 0) sx = 0; if (sx >= sw) sx = sw - 1;
            dp[x] = sp[sx];
        }
    }
}

static void Blit(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    OSType sf = CVPixelBufferGetPixelFormatType(src);
    OSType df = CVPixelBufferGetPixelFormatType(dst);
    BOOL sPlanar = (sf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || sf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    BOOL dPlanar = (df == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || df == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!sPlanar || !dPlanar) return;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) { CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly); return; }
    int sw = (int)CVPixelBufferGetWidthOfPlane(src, 0), sh = (int)CVPixelBufferGetHeightOfPlane(src, 0);
    int dw = (int)CVPixelBufferGetWidthOfPlane(dst, 0), dh = (int)CVPixelBufferGetHeightOfPlane(dst, 0);
    UInt8 *sp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 0);
    UInt8 *dp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    size_t sRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0), dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    if (sp && dp && sw > 0 && sh > 0 && dw > 0 && dh > 0) CopyPlane(dp, dRow, 0, 0, dw, dh, sp, sRow, sw, sh, dw, dh);
    int scw = (int)CVPixelBufferGetWidthOfPlane(src, 1), sch = (int)CVPixelBufferGetHeightOfPlane(src, 1);
    int dcw = (int)CVPixelBufferGetWidthOfPlane(dst, 1), dch = (int)CVPixelBufferGetHeightOfPlane(dst, 1);
    UInt8 *scp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 1);
    UInt8 *dcp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t scRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1), dcRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
    if (scp && dcp && scw > 0 && sch > 0 && dcw > 0 && dch > 0) {
        for (int y = 0; y < dch; y++) {
            int sy = (int)((float)y * sch / dch);
            if (sy >= sch) sy = sch - 1;
            UInt8 *dpp = dcp + (size_t)y * dcRow;
            UInt8 *spp = scp + (size_t)sy * scRow;
            for (int x = 0; x < dcw * 2; x++) {
                int sx = (int)((float)x * (scw * 2) / (dcw * 2));
                if (sx >= scw * 2) sx = scw * 2 - 1;
                dpp[x] = spp[sx];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
}

// ---------- 钩子 ----------
static IMP gOrigEmit = NULL;

static void AuxEmitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (gActive && sb) {
        gFrames++;
        CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
        if (dst && gLast) {
            Blit(gLast, dst);
            gCopied++;
        }
        if ((gFrames % 150) == 0) {
            NSString *beat = [NSString stringWithFormat:@"frames=%d copied=%d decoded=%d fmt=%d time=%@\n",
                              gFrames, gCopied, gDecoded, gFmtReady, [NSDate date]];
            [beat writeToFile:kBeatPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    if (gOrigEmit) ((void (*)(id, SEL, CMSampleBufferRef))gOrigEmit)(self, _cmd, sb);
}

// ---------- 读流线程 ----------
static void *ReaderThread(void *arg) {
    (void)arg;
    int fd = -1;
    uint64_t off = 0;
    while (1) {
        @autoreleasepool {
            if (!gActive) { usleep(200 * 1000); if (fd >= 0) { close(fd); fd = -1; } continue; }
            if (fd < 0) {
                fd = open(kESPath.UTF8String, O_RDONLY);
                off = 0;
                if (fd < 0) { usleep(200 * 1000); continue; }
            }
            struct stat st;
            if (fstat(fd, &st) == 0) {
                if ((uint64_t)st.st_size < off) {
                    off = 0;
                    lseek(fd, 0, SEEK_SET);
                    DecoderReset();
                }
                if ((uint64_t)st.st_size > off) {
                    size_t want = (size_t)(st.st_size - off);
                    if (want > (1 << 20)) want = 1 << 20;
                    uint8_t *buf = (uint8_t *)malloc(want);
                    ssize_t rd = read(fd, buf, want);
                    if (rd > 0) {
                        Feed([NSData dataWithBytesNoCopy:buf length:rd freeWhenDone:YES]);
                        off += rd;
                    } else {
                        free(buf);
                    }
                }
            }
        }
        usleep(40 * 1000);
    }
    return NULL;
}

__attribute__((constructor)) static void AuxCamStreamInit(void) {
    SLog(@"v3 已加载（进程 %@）", [[NSProcessInfo processInfo] processName]);
    LoadConf();
    pthread_t t;
    pthread_create(&t, NULL, ReaderThread, NULL);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (;;) {
            @autoreleasepool { LoadConf(); }
            [NSThread sleepForTimeInterval:1.0];
        }
    });
    Class c = objc_getClass("BWNodeOutput");
    if (!c) c = NSClassFromString(@"BWNodeOutput");
    if (!c) { SLog(@"没找到 BWNodeOutput"); return; }
    SEL s = NSSelectorFromString(@"emitSampleBuffer:");
    Method m = class_getInstanceMethod(c, s);
    if (!m) { SLog(@"没找到 emitSampleBuffer:"); return; }
    gOrigEmit = method_getImplementation(m);
    method_setImplementation(m, (IMP)AuxEmitSampleBuffer);
    SLog(@"已挂钩 BWNodeOutput");
}
