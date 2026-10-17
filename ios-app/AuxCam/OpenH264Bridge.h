#ifndef AUXCAM_OPENH264_BRIDGE_H
#define AUXCAM_OPENH264_BRIDGE_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

void * _Nullable auxh264_create(void);
void auxh264_destroy(void * _Nullable decoder);
int32_t auxh264_decode(void * _Nullable decoder, const uint8_t * _Nullable bytes, int32_t length,
                       CVPixelBufferRef _Nullable * _Nonnull outputBuffer);
#endif