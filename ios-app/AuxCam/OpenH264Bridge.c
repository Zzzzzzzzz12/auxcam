// AuxCam 手机端 C 部分：OpenH264 软件解码 + 写共享内存（相机插件从共享内存读画面）。
#include "OpenH264Bridge.h"
#include "AuxCamSharedFrame.h"
#include "codec_api.h"
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// ───────────────────────── 软件解码 ─────────────────────────

typedef struct {
    ISVCDecoder *api;
    CVPixelBufferPoolRef pool;   // 输出画面的缓冲池（重复使用，不每帧申请 3MB 新内存）
    int poolW, poolH;
} AuxH264Decoder;

static void setNumber(CFMutableDictionaryRef dict, CFStringRef key, int32_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
    if (number) {
        CFDictionarySetValue(dict, key, number);
        CFRelease(number);
    }
}

// 注意：不带 IOSurface 属性。这台越狱机上带 IOSurface 属性创建缓冲会失败。
static CVPixelBufferRef makeOutputBuffer(AuxH264Decoder *d, int width, int height) {
    if (d->pool == NULL || d->poolW != width || d->poolH != height) {
        if (d->pool) { CVPixelBufferPoolRelease(d->pool); d->pool = NULL; }
        CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFMutableDictionaryRef poolAttrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (attrs && poolAttrs) {
            setNumber(attrs, kCVPixelBufferPixelFormatTypeKey, (int32_t)kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            setNumber(attrs, kCVPixelBufferWidthKey, width);
            setNumber(attrs, kCVPixelBufferHeightKey, height);
            setNumber(poolAttrs, kCVPixelBufferPoolMinimumBufferCountKey, 10);
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, attrs, &d->pool);
        }
        if (attrs) CFRelease(attrs);
        if (poolAttrs) CFRelease(poolAttrs);
        d->poolW = width;
        d->poolH = height;
    }
    CVPixelBufferRef buffer = NULL;
    if (d->pool && CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, d->pool, &buffer) == kCVReturnSuccess && buffer) {
        return buffer;
    }
    buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, (size_t)width, (size_t)height,
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, NULL, &buffer);
    return buffer;
}

void *auxh264_create(void) {
    AuxH264Decoder *d = (AuxH264Decoder *)calloc(1, sizeof(AuxH264Decoder));
    if (d == NULL) return NULL;
    if (WelsCreateDecoder(&d->api) != 0 || d->api == NULL) {
        free(d);
        return NULL;
    }
    // 单线程（0）：OpenH264 的多线程解码实测会把画面解错，哪怕关键帧也错。
    int32_t threads = 0;
    (*d->api)->SetOption(d->api, DECODER_OPTION_NUM_OF_THREADS, &threads);
    SDecodingParam param;
    memset(&param, 0, sizeof(param));
    param.uiTargetDqLayer = UCHAR_MAX;
    param.eEcActiveIdc = ERROR_CON_SLICE_COPY;   // 码流有小错时自动修补，不黑屏
    param.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
    if ((*d->api)->Initialize(d->api, &param) != 0) {
        WelsDestroyDecoder(d->api);
        free(d);
        return NULL;
    }
    return d;
}

void auxh264_destroy(void *opaque) {
    AuxH264Decoder *d = (AuxH264Decoder *)opaque;
    if (d == NULL) return;
    if (d->api) {
        (*d->api)->Uninitialize(d->api);
        WelsDestroyDecoder(d->api);
    }
    if (d->pool) CVPixelBufferPoolRelease(d->pool);
    free(d);
}

