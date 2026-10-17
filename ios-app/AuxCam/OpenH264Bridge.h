#ifndef AUXCAM_OPENH264_BRIDGE_H
#define AUXCAM_OPENH264_BRIDGE_H
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

void *auxh264_create(void);
void auxh264_destroy(void *decoder);
int32_t auxh264_decode(void *decoder, const uint8_t *bytes, int32_t length,
                       CVPixelBufferRef _Nullable * _Nonnull outputBuffer);
#endif
