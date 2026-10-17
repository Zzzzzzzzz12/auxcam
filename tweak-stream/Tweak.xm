// AuxCamStream —— 用 App 解码后的共享内存帧替换相机输出。
// App 负责收电脑视频和解码；插件只读取最新 NV12 帧并替换相机样本。
// 配置: /var/mobile/Media/DCIM/stream.cfg  active=1 才干活；active=0 完全放行真相机。
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "AuxCamSharedFrame.h"
#import <objc/runtime.h>
#include <sys/stat.h>
#include <errno.h>
#include <sys/mman.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>

static NSString *const kConfPath = @"/var/mobile/Media/DCIM/stream.cfg";
static const char *kFrameShmName = "/auxcam_frame_v2";
static NSString *const kBeatPath = @"/var/mobile/Media/DCIM/.auxcam-stream-heartbeat";
static NSString *const kLogPath  = @"/var/mobile/Media/DCIM/.auxcam-stream.log";

static int gActive = 0;
static pthread_mutex_t gFrameMutex = PTHREAD_MUTEX_INITIALIZER;
static CVPixelBufferRef gLast = NULL;
static int gFrames = 0, gCopied = 0, gDecoded = 0;
static int gFrameFD = -1;
static unsigned int gMapFailures = 0;
static void *gFrameMap = MAP_FAILED;
static const size_t kFrameMapBytes = sizeof(AuxSharedFrameHeader) +
    (size_t)AUX_SHARED_FRAME_SLOT_COUNT * AUX_SHARED_FRAME_SLOT_CAPACITY;


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

static void SetLastFrame(CVPixelBufferRef frame) {
    CVPixelBufferRef old = NULL;
    pthread_mutex_lock(&gFrameMutex);
    old = gLast;
    gLast = frame ? CVPixelBufferRetain(frame) : NULL;
    pthread_mutex_unlock(&gFrameMutex);
    if (old) CVPixelBufferRelease(old);
}

static void ClearLastFrame(void) {
    SetLastFrame(NULL);
}

static CVPixelBufferRef CopyLastFrame(void) {
    pthread_mutex_lock(&gFrameMutex);
    CVPixelBufferRef frame = gLast ? CVPixelBufferRetain(gLast) : NULL;
    pthread_mutex_unlock(&gFrameMutex);
    return frame;
}

static BOOL MapSharedFrame(void) {
    if (gFrameMap != MAP_FAILED) return YES;
    int fd = shm_open(kFrameShmName, O_RDWR, 0);
    if (fd < 0) {
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"共享内存打开失败 errno=%d", errno);
        return NO;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"共享内存检查失败 errno=%d", e);
        return NO;
    }
    if ((size_t)st.st_size < kFrameMapBytes) {
        size_t actual = (size_t)st.st_size;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"共享内存尺寸不对 actual=%zu expected=%zu", actual, kFrameMapBytes);
        return NO;
    }
    void *map = mmap(NULL, kFrameMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"共享内存映射失败 errno=%d", e);
        return NO;
    }
    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)map;
    uint32_t magic = __atomic_load_n(&header->magic, __ATOMIC_ACQUIRE);
    if (magic != AUX_SHARED_FRAME_MAGIC || header->version != AUX_SHARED_FRAME_VERSION) {
        uint32_t version = header->version;
        munmap(map, kFrameMapBytes);
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"共享内存版本不对 magic=%u version=%u", magic, version);
        return NO;
    }
    gFrameFD = fd;
    gFrameMap = map;
    SLog(@"共享画面文件已连接");
    return YES;
}

static double MonotonicSeconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
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
    int wasActive = __atomic_load_n(&gActive, __ATOMIC_ACQUIRE);
    if (!act && wasActive) {
        SLog(@"切回正常相机（放行）");
        __atomic_store_n(&gActive, 0, __ATOMIC_RELEASE);
        ClearLastFrame();
    } else if (act && !wasActive) {
        SLog(@"进入逐帧直灌模式");
        __atomic_store_n(&gActive, 1, __ATOMIC_RELEASE);
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
    if (__atomic_load_n(&gActive, __ATOMIC_ACQUIRE) && sb) {
        gFrames++;
        CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
        CVPixelBufferRef src = CopyLastFrame();
        if (dst && src) {
            Blit(src, dst);
            gCopied++;
        }
        if (src) CVPixelBufferRelease(src);
        if ((gFrames % 150) == 0) {
            NSString *beat = [NSString stringWithFormat:@"camera=%d replaced=%d received=%d time=%@\n",
                              gFrames, gCopied, gDecoded, [NSDate date]];
            [beat writeToFile:kBeatPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    if (gOrigEmit) ((void (*)(id, SEL, CMSampleBufferRef))gOrigEmit)(self, _cmd, sb);
}

// ---------- 读 App 解码后的共享帧，并替换相机输出 ----------
static void *ReaderThread(void *arg) {
    (void)arg;
    uint64_t lastSequence = 0;
    double lastFrameAt = 0;
    while (1) {
        @autoreleasepool {
            if (!__atomic_load_n(&gActive, __ATOMIC_ACQUIRE)) {
                ClearLastFrame();
                if (gFrameMap != MAP_FAILED) {
                    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)gFrameMap;
                    lastSequence = __atomic_load_n(&header->sequence, __ATOMIC_ACQUIRE);
                } else {
                    lastSequence = 0;
                }
                lastFrameAt = 0;
                usleep(100 * 1000);
                continue;
            }
            if (!MapSharedFrame()) {
                usleep(100 * 1000);
                continue;
            }
            AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)gFrameMap;
            uint64_t sequence = __atomic_load_n(&header->sequence, __ATOMIC_ACQUIRE);
            if (sequence != lastSequence) {
                uint32_t index = __atomic_load_n(&header->activeSlot, __ATOMIC_ACQUIRE);
                if (index < AUX_SHARED_FRAME_SLOT_COUNT) {
                    AuxSharedFrameSlot *slot = &header->slots[index];
                    uint32_t expected = AUX_SHARED_SLOT_READY;
                    if (__atomic_compare_exchange_n(&slot->state, &expected, AUX_SHARED_SLOT_READING,
                                                    false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
                        uint32_t current = __atomic_load_n(&header->activeSlot, __ATOMIC_ACQUIRE);
                        size_t width = slot->width, height = slot->height;
                        size_t yStride = slot->yStride, uvStride = slot->uvStride;
                        size_t frameBytes = slot->frameBytes;
                        BOOL valid = current == index && width > 0 && height > 0 &&
                            width <= 4096 && height <= 2160 && !(width & 1) && !(height & 1) &&
                            yStride >= width && uvStride >= width &&
                            frameBytes >= yStride * height + uvStride * (height / 2) &&
                            frameBytes <= AUX_SHARED_FRAME_SLOT_CAPACITY;
                        CVPixelBufferRef pb = NULL;
                        if (valid && CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb) == kCVReturnSuccess && pb &&
                            CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
                            uint8_t *src = (uint8_t *)gFrameMap + sizeof(*header) +
                                (size_t)index * AUX_SHARED_FRAME_SLOT_CAPACITY;
                            uint8_t *srcUV = src + yStride * height;
                            uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
                            uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
                            size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
                            size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
                            valid = dstY && dstUV && dstYStride >= width && dstUVStride >= width;
                            if (valid) {
                                for (size_t row = 0; row < height; row++)
                                    memcpy(dstY + row * dstYStride, src + row * yStride, width);
                                for (size_t row = 0; row < height / 2; row++)
                                    memcpy(dstUV + row * dstUVStride, srcUV + row * uvStride, width);
                            }
                            CVPixelBufferUnlockBaseAddress(pb, 0);
                        } else {
                            valid = NO;
                        }
                        __atomic_store_n(&slot->state, AUX_SHARED_SLOT_READY, __ATOMIC_RELEASE);
                        if (valid && pb && __atomic_load_n(&gActive, __ATOMIC_ACQUIRE)) {
                            SetLastFrame(pb);
                            gDecoded++;
                            lastFrameAt = MonotonicSeconds();
                            if (gDecoded <= 3 || (gDecoded % 90) == 0)
                                SLog(@"共享帧已接收 #%d %zux%zu", gDecoded, width, height);
                        }
                        if (pb) CVPixelBufferRelease(pb);
                    }
                }
                lastSequence = sequence;
            }
            if (lastFrameAt > 0 && MonotonicSeconds() - lastFrameAt > 1.5) {
                ClearLastFrame();
                lastFrameAt = 0;
                SLog(@"共享画面中断，已放行真相机");
            }
        }
        usleep(15 * 1000);
    }
    return NULL;
}

__attribute__((constructor)) static void AuxCamStreamInit(void) {
    SLog(@"共享内存替换插件已加载（进程 %@）", [[NSProcessInfo processInfo] processName]);
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
