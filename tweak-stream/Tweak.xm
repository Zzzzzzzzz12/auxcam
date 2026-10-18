// AuxCamStream 鈥斺€?鐢?App 瑙ｇ爜鍚庣殑鍏变韩鍐呭瓨甯ф浛鎹㈢浉鏈鸿緭鍑恒€?
// App 璐熻矗鏀剁數鑴戣棰戝拰瑙ｇ爜锛涙彃浠跺彧璇诲彇鏈€鏂?NV12 甯у苟鏇挎崲鐩告満鏍锋湰銆?
// 閰嶇疆: /var/mobile/Media/DCIM/stream.cfg  active=1 鎵嶅共娲伙紱active=0 瀹屽叏鏀捐鐪熺浉鏈恒€?
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
#include <stdint.h>

static NSString *const kConfPath = @"/var/mobile/Media/DCIM/stream.cfg";
static const char *kFramePath = "/var/mobile/Media/DCIM/.frame.ring";
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
    int fd = open(kFramePath, O_RDWR);
    if (fd < 0) {
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"鍏变韩甯ф枃浠舵墦寮€澶辫触 errno=%d", errno);
        return NO;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"鍏变韩鍐呭瓨妫€鏌ュけ璐?errno=%d", e);
        return NO;
    }
    if ((size_t)st.st_size < kFrameMapBytes) {
        size_t actual = (size_t)st.st_size;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"鍏变韩鍐呭瓨灏哄涓嶅 actual=%zu expected=%zu", actual, kFrameMapBytes);
        return NO;
    }
    void *map = mmap(NULL, kFrameMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"鍏变韩鍐呭瓨鏄犲皠澶辫触 errno=%d", e);
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
            SLog(@"鍏变韩鍐呭瓨鐗堟湰涓嶅 magic=%u version=%u", magic, version);
        return NO;
    }
    gFrameFD = fd;
    gFrameMap = map;
    SLog(@"鍏变韩鐢婚潰鏂囦欢宸茶繛鎺?);
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
        SLog(@"鍒囧洖姝ｅ父鐩告満锛堟斁琛岋級");
        __atomic_store_n(&gActive, 0, __ATOMIC_RELEASE);
        ClearLastFrame();
    } else if (act && !wasActive) {
        SLog(@"杩涘叆閫愬抚鐩寸亴妯″紡");
        __atomic_store_n(&gActive, 1, __ATOMIC_RELEASE);
    }
}

// ---------- 鍍忕礌鎼繍 ----------
static NSString *PixelFormatName(OSType format) {
    char name[5] = {
        (char)((format >> 24) & 0xff),
        (char)((format >> 16) & 0xff),
        (char)((format >> 8) & 0xff),
        (char)(format & 0xff),
        0
    };
    return [NSString stringWithUTF8String:name] ?: @"????";
}

static UInt8 ConvertRange(UInt8 value, BOOL chroma, int mode) {
    if (mode == 0) return value;
    int span = chroma ? 224 : 219;
    int result = mode > 0
        ? (((int)value - 16) * 255 + span / 2) / span
        : 16 + ((int)value * span + 127) / 255;
    if (result < 0) result = 0;
    if (result > 255) result = 255;
    return (UInt8)result;
}

static BOOL CopyPlane(UInt8 *dst, size_t dstRow, int dstWidth, int dstHeight,
                      UInt8 *src, size_t srcRow, int srcWidth, int srcHeight,
                      int rangeMode, BOOL chroma) {
    if (!dst || !src || dstWidth <= 0 || dstHeight <= 0 || srcWidth <= 0 || srcHeight <= 0 ||
        dstRow < (size_t)dstWidth || srcRow < (size_t)srcWidth) return NO;
    if (dstWidth == srcWidth && dstHeight == srcHeight && rangeMode == 0) {
        for (int y = 0; y < dstHeight; y++)
            memcpy(dst + (size_t)y * dstRow, src + (size_t)y * srcRow, (size_t)dstWidth);
        return YES;
    }
    uint64_t xStep = ((uint64_t)srcWidth << 16) / (uint64_t)dstWidth;
    uint64_t yStep = ((uint64_t)srcHeight << 16) / (uint64_t)dstHeight;
    for (int y = 0; y < dstHeight; y++) {
        int sy = (int)(((uint64_t)y * yStep) >> 16);
        if (sy >= srcHeight) sy = srcHeight - 1;
        UInt8 *d = dst + (size_t)y * dstRow;
        UInt8 *s = src + (size_t)sy * srcRow;
        for (int x = 0; x < dstWidth; x++) {
            int sx = (int)(((uint64_t)x * xStep) >> 16);
            if (sx >= srcWidth) sx = srcWidth - 1;
            d[x] = ConvertRange(s[sx], chroma, rangeMode);
        }
    }
    return YES;
}

