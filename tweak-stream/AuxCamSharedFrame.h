#ifndef AUXCAM_SHARED_FRAME_H
#define AUXCAM_SHARED_FRAME_H
#include <stdint.h>

#define AUX_SHARED_FRAME_MAGIC 0x41554632u
#define AUX_SHARED_FRAME_VERSION 2u
#define AUX_SHARED_FRAME_SLOT_COUNT 3u
#define AUX_SHARED_FRAME_SLOT_CAPACITY (16u * 1024u * 1024u)
#define AUX_SHARED_SLOT_FREE 0u
#define AUX_SHARED_SLOT_WRITING 1u
#define AUX_SHARED_SLOT_READY 2u
#define AUX_SHARED_SLOT_READING 3u

typedef struct {
    uint32_t state;
    uint32_t width;
    uint32_t height;
    uint32_t yStride;
    uint32_t uvStride;
    uint32_t frameBytes;
} AuxSharedFrameSlot;

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t activeSlot;
    uint32_t reserved;
    uint64_t sequence;
    AuxSharedFrameSlot slots[AUX_SHARED_FRAME_SLOT_COUNT];
    uint8_t padding[32];
} AuxSharedFrameHeader;
#endif
