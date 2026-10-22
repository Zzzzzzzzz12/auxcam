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

typedef struct {
    ISVCDecoder *api;
} AuxH264Decoder;

static const char *kSharedFramePath = "/var/mobile/Media/DCIM/.frame.ring";
static pthread_mutex_t gPublishMutex = PTHREAD_MUTEX_INITIALIZER;
static int gSharedFrameFD = -1;
static void *gSharedFrameMap = MAP_FAILED;
static size_t gSharedFrameMapBytes = 0;

static size_t sharedFrameFileBytes(void) {
    return sizeof(AuxSharedFrameHeader) +
        (size_t)AUX_SHARED_FRAME_SLOT_COUNT * AUX_SHARED_FRAME_SLOT_CAPACITY;
}

static int32_t ensureSharedFrameMap(void) {
    if (gSharedFrameMap != MAP_FAILED) return 0;
    const size_t bytes = sharedFrameFileBytes();
    int fd = open(kSharedFramePath, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return -10;
    (void)fchmod(fd, 0666);
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < bytes) {
        if (ftruncate(fd, (off_t)bytes) != 0) {
            close(fd);
            return -11;
        }
    }
    void *map = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return -12;
    }
    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)map;
    if (__atomic_load_n(&header->magic, __ATOMIC_ACQUIRE) != AUX_SHARED_FRAME_MAGIC ||
        header->version != AUX_SHARED_FRAME_VERSION) {
        memset(header, 0, sizeof(*header));
        header->version = AUX_SHARED_FRAME_VERSION;
        __atomic_store_n(&header->magic, AUX_SHARED_FRAME_MAGIC, __ATOMIC_RELEASE);
    }
    gSharedFrameFD = fd;
    gSharedFrameMap = map;
    gSharedFrameMapBytes = bytes;
    return 0;
}

static int32_t makeDecoder(AuxH264Decoder *decoder) {
    if (WelsCreateDecoder(&decoder->api) != 0 || decoder->api == NULL) return -1;
    SDecodingParam parameters;
    memset(&parameters, 0, sizeof(parameters));
    parameters.uiTargetDqLayer = UCHAR_MAX;
    parameters.eEcActiveIdc = ERROR_CON_SLICE_COPY;
    parameters.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
    if ((*decoder->api)->Initialize(decoder->api, &parameters) != 0) {
        WelsDestroyDecoder(decoder->api);
        decoder->api = NULL;
        return -2;
    }
    return 0;
}

void *auxh264_create(void) {
    AuxH264Decoder *decoder = (AuxH264Decoder *)calloc(1, sizeof(AuxH264Decoder));
    if (decoder == NULL) return NULL;
    if (makeDecoder(decoder) != 0) {
        free(decoder);
        return NULL;
    }
    return decoder;
}

void auxh264_destroy(void *opaque) {
    AuxH264Decoder *decoder = (AuxH264Decoder *)opaque;
    if (decoder == NULL) return;
    if (decoder->api != NULL) {
        (*decoder->api)->Uninitialize(decoder->api);
        WelsDestroyDecoder(decoder->api);
    }
    free(decoder);
}

