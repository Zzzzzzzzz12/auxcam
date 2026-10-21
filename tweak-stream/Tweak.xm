// AuxCamStream - replaces the camera output with the shared NV12 frames decoded by the App.
// The App receives and decodes the PC video; this plugin only reads the latest NV12 frame and swaps the camera sample.
// Config: /var/mobile/Media/DCIM/stream.cfg  active=1 enables replacement; active=0 passes the real camera through.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "AuxCamSharedFrame.h"
#include "AuxScale.h"
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
            SLog(@"shared frame file open failed errno=%d", errno);
        return NO;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"shared memory check failed errno=%d", e);
        return NO;
    }
    if ((size_t)st.st_size < kFrameMapBytes) {
        size_t actual = (size_t)st.st_size;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"shared memory size mismatch actual=%zu expected=%zu", actual, kFrameMapBytes);
        return NO;
    }
    void *map = mmap(NULL, kFrameMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        int e = errno;
        close(fd);
        gMapFailures++;
        if (gMapFailures == 1 || (gMapFailures % 100) == 0)
            SLog(@"shared memory map failed errno=%d", e);
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
            SLog(@"shared memory version mismatch magic=%u version=%u", magic, version);
        return NO;
    }
    gFrameFD = fd;
    gFrameMap = map;
    SLog(@"shared frame file connected");
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
        SLog(@"switched back to the real camera (pass-through)");
        __atomic_store_n(&gActive, 0, __ATOMIC_RELEASE);
        ClearLastFrame();
    } else if (act && !wasActive) {
        SLog(@"entered frame-injection mode");
        __atomic_store_n(&gActive, 1, __ATOMIC_RELEASE);
    }
}

// ---------- frame blit ----------
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

// Log every distinct camera output (format + size) once, including the ones we cannot replace,
// so the log shows which outputs are skipped.
static pthread_mutex_t gFormatLogLock = PTHREAD_MUTEX_INITIALIZER;
static void LogFormatOnce(OSType srcFmt, size_t sw, size_t sh, OSType dstFmt, size_t dw, size_t dh, BOOL usable) {
    static uint64_t seen[8];
    static int seenCount = 0;
    uint64_t key = ((uint64_t)dstFmt << 32) ^ ((uint64_t)dw << 16) ^ (uint64_t)dh;
    BOOL isNew = YES;
    pthread_mutex_lock(&gFormatLogLock);
    for (int i = 0; i < seenCount; i++) { if (seen[i] == key) { isNew = NO; break; } }
    if (isNew && seenCount < 8) seen[seenCount++] = key; else isNew = NO;
    pthread_mutex_unlock(&gFormatLogLock);
    if (isNew) {
        SLog(@"camera output seen: source=%@ %zux%zu destination=%@ %zux%zu replaceable=%d",
             PixelFormatName(srcFmt), sw, sh, PixelFormatName(dstFmt), dw, dh, (int)usable);
    }
}

static BOOL Blit(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    OSType sourceFormat = CVPixelBufferGetPixelFormatType(src);
    OSType destinationFormat = CVPixelBufferGetPixelFormatType(dst);
    BOOL sourceFull = sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL sourcePlanar = sourceFull || sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    BOOL destinationFull = destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    BOOL destinationPlanar = destinationFull || destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    LogFormatOnce(sourceFormat, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src),
                  destinationFormat, CVPixelBufferGetWidth(dst), CVPixelBufferGetHeight(dst),
                  sourcePlanar && destinationPlanar);
    if (!sourcePlanar || !destinationPlanar) return NO;

    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    int rangeMode = sourceFull == destinationFull ? 0 : (sourceFull ? -1 : 1);
    int sourceWidth = (int)CVPixelBufferGetWidthOfPlane(src, 0);
    int sourceHeight = (int)CVPixelBufferGetHeightOfPlane(src, 0);
    int destinationWidth = (int)CVPixelBufferGetWidthOfPlane(dst, 0);
    int destinationHeight = (int)CVPixelBufferGetHeightOfPlane(dst, 0);
    // Aspect ratios differ -> crop the centre of the source (cover) instead of stretching.
    int cropX = 0, cropY = 0, cropW = sourceWidth, cropH = sourceHeight;
    AuxComputeCover(sourceWidth, sourceHeight, destinationWidth, destinationHeight,
                    &cropX, &cropY, &cropW, &cropH);
    BOOL copiedY = AuxCopyLuma((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(dst, 0), destinationWidth, destinationHeight,
                               (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, 0),
                               CVPixelBufferGetBytesPerRowOfPlane(src, 0),
                               cropX, cropY, cropW, cropH, rangeMode) != 0;
    BOOL copiedUV = AuxCopyChroma((uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 1),
                                  CVPixelBufferGetBytesPerRowOfPlane(dst, 1), destinationWidth, destinationHeight,
                                  (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(src, 1),
                                  CVPixelBufferGetBytesPerRowOfPlane(src, 1),
                                  cropX, cropY, cropW, cropH, rangeMode) != 0;
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

// ---------- hook ----------
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

// ---------- read the App's shared frames and replace the camera output ----------
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
                                SLog(@"shared frame received #%d %zux%zu", gDecoded, width, height);
                        }
                        if (pb) CVPixelBufferRelease(pb);
                        lastSequence = sequence;   // consumed: remember it
                    }
                    // CAS failed (other camera process is reading this slot): do NOT mark as seen, retry next loop
                } else {
                    lastSequence = sequence;
                }
            }
            if (lastFrameAt > 0 && MonotonicSeconds() - lastFrameAt > 1.5) {
                ClearLastFrame();
                lastFrameAt = 0;
                SLog(@"shared frame stalled, passing through the real camera");
            }
        }
        usleep(4 * 1000);
    }
    return NULL;
}

__attribute__((constructor)) static void AuxCamStreamInit(void) {
    SLog(@"shared-memory replacement plugin loaded (process %@)", [[NSProcessInfo processInfo] processName]);
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
    if (!c) { SLog(@"BWNodeOutput not found"); return; }
    SEL s = NSSelectorFromString(@"emitSampleBuffer:");
    Method m = class_getInstanceMethod(c, s);
    if (!m) { SLog(@"emitSampleBuffer: not found"); return; }
    gOrigEmit = method_getImplementation(m);
    method_setImplementation(m, (IMP)AuxEmitSampleBuffer);
    SLog(@"hooked BWNodeOutput");
}

