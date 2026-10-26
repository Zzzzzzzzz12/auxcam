#ifndef AUXCAMD_VCU1_H
#define AUXCAMD_VCU1_H
#include <stddef.h>
#include <stdint.h>

// VCU1 协议：24 字节头（全部大端）+ payload。和 App 旧版 VCU1Receiver 的解析保持一致。
#define VCU1_HEADER_BYTES 24
#define VCU1_MAX_PAYLOAD (4u * 1024u * 1024u)
#define VCU1_TYPE_CONFIG 1
#define VCU1_TYPE_VIDEO 2
#define VCU1_TYPE_HEARTBEAT 5
#define VCU1_FLAG_KEYFRAME 1
#define VCU1_PARAM_SET_CAPACITY 1024
#define VCU1_RING_MAX_BYTES (8 * 1024 * 1024)

typedef struct {
    uint8_t version;
    uint8_t type;
    uint16_t flags;
    uint32_t length;
    uint32_t seq;
    uint64_t timestamp_us;
} VCU1Header;

typedef struct {
    uint8_t bytes[VCU1_PARAM_SET_CAPACITY];
    size_t length;
} VCU1ParamSet;

// 返回 0 合法；-1 magic 不对；-2 版本或长度不合法。
int vcu1_parse_header(const uint8_t *raw, VCU1Header *out);

// 从 AVCDecoderConfigurationRecord 取出 SPS/PPS（取最后一组）。两者都有才返回 0。
int vcu1_parse_avcc(const uint8_t *data, size_t length, VCU1ParamSet *sps, VCU1ParamSet *pps);

// stream.h264 环形缓存：超过 8MB 从头覆盖，并等下一个关键帧再继续写。
typedef struct {
    int fd;
    int64_t size;
    int needs_keyframe;
    char path[1024];
} VCU1Ring;

void vcu1_ring_init(VCU1Ring *ring, const char *path);
void vcu1_ring_close(VCU1Ring *ring);
// nalu 可带也可不带起始码；关键帧时前面补上 SPS/PPS。
void vcu1_ring_append(VCU1Ring *ring, const uint8_t *nalu, size_t length, int keyframe,
                      const VCU1ParamSet *sps, const VCU1ParamSet *pps);

// 诊断日志：追加一行到 path，超过 1MB 就截断重写。
void vcu1_log(const char *path, const char *fmt, ...);
#endif