int32_t auxh264_decode(void *opaque, const uint8_t *bytes, int32_t length, int32_t lowDelay,
                       CVPixelBufferRef *outputBuffer) {
    if (outputBuffer) *outputBuffer = NULL;
    AuxH264Decoder *d = (AuxH264Decoder *)opaque;
    if (d == NULL || d->api == NULL || bytes == NULL || length <= 0 || outputBuffer == NULL) return -1;

    SBufferInfo info;
    unsigned char *planes[3] = { NULL, NULL, NULL };
    memset(&info, 0, sizeof(info));
    DECODING_STATE state = (*d->api)->DecodeFrameNoDelay(d->api, bytes, length, planes, &info);
    // 开了错误修补：就算报了小错，只要吐出了画面就照样用；既报错又没画面才算失败。
    if (state != dsErrorFree && info.iBufferStatus != 1) return -2;
    if (info.iBufferStatus != 1 && lowDelay) {
        // High / Main 档次的视频，OpenH264 会为"可能的重排序"把刚解好的画面扣住一帧（实测：每帧都晚一帧出，
        // 第一张关键帧要等第二帧来了才出）。没有 B 帧时根本不需要重排，用官方的 FlushFrame 立刻放出来。
        // FlushFrame 只在"流结束"标记打开时才放画面；下一次送数据时解码器会自己把这个标记清掉，不影响后续解码。
        int32_t eos = 1;
        (*d->api)->SetOption(d->api, DECODER_OPTION_END_OF_STREAM, &eos);
        memset(&info, 0, sizeof(info));
        planes[0] = planes[1] = planes[2] = NULL;
        (*d->api)->FlushFrame(d->api, planes, &info);
        eos = 0;
        (*d->api)->SetOption(d->api, DECODER_OPTION_END_OF_STREAM, &eos);
    }
    if (info.iBufferStatus != 1) return 0;

    const int width = info.UsrData.sSystemBuffer.iWidth;
    const int height = info.UsrData.sSystemBuffer.iHeight;
    const int yStride = info.UsrData.sSystemBuffer.iStride[0];
    const int uvStride = info.UsrData.sSystemBuffer.iStride[1];
    const uint8_t *ySrc = info.pDst[0], *uSrc = info.pDst[1], *vSrc = info.pDst[2];
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1) || width > 4096 || height > 4096 ||
        yStride < width || uvStride < width / 2 || !ySrc || !uSrc || !vSrc) return -3;

    CVPixelBufferRef buffer = makeOutputBuffer(d, width, height);
    if (buffer == NULL) return -4;
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(buffer);
        return -5;
    }
    uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const size_t yDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    const size_t uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    if (!yDst || !uvDst || yDstStride < (size_t)width || uvDstStride < (size_t)width) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        CVPixelBufferRelease(buffer);
        return -6;
    }
    for (int row = 0; row < height; row++) {
        memcpy(yDst + (size_t)row * yDstStride, ySrc + (size_t)row * (size_t)yStride, (size_t)width);
    }
    const int halfW = width / 2;
    for (int row = 0; row < height / 2; row++) {
        uint8_t *uv = uvDst + (size_t)row * uvDstStride;
        const uint8_t *u = uSrc + (size_t)row * (size_t)uvStride;
        const uint8_t *v = vSrc + (size_t)row * (size_t)uvStride;
        for (int col = 0; col < halfW; col++) {
            uv[2 * col] = u[col];
            uv[2 * col + 1] = v[col];
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    *outputBuffer = buffer;
    return 1;
}

// ───────────────────────── 共享内存（给相机插件） ─────────────────────────
// 格式见 AuxCamSharedFrame.h，必须和插件 tweak-stream 保持一致。

#ifndef AUX_SHARED_FRAME_PATH
#define AUX_SHARED_FRAME_PATH "/var/mobile/Media/DCIM/.frame.ring"   // 电脑上测试时可以换路径
#endif
static const char *kSharedFramePath = AUX_SHARED_FRAME_PATH;
static pthread_mutex_t gPublishMutex = PTHREAD_MUTEX_INITIALIZER;
static void *gMap = MAP_FAILED;

static int32_t ensureSharedMap(void) {
    if (gMap != MAP_FAILED) return 0;
    const size_t bytes = sizeof(AuxSharedFrameHeader) +
        (size_t)AUX_SHARED_FRAME_SLOT_COUNT * AUX_SHARED_FRAME_SLOT_CAPACITY;
    int fd = open(kSharedFramePath, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return -10;
    (void)fchmod(fd, 0666);
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < bytes) {
        if (ftruncate(fd, (off_t)bytes) != 0) { close(fd); return -11; }
    }
    void *map = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);   // 映射建好后文件句柄可以关掉，映射依然有效
    if (map == MAP_FAILED) return -12;
    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)map;
    if (__atomic_load_n(&header->magic, __ATOMIC_ACQUIRE) != AUX_SHARED_FRAME_MAGIC ||
        header->version != AUX_SHARED_FRAME_VERSION) {
        memset(header, 0, sizeof(*header));
        header->version = AUX_SHARED_FRAME_VERSION;
        __atomic_store_n(&header->magic, AUX_SHARED_FRAME_MAGIC, __ATOMIC_RELEASE);
    }
    gMap = map;
    return 0;
}

