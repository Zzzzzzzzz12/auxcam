#include "OpenH264Bridge.h"
#include "codec_api.h"
#include <IOSurface/IOSurfaceRef.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    ISVCDecoder *api;
} AuxH264Decoder;

static bool setSurfaceNumber(CFMutableDictionaryRef dictionary, CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    if (number == NULL) return false;
    CFDictionarySetValue(dictionary, key, number);
    CFRelease(number);
    return true;
}

static IOSurfaceRef createNV12Surface(int width, int height) {
    size_t yStride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width);
    size_t ySize = IOSurfaceAlignProperty(kIOSurfaceAllocSize, yStride * (size_t)height);
    size_t uvStride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width);
    size_t uvSize = IOSurfaceAlignProperty(kIOSurfaceAllocSize, uvStride * (size_t)(height / 2));
    if (yStride == 0 || ySize == 0 || uvStride == 0 || uvSize == 0) return NULL;

    CFMutableDictionaryRef yPlane = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef uvPlane = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (yPlane == NULL || uvPlane == NULL || properties == NULL) {
        if (yPlane != NULL) CFRelease(yPlane);
        if (uvPlane != NULL) CFRelease(uvPlane);
        if (properties != NULL) CFRelease(properties);
        return NULL;
    }

    bool ok = setSurfaceNumber(yPlane, kIOSurfacePlaneWidth, width) &&
        setSurfaceNumber(yPlane, kIOSurfacePlaneHeight, height) &&
        setSurfaceNumber(yPlane, kIOSurfacePlaneBytesPerRow, (int64_t)yStride) &&
        setSurfaceNumber(yPlane, kIOSurfacePlaneOffset, 0) &&
        setSurfaceNumber(yPlane, kIOSurfacePlaneSize, (int64_t)ySize) &&
        setSurfaceNumber(uvPlane, kIOSurfacePlaneWidth, width / 2) &&
        setSurfaceNumber(uvPlane, kIOSurfacePlaneHeight, height / 2) &&
        setSurfaceNumber(uvPlane, kIOSurfacePlaneBytesPerRow, (int64_t)uvStride) &&
        setSurfaceNumber(uvPlane, kIOSurfacePlaneOffset, (int64_t)ySize) &&
        setSurfaceNumber(uvPlane, kIOSurfacePlaneSize, (int64_t)uvSize) &&
        setSurfaceNumber(properties, kIOSurfaceWidth, width) &&
        setSurfaceNumber(properties, kIOSurfaceHeight, height) &&
        setSurfaceNumber(properties, kIOSurfacePixelFormat,
                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) &&
        setSurfaceNumber(properties, kIOSurfaceAllocSize, (int64_t)(ySize + uvSize));

    CFMutableArrayRef planes = CFArrayCreateMutable(
        kCFAllocatorDefault, 2, &kCFTypeArrayCallBacks);
    if (planes == NULL) ok = false;
    if (ok) {
        CFArrayAppendValue(planes, yPlane);
        CFArrayAppendValue(planes, uvPlane);
        CFDictionarySetValue(properties, kIOSurfacePlaneInfo, planes);
    }

    IOSurfaceRef surface = ok ? IOSurfaceCreate(properties) : NULL;
    if (planes != NULL) CFRelease(planes);
    CFRelease(properties);
    CFRelease(uvPlane);
    CFRelease(yPlane);
    return surface;
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

    IOSurfaceRef surface = createNV12Surface(width, height);
    if (surface == NULL) return -4001;
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn createStatus = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    IOSurfaceRelease(surface);
    if (createStatus != kCVReturnSuccess) {
        if (pixelBuffer != NULL) CVPixelBufferRelease(pixelBuffer);
        return -5000 - (int32_t)createStatus;
    }
    if (pixelBuffer == NULL) return -2000;

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