int32_t auxh264_decode(void *opaque, const uint8_t *bytes, int32_t length,
                       CVPixelBufferRef _Nullable * _Nonnull outputBuffer) {
    if (outputBuffer != NULL) *outputBuffer = NULL;
    AuxH264Decoder *decoder = (AuxH264Decoder *)opaque;
    if (decoder == NULL || decoder->api == NULL || bytes == NULL || length <= 0 || outputBuffer == NULL) return -1;

    SBufferInfo info;
    unsigned char *planes[3] = { NULL, NULL, NULL };
    memset(&info, 0, sizeof(info));
    DECODING_STATE state = (*decoder->api)->DecodeFrameNoDelay(
        decoder->api, bytes, length, planes, &info);
    if (state != dsErrorFree) return -2;
    if (info.iBufferStatus != 1) return 0;

    const int width = info.UsrData.sSystemBuffer.iWidth;
    const int height = info.UsrData.sSystemBuffer.iHeight;
    const int yStride = info.UsrData.sSystemBuffer.iStride[0];
    const int uvStride = info.UsrData.sSystemBuffer.iStride[1];
    const uint8_t *ySrc = info.pDst[0];
    const uint8_t *uSrc = info.pDst[1];
    const uint8_t *vSrc = info.pDst[2];
    if (width <= 0 || height <= 0 || (width & 1) || (height & 1) ||
        yStride < width || uvStride < width / 2 || ySrc == NULL || uSrc == NULL || vSrc == NULL) return -3;

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, (size_t)width, (size_t)height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pixelBuffer);
    if (createStatus != kCVReturnSuccess || pixelBuffer == NULL) {
        if (pixelBuffer != NULL) CVPixelBufferRelease(pixelBuffer);
        return -2000 - (int32_t)createStatus;
    }
    CVReturn lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockStatus != kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        return -6;
    }
    uint8_t *yDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
    uint8_t *uvDst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
    size_t yDstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t uvDstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    if (yDst == NULL || uvDst == NULL || yDstStride < (size_t)width || uvDstStride < (size_t)width) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return -7;
    }
    for (int row = 0; row < height; row++) {
        memcpy(yDst + (size_t)row * yDstStride, ySrc + (size_t)row * (size_t)yStride, (size_t)width);
    }
    for (int row = 0; row < height / 2; row++) {
        uint8_t *uv = uvDst + (size_t)row * uvDstStride;
        const uint8_t *u = uSrc + (size_t)row * (size_t)uvStride;
        const uint8_t *v = vSrc + (size_t)row * (size_t)uvStride;
        for (int col = 0; col < width / 2; col++) {
            uv[col * 2] = u[col];
            uv[col * 2 + 1] = v[col];
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    *outputBuffer = pixelBuffer;
    return 1;
}

// AUXXFORM：镜像 / 旋转（发布到共享内存前对画面做变换）
static volatile int gMirror = 0;
static volatile int gRotate = 0;   // 0 / 90 / 180 / 270（顺时针）

void auxcam_set_transform(int32_t mirror, int32_t rotate) {
    int r = ((rotate % 360) + 360) % 360;
    gRotate = (r == 90 || r == 180 || r == 270) ? r : 0;
    gMirror = mirror ? 1 : 0;
}

#define AUX_XFORM_PLANE(NAME, T) \
static void NAME(const uint8_t *src, size_t sStride, int sw, int sh, uint8_t *dst, size_t dStride, int rot, int mirror) { \
    int W = (rot == 90 || rot == 270) ? sh : sw; \
    int H = (rot == 90 || rot == 270) ? sw : sh; \
    for (int dy = 0; dy < H; dy++) { \
        T *drow = (T *)(dst + (size_t)dy * dStride); \
        for (int dx = 0; dx < W; dx++) { \
            int mx = mirror ? (W - 1 - dx) : dx; \
            int sx, sy; \
            switch (rot) { \
                case 90:  sx = dy;          sy = sh - 1 - mx; break; \
                case 180: sx = sw - 1 - mx; sy = sh - 1 - dy; break; \
                case 270: sx = sw - 1 - dy; sy = mx;          break; \
                default:  sx = mx;          sy = dy;          break; \
            } \
            drow[dx] = ((const T *)(src + (size_t)sy * sStride))[sx]; \
        } \
    } \
}
AUX_XFORM_PLANE(auxXformPlane8, uint8_t)
AUX_XFORM_PLANE(auxXformPlane16, uint16_t)

int32_t auxcam_publish_shared_frame(CVPixelBufferRef frame) {
    if (frame == NULL || !CVPixelBufferIsPlanar(frame) || CVPixelBufferGetPlaneCount(frame) < 2) return -1;
    const size_t width = CVPixelBufferGetWidth(frame);
    const size_t height = CVPixelBufferGetHeight(frame);
    if (width == 0 || height == 0 || (width & 1) || (height & 1) ||
        width > 4096 || height > 2160 || width * height * 3 / 2 > AUX_SHARED_FRAME_SLOT_CAPACITY) return -2;
    if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return -3;
    const uint8_t *srcY = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 0);
    const uint8_t *srcUV = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(frame, 1);
    const size_t srcYStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 0);
    const size_t srcUVStride = CVPixelBufferGetBytesPerRowOfPlane(frame, 1);
    if (srcY == NULL || srcUV == NULL || srcYStride < width || srcUVStride < width) {
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        return -4;
    }

    pthread_mutex_lock(&gPublishMutex);
    int32_t mapResult = ensureSharedFrameMap();
    if (mapResult != 0) {
        pthread_mutex_unlock(&gPublishMutex);
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        return mapResult;
    }
    AuxSharedFrameHeader *header = (AuxSharedFrameHeader *)gSharedFrameMap;
    uint32_t active = __atomic_load_n(&header->activeSlot, __ATOMIC_ACQUIRE);
    if (active >= AUX_SHARED_FRAME_SLOT_COUNT) active = 0;
    uint32_t target = AUX_SHARED_FRAME_SLOT_COUNT;
    for (uint32_t i = 0; i < AUX_SHARED_FRAME_SLOT_COUNT; i++) {
        if (i == active) continue;
        AuxSharedFrameSlot *slot = &header->slots[i];
        uint32_t stateValue = __atomic_load_n(&slot->state, __ATOMIC_ACQUIRE);
        if (stateValue != AUX_SHARED_SLOT_FREE && stateValue != AUX_SHARED_SLOT_READY) continue;
        if (__atomic_compare_exchange_n(&slot->state, &stateValue, AUX_SHARED_SLOT_WRITING,
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
    uint8_t *dst = (uint8_t *)gSharedFrameMap + sizeof(*header) +
        (size_t)target * AUX_SHARED_FRAME_SLOT_CAPACITY;
    const int xRot = gRotate;
    const int xMirror = gMirror;
    if (xRot != 0 || xMirror) {
        const size_t outW = (xRot == 90 || xRot == 270) ? height : width;
        const size_t outH = (xRot == 90 || xRot == 270) ? width : height;
        auxXformPlane8(srcY, srcYStride, (int)width, (int)height, dst, outW, xRot, xMirror);
        auxXformPlane16(srcUV, srcUVStride, (int)(width / 2), (int)(height / 2),
                        dst + outW * outH, outW, xRot, xMirror);
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
    for (size_t row = 0; row < height; row++) {
        memcpy(dst + row * width, srcY + row * srcYStride, width);
    }
    uint8_t *dstUV = dst + width * height;
    for (size_t row = 0; row < height / 2; row++) {
        memcpy(dstUV + row * width, srcUV + row * srcUVStride, width);
    }
    slot->width = (uint32_t)width;
    slot->height = (uint32_t)height;
    slot->yStride = (uint32_t)width;
    slot->uvStride = (uint32_t)width;
    slot->frameBytes = (uint32_t)(width * height * 3 / 2);
    __atomic_store_n(&slot->state, AUX_SHARED_SLOT_READY, __ATOMIC_RELEASE);
    __atomic_store_n(&header->activeSlot, target, __ATOMIC_RELEASE);
    __atomic_add_fetch(&header->sequence, 1, __ATOMIC_ACQ_REL);
    pthread_mutex_unlock(&gPublishMutex);
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    return 1;
}
