#include "OpenH264Bridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include "codec_api.h"
#include <fcntl.h>
#include <IOSurface/IOSurfaceRef.h>
#include <stdio.h>
#include <sys/stat.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    ISVCDecoder *api;
} AuxH264Decoder;

static const char *kSurfacePath = "/var/mobile/Media/DCIM/.frame.surface";
static pthread_mutex_t gPublishMutex = PTHREAD_MUTEX_INITIALIZER;
static int gSurfaceFD = -1;

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

    CFMutableDictionaryRef attributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef surfaceAttributes = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL || surfaceAttributes == NULL) {
        if (attributes != NULL) CFRelease(attributes);
        if (surfaceAttributes != NULL) CFRelease(surfaceAttributes);
        return -8;
    }
    CFDictionarySetValue(attributes, kCVPixelBufferIOSurfacePropertiesKey, surfaceAttributes);
    CFRelease(surfaceAttributes);
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, (size_t)width, (size_t)height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer);
    CFRelease(attributes);
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

int32_t auxcam_publish_shared_frame(CVPixelBufferRef frame) {
    if (frame == NULL) return -1;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(frame);
    if (surface == NULL) return -2;
    IOSurfaceID surfaceID = IOSurfaceGetID(surface);
    if (surfaceID == 0) return -3;

    char contents[16];
    int length = snprintf(contents, sizeof(contents), "id=%010u\n", surfaceID);
    if (length != 14) return -4;

    pthread_mutex_lock(&gPublishMutex);
    if (gSurfaceFD < 0) {
        gSurfaceFD = open(kSurfacePath, O_CREAT | O_WRONLY, 0666);
        if (gSurfaceFD >= 0) (void)fchmod(gSurfaceFD, 0666);
    }
    ssize_t written = gSurfaceFD >= 0 ? pwrite(gSurfaceFD, contents, (size_t)length, 0) : -1;
    int result = written == length ? 1 : -5;
    pthread_mutex_unlock(&gPublishMutex);
    return result;
}
