#include "vcu1.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define VCU1_LOG_MAX_BYTES (1024 * 1024)

static const uint8_t kStartCode[4] = {0, 0, 0, 1};

int vcu1_parse_header(const uint8_t *raw, VCU1Header *out) {
    if (memcmp(raw, "VCU1", 4) != 0) return -1;
    out->version = raw[4];
    out->type = raw[5];
    out->flags = (uint16_t)((raw[6] << 8) | raw[7]);
    out->length = ((uint32_t)raw[8] << 24) | ((uint32_t)raw[9] << 16) | ((uint32_t)raw[10] << 8) | raw[11];
    out->seq = ((uint32_t)raw[12] << 24) | ((uint32_t)raw[13] << 16) | ((uint32_t)raw[14] << 8) | raw[15];
    uint64_t ts = 0;
    for (int i = 16; i < 24; i++) ts = (ts << 8) | raw[i];
    out->timestamp_us = ts;
    if (out->version != 1 || out->length > VCU1_MAX_PAYLOAD) return -2;
    return 0;
}

static int copy_param_set(const uint8_t *d, size_t n, size_t *i, VCU1ParamSet *out) {
    if (*i + 2 > n) return -1;
    size_t l = ((size_t)d[*i] << 8) | d[*i + 1];
    *i += 2;
    if (l > VCU1_PARAM_SET_CAPACITY || *i + l > n) return -1;
    memcpy(out->bytes, d + *i, l);
    out->length = l;
    *i += l;
    return 0;
}

int vcu1_parse_avcc(const uint8_t *d, size_t n, VCU1ParamSet *sps, VCU1ParamSet *pps) {
    if (n <= 7 || d[0] != 1) return -1;
    VCU1ParamSet s = {{0}, 0};
    VCU1ParamSet p = {{0}, 0};
    size_t i = 5;
    size_t numSPS = d[i] & 0x1F;
    i += 1;
    for (size_t k = 0; k < numSPS; k++) {
        if (copy_param_set(d, n, &i, &s) != 0) return -1;
    }
    if (i >= n) return -1;
    size_t numPPS = d[i] & 0x1F;
    i += 1;
    for (size_t k = 0; k < numPPS; k++) {
        if (copy_param_set(d, n, &i, &p) != 0) return -1;
    }
    if (s.length == 0 || p.length == 0) return -1;
    *sps = s;
    *pps = p;
    return 0;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t k = write(fd, p, n);
        if (k < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "write failed errno=%d\n", errno);
            return -1;
        }
        p += k;
        n -= (size_t)k;
    }
    return 0;
}

void vcu1_ring_init(VCU1Ring *ring, const char *path) {
    memset(ring, 0, sizeof(*ring));
    ring->fd = -1;
    snprintf(ring->path, sizeof(ring->path), "%s", path);
}

void vcu1_ring_close(VCU1Ring *ring) {
    if (ring->fd >= 0) close(ring->fd);
    ring->fd = -1;
}

static int ring_open(VCU1Ring *ring) {
    if (ring->fd >= 0) return 0;
    int fd = open(ring->path, O_WRONLY | O_CREAT, 0644);
    if (fd < 0) {
        fprintf(stderr, "ring open failed path=%s errno=%d\n", ring->path, errno);
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        close(fd);
        return -1;
    }
    ring->size = (int64_t)st.st_size;
    lseek(fd, 0, SEEK_END);
    ring->fd = fd;
    return 0;
}

void vcu1_ring_append(VCU1Ring *ring, const uint8_t *nalu, size_t length, int keyframe,
                      const VCU1ParamSet *sps, const VCU1ParamSet *pps) {
    if (length >= 4 && memcmp(nalu, kStartCode, 4) == 0) {
        nalu += 4;
        length -= 4;
    } else if (length >= 3 && nalu[0] == 0 && nalu[1] == 0 && nalu[2] == 1) {
        nalu += 3;
        length -= 3;
    }
    if (length == 0) return;
    if (ring_open(ring) != 0) return;
    if (ring->needs_keyframe && !keyframe) return;

    int withParams = keyframe && sps->length > 0 && pps->length > 0;
    size_t total = 4 + length;
    if (withParams) total += 8 + sps->length + pps->length;

    if (ring->size + (int64_t)total > VCU1_RING_MAX_BYTES) {
        ftruncate(ring->fd, 0);
        lseek(ring->fd, 0, SEEK_SET);
        ring->size = 0;
        ring->needs_keyframe = 1;
        // 环形缓存从完整 GOP 起步，避免绕回后以 P 帧开头。
        if (!keyframe) return;
    }

    uint8_t *buf = malloc(total);
    if (buf == NULL) return;
    size_t o = 0;
    if (withParams) {
        memcpy(buf + o, kStartCode, 4); o += 4;
        memcpy(buf + o, sps->bytes, sps->length); o += sps->length;
        memcpy(buf + o, kStartCode, 4); o += 4;
        memcpy(buf + o, pps->bytes, pps->length); o += pps->length;
    }
    memcpy(buf + o, kStartCode, 4); o += 4;
    memcpy(buf + o, nalu, length); o += length;

    if (write_all(ring->fd, buf, total) == 0) {
        ring->size += (int64_t)total;
        if (keyframe) ring->needs_keyframe = 0;
    }
    free(buf);
}

void vcu1_log(const char *path, const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        // 调试：写日志失败时把路径和错误码打到标准错误
        fprintf(stderr, "vcu1_log open failed path=%s errno=%d\n", path, errno);
        return;
    }
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > VCU1_LOG_MAX_BYTES) {
        close(fd);
        fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
        if (fd < 0) return;
    }
    char line[640];
    int n = snprintf(line, sizeof(line), "%ld %s\n", (long)time(NULL), msg);
    if (n > 0) {
        int w = write_all(fd, (const uint8_t *)line, (size_t)n);
        fprintf(stderr, "log write rc=%d n=%d fd=%d\n", w, n, fd);
    }
    close(fd);
}