// 镜像 / 旋转
static volatile int gMirror = 0;
static volatile int gRotate = 0;

void auxcam_set_transform(int32_t mirror, int32_t rotate) {
    int r = ((rotate % 360) + 360) % 360;
    gRotate = (r == 90 || r == 180 || r == 270) ? r : 0;
    gMirror = mirror ? 1 : 0;
}

// 旋转 / 镜像一个平面。bpp = 每个点几个字节：Y 平面 1 个，UV 平面 2 个（U、V 成对搬，不会拆开）。
// 按字节搬，不做 2 字节强制转换，不依赖内存对齐。
static void xformPlane(const uint8_t *src, size_t sStride, int sw, int sh, uint8_t *dst, size_t dStride,
                       int rot, int mirror, int bpp) {
    int W = (rot == 90 || rot == 270) ? sh : sw;
    int H = (rot == 90 || rot == 270) ? sw : sh;
    for (int dy = 0; dy < H; dy++) {
        uint8_t *drow = dst + (size_t)dy * dStride;
        for (int dx = 0; dx < W; dx++) {
            int mx = mirror ? (W - 1 - dx) : dx;
            int sx, sy;
            switch (rot) {
                case 90:  sx = dy;          sy = sh - 1 - mx; break;
                case 180: sx = sw - 1 - mx; sy = sh - 1 - dy; break;
                case 270: sx = sw - 1 - dy; sy = mx;          break;
                default:  sx = mx;          sy = dy;          break;
            }
            const uint8_t *s = src + (size_t)sy * sStride + (size_t)sx * (size_t)bpp;
            uint8_t *d = drow + (size_t)dx * (size_t)bpp;
            d[0] = s[0];
            if (bpp == 2) d[1] = s[1];
        }
    }
}

// 窄范围 → 全范围的查表（Y: 16~235 → 0~255；UV: 16~240 → 0~255，以 128 为中心）
static uint8_t gLumaLUT[256], gChromaLUT[256];
static pthread_once_t gLUTOnce = PTHREAD_ONCE_INIT;
static void buildLUT(void) {
    for (int i = 0; i < 256; i++) {
        int y = ((i - 16) * 255 + 109) / 219;
        int c = ((i - 128) * 255) / 224 + 128;
        gLumaLUT[i] = (uint8_t)(y < 0 ? 0 : (y > 255 ? 255 : y));
        gChromaLUT[i] = (uint8_t)(c < 0 ? 0 : (c > 255 ? 255 : c));
    }
}
static void applyLUT(uint8_t *p, size_t n, const uint8_t *lut) {
    for (size_t i = 0; i < n; i++) p[i] = lut[p[i]];
}