static BOOL Blit(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(src);
    OSType destinationFormat = CVPixelBufferGetPixelFormatType(dst);
    BOOL sourceFull = sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL sourcePlanar = sourceFull || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    BOOL destinationFull = destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL destinationPlanar = destinationFull || destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!sourcePlanar || !destinationPlanar) return NO;

    static int pixelFormatLogged = 0;
    if (!__atomic_exchange_n(&pixelFormatLogged, 1, __ATOMIC_ACQ_REL)) {
        SLog(@"鐩告満鐢婚潰鏍煎紡 source=%@ %zux%zu destination=%@ %zux%zu",
             PixelFormatName(sourceFormat), CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
             PixelFormatName(destinationFormat), CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst));
    }
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    int rangeMode = sourceFull == destinationFull ? 0 : (sourceFull ? -1 : 1);
    int sourceYWidth = (int)CVPixelBufferGetWidthOfPlane(src, 0);
    int sourceYHeight = (int)CVPixelBufferGetHeightOfPlane(src, 0);
    int destinationYWidth = (int)CVPixelBufferGetWidthOfPlane(dst, 0);
    int destinationYHeight = (int)CVPixelBufferGetHeightOfPlane(dst, 0);
    BOOL copiedY = CopyPlane((UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                             CVPixelBufferGetBytesPerRowOfPlane(dst, 0), destinationYWidth, destinationYHeight,
                             (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 0),
                             CVPixelBufferGetBytesPerRowOfPlane(src, 0), sourceYWidth, sourceYHeight,
                             rangeMode, NO);

    int sourceUVWidth = (int)CVPixelBufferGetWidthOfPlane(src, 1) * 2;
    int sourceUVHeight = (int)CVPixelBufferGetHeightOfPlane(src, 1);
    int destinationUVWidth = (int)CVPixelBufferGetWidthOfPlane(dst, 1) * 2;
    int destinationUVHeight = (int)CVPixelBufferGetHeightOfPlane(dst, 1);
    BOOL copiedUV = CopyPlane((UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                              CVPixelBufferGetBytesPerRowOfPlane(dst, 1), destinationUVWidth, destinationUVHeight,
                              (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 1),
                              CVPixelBufferGetBytesPerRowOfPlane(src, 1), sourceUVWidth, sourceUVHeight,
                              rangeMode, YES);
    if (!copiedY || !copiedUV) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return YES;
}

// ---------- 閽╁瓙 ----------
static IMP gOrigEmit = NULL;

static void AuxEmitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (__atomic_load_n(&gActive, __ATOMIC_ACQUIRE) && sb) {
        gFrames++;
        CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
        CVPixelBufferRef src = CopyLastFrame();
        if (dst && src && Blit(src, dst)) gCopied++;
        if (src) CVPixelBufferRelease(src);
        if ((gFrames % 150) == 0) {
            NSString *beat = [NSString stringWithFormat:@"camera=%d replaced=%d received=%d time=%@\n",
                              gFrames, gCopied, gDecoded, [NSDate date]];
            [beat writeToFile:kBeatPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    if (gOrigEmit) ((void (*)(id, SEL, CMSampleBufferRef))gOrigEmit)(self, _cmd, sb);
}

// ---------- 璇?App 瑙ｇ爜鍚庣殑鍏变韩甯э紝骞舵浛鎹㈢浉鏈鸿緭鍑?----------
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
                                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &pb) == kCVReturnSuccess && pb &&
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
                                SLog(@"鍏变韩甯у凡鎺ユ敹 #%d %zux%zu", gDecoded, width, height);
                        }
                        if (pb) CVPixelBufferRelease(pb);
                    }
                }
                lastSequence = sequence;
            }
            if (lastFrameAt > 0 && MonotonicSeconds() - lastFrameAt > 1.5) {
                ClearLastFrame();
                lastFrameAt = 0;
                SLog(@"鍏变韩鐢婚潰涓柇锛屽凡鏀捐鐪熺浉鏈?);
            }
        }
        usleep(15 * 1000);
    }
    return NULL;
}

__attribute__((constructor)) static void AuxCamStreamInit(void) {
    SLog(@"鍏变韩鍐呭瓨鏇挎崲鎻掍欢宸插姞杞斤紙杩涚▼ %@锛?, [[NSProcessInfo processInfo] processName]);
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
    if (!c) { SLog(@"娌℃壘鍒?BWNodeOutput"); return; }
    SEL s = NSSelectorFromString(@"emitSampleBuffer:");
    Method m = class_getInstanceMethod(c, s);
    if (!m) { SLog(@"娌℃壘鍒?emitSampleBuffer:"); return; }
    gOrigEmit = method_getImplementation(m);
    method_setImplementation(m, (IMP)AuxEmitSampleBuffer);
    SLog(@"宸叉寕閽?BWNodeOutput");
}