int32_t auxcam_publish_frame(CVPixelBufferRef frame, int32_t limitedRange) {
    if (frame == NULL || !CVPixelBufferIsPlanar(frame) || CVPixelBufferGetPlaneCount(frame) < 2) return -1;
    const size_t width = CVPixelBufferGetWidth(frame);
    const size_t height = CVPixelBufferGetHeight(frame);
    if (width == 0 || height == 0 || (width & 1) || (height & 1) ||
        width > 4096 || height > 4096 || width * height * 3 / 2 > AUX_SHARED_FRAME_SLOT_CAPACITY) return -2;
    if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return -3;
    const uint8_t *srcY = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 0);
    const uint8_t *srcUV = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 1);
    const size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
    const size_t srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
    if (!srcY || !srcUV || srcYStride < width || srcUVStride < width) {
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        return -4;
    }
    if (limitedRange) pthread_once(&gLUTOnce, buildLUT);

    pthread_mutex_lock(&gPublishMutex);
    int32_t mapResult = ensureSharedMap();
    if (mapResult != 0) {
        pthread_mutex_unlock(&gPublishMutex);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        return mapResult;
    }
    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)gMap;
    // 选一个不是"当前画面"的槽来写（插件可能正在读当前那张）
    uint32_t active = __atomic_load_n(&header->activeSlot, __ATOMIC_ACQUIRE);
    if (active >= AUX_SHARED_FRAME_SLOT_COUNT) active = 0;
    uint32_t target = AUX_SHARED_FRAME_SLOT_COUNT;
    for (uint32_t i = 0; i < AUX_SHARED_FRAME_SLOT_COUNT; i++) {
        if (i == active) continue;
        uint32_t state = __atomic_load_n(&header->slots[i].state, __ATOMIC_ACQUIRE);
        if (state != AUX_SHARED_SLOT_FREE && state != AUX_SHARED_SLOT_READY) continue;
        if (__atomic_compare_exchange_n(&header->slots[i].state, &state, AUX_SHARED_SLOT_WRITING,
                                        false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            target = i;
            break;
        }
    }
    if (target >= AUX_SHARED_FRAME_SLOT_COUNT) {
        pthread_mutex_unlock(&gPublishMutex);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        return -5;
    }

    AuxSharedFrameSlot *slot = &header->slots[target];
    uint8_t *dst = (uint8_t *)gMap + sizeof(*header) + (size_t)target * AUX_SHARED_FRAME_SLOT_CAPACITY;
    const int rot = gRotate, mirror = gMirror;
    const size_t outW = (rot == 90 || rot == 270) ? height : width;
    const size_t outH = (rot == 90 || rot == 270) ? width : height;
    uint8_t *dstUV = dst + outW * outH;
    if (rot != 0 || mirror) {
        xformPlane(srcY, srcYStride, (int)width, (int)height, dst, outW, rot, mirror, 1);
        xformPlane(srcUV, srcUVStride, (int)(width / 2), (int)(height / 2), dstUV, outW, rot, mirror, 2);
    } else {
        for (size_t row = 0; row < height; row++) memcpy(dst + row * width, srcY + row * srcYStride, width);
        for (size_t row = 0; row < height / 2; row++) memcpy(dstUV + row * width, srcUV + row * srcUVStride, width);
    }
    if (limitedRange) {
        applyLUT(dst, outW * outH, gLumaLUT);
        applyLUT(dstUV, outW * outH / 2, gChromaLUT);
    }
    slot->width = (uint32_t)outW;
    slot->height = (uint32_t)outH;
    slot->yStride = (uint32_t)outW;
    slot->uvStride = (uint32_t)outW;
    slot->frameBytes = (uint32_t)(outW * outH * 3 / 2);
    __atomic_store_n(&slot->state, AUX_SHARED_SLOT_READY, __ATOMIC_RELEASE);
    __atomic_store_n(&header->activeSlot, target, __ATOMIC_RELEASE);
    __atomic_add_fetch(&header->sequence, 1, __ATOMIC_ACQ_REL);
    pthread_mutex_unlock(&gPublishMutex);
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    return 1;
}
