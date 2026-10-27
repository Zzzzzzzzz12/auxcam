// auxcamd：推流接收守护进程（launchd 常驻，开机自启，不随 App 被杀）。
// 绑 127.0.0.1:28765 接万相电脑端的 VCU1 推流。收包线程只负责收和落盘；
// 解码和发布共享帧在单独的解码线程里做，中间是一个有上限的队列，解码跟不上就丢帧等关键帧，
// 这样不会因为解码慢而卡住 TCP 读取（那是画面卡顿的原因）。
// 同时写 stream.h264、.vcu1.log（每 5 秒一行心跳），并写状态文件 .auxcamd.status 给 App 只读。
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include "OpenH264Bridge.h"
#include "vcu1.h"

#define AUXCAMD_PORT 28765
#define AUXCAMD_DEFAULT_DIR "/var/mobile/Media/DCIM"
#define AUXCAMD_IDLE_SECONDS 5.0
#define AUXCAMD_HEARTBEAT_TIMEOUT 8.0
#define AUXCAMD_HEARTBEAT_LOG_SECONDS 5.0
#define AUXCAMD_GAP_WINDOW 90
#define AUXCAMD_DECODE_QUEUE_DEPTH 8
#define AUXCAMD_PACE_PRIME 2          // 攒够 2 帧再开始按节奏发布
#define AUXCAMD_PACE_MAX 8            // 发布队列最多 4 帧，超过就丢最旧的，延迟不会越攒越大
#define AUXCAMD_FRAME_INTERVAL_NS 33333333L

typedef struct {
    uint8_t *data;
    size_t length;
    int keyframe;
} DecodeItem;

typedef struct {
    char logPath[PATH_MAX];
    char statusPath[PATH_MAX];
    VCU1Ring ring;

    // 收包线程专用
    VCU1ParamSet sps;
    VCU1ParamSet pps;
    int haveConfig;
    int listening;
    int connected;
    int dropConnection;
    int seenType[256];
    uint8_t *payload;
    size_t payloadCap;
    double lastHeartbeatAt;
    double lastStatusAt;
    double lastLogAt;
    double fpsWindowAt;
    double fps;
    uint64_t fpsFrames;
    uint64_t frames;
    uint64_t bytes;
    double lastFrameAt;
    double gapMax;
    int gapCount;
    int gapOver50;
    int gapUnder15;

    // 收包线程和解码线程共享，全部用 mu 保护
    pthread_mutex_t mu;
    pthread_cond_t cv;
    DecodeItem queue[AUXCAMD_DECODE_QUEUE_DEPTH];
    int queueHead;
    int queueCount;
    int resync;          // 队列溢出过：解码线程要等下一个关键帧再解码
    int pendingConfig;   // 有新的 SPS/PPS，解码线程要重建解码器
    VCU1ParamSet pendingSps;
    VCU1ParamSet pendingPps;
    int stopping;
    uint64_t decoded;
    uint64_t decodeErrors;
    uint64_t dropped;
    uint64_t decodeTimed;
    double decodeMsSum;
    double decodeMsMax;
    // 发布节奏：解码出来的帧先排队，再按固定 30fps 交给相机插件（抹平 USB/解码的快慢不均）
    CVPixelBufferRef paceQueue[AUXCAMD_PACE_MAX];
    int paceHead;
    int paceCount;
    int paceReady;
    uint64_t paceUnderruns;
    pthread_t paceThread;

    // 只在解码线程里用
    void *decoder;
    int waitingKeyframe;
    pthread_t decodeThread;
} Daemon;

static Daemon gDaemon;
static volatile sig_atomic_t gRunning = 1;

static double monotonic_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void on_signal(int sig) {
    (void)sig;
    gRunning = 0;
}

// App 只读这个文件：先写临时文件再 rename，保证读到的总是完整 JSON。
static void write_status(Daemon *d) {
    uint64_t decoded, dropped;
    pthread_mutex_lock(&d->mu);
    decoded = d->decoded;
    dropped = d->dropped;
    pthread_mutex_unlock(&d->mu);

    char tmp[PATH_MAX + 8];
    snprintf(tmp, sizeof(tmp), "%s.tmp", d->statusPath);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char json[512];
    int n = snprintf(json, sizeof(json),
                     "{\"pid\":%d,\"listening\":%s,\"connected\":%s,\"fps\":%.1f,"
                     "\"frames\":%llu,\"bytes\":%llu,\"decoded\":%llu,\"dropped\":%llu,\"updated\":%ld}\n",
                     (int)getpid(),
                     d->listening ? "true" : "false",
                     d->connected ? "true" : "false",
                     d->fps,
                     (unsigned long long)d->frames,
                     (unsigned long long)d->bytes,
                     (unsigned long long)decoded,
                     (unsigned long long)dropped,
                     (long)time(NULL));
    if (n > 0) {
        if (write(fd, json, (size_t)n) < 0) {
            // 状态文件写失败只影响 App 显示，不影响画面
        }
    }
    close(fd);
    rename(tmp, d->statusPath);
}

// 每秒调用一次：状态文件、fps 窗口、5 秒心跳日志、心跳超时检测。
static void tick(Daemon *d) {
    double t = monotonic_now();
    if (t - d->fpsWindowAt >= 1.0) {
        d->fps = (double)d->fpsFrames / (t - d->fpsWindowAt);
        d->fpsFrames = 0;
        d->fpsWindowAt = t;
    }
    if (d->connected && t - d->lastHeartbeatAt > AUXCAMD_HEARTBEAT_TIMEOUT) {
        vcu1_log(d->logPath, "heartbeat timeout");
        d->dropConnection = 1;
    }
    if (t - d->lastStatusAt >= 1.0) {
        write_status(d);
        d->lastStatusAt = t;
    }
    if (t - d->lastLogAt >= AUXCAMD_HEARTBEAT_LOG_SECONDS) {
        pthread_mutex_lock(&d->mu);
        uint64_t decoded = d->decoded, decodeErrors = d->decodeErrors, dropped = d->dropped;
        uint64_t underruns = d->paceUnderruns;
        double decodeAvg = d->decodeTimed ? d->decodeMsSum / (double)d->decodeTimed : 0;
        double decodeMax = d->decodeMsMax;
        d->decodeTimed = 0; d->decodeMsSum = 0; d->decodeMsMax = 0;   // 每次心跳重新统计
        pthread_mutex_unlock(&d->mu);
        vcu1_log(d->logPath, "heartbeat listening=%d connected=%d frames=%llu fps=%.1f decoded=%llu decodeErr=%llu dropped=%llu decodeAvgMs=%.1f decodeMaxMs=%.1f underruns=%llu",
                 d->listening, d->connected,
                 (unsigned long long)d->frames, d->fps,
                 (unsigned long long)decoded, (unsigned long long)decodeErrors, (unsigned long long)dropped,
                 decodeAvg, decodeMax, (unsigned long long)underruns);
        d->lastLogAt = t;
    }
}

// 等待 n 字节。每秒 tick 一次；5 秒没有数据或被要求断开就返回 -1。
static int read_full(Daemon *d, int fd, uint8_t *buf, size_t n) {
    size_t got = 0;
    double lastByteAt = monotonic_now();
    while (got < n) {
        struct pollfd p = {.fd = fd, .events = POLLIN, .revents = 0};
        int r = poll(&p, 1, 1000);
        tick(d);
        if (!gRunning || d->dropConnection) return -1;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) {
            if (monotonic_now() - lastByteAt > AUXCAMD_IDLE_SECONDS) {
                vcu1_log(d->logPath, "idle %.0fs, drop", AUXCAMD_IDLE_SECONDS);
                return -1;
            }
            continue;
        }
        ssize_t k = read(fd, buf + got, n - got);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        got += (size_t)k;
        lastByteAt = monotonic_now();
    }
    return 0;
}

// ---------- 解码线程 ----------

static void rebuild_decoder(Daemon *d, const VCU1ParamSet *sps, const VCU1ParamSet *pps) {
    if (d->decoder != NULL) auxh264_destroy(d->decoder);
    d->decoder = auxh264_create();
    d->waitingKeyframe = 1;
    if (d->decoder == NULL) {
        vcu1_log(d->logPath, "openh264 create failed");
        return;
    }
    // SPS/PPS 只在解码器初始化时补一次（和 App 的 StreamDecoder 一致）：每帧都补会让解码器判坏帧。
    size_t len = 8 + sps->length + pps->length;
    uint8_t *buf = malloc(len);
    if (buf == NULL) return;
    size_t o = 0;
    static const uint8_t sc[4] = {0, 0, 0, 1};
    memcpy(buf + o, sc, 4); o += 4;
    memcpy(buf + o, sps->bytes, sps->length); o += sps->length;
    memcpy(buf + o, sc, 4); o += 4;
    memcpy(buf + o, pps->bytes, pps->length); o += pps->length;
    CVPixelBufferRef image = NULL;
    auxh264_decode(d->decoder, buf, (int32_t)o, &image);
    if (image != NULL) CVPixelBufferRelease(image);
    free(buf);
}

// 放进发布队列（接管 image 的所有权）。队列满了丢最旧的，保证延迟不会越攒越大。
static void pace_push(Daemon *d, CVPixelBufferRef image) {
    pthread_mutex_lock(&d->mu);
    while (d->paceCount >= AUXCAMD_PACE_MAX) {
        CVPixelBufferRelease(d->paceQueue[d->paceHead]);
        d->paceHead = (d->paceHead + 1) % AUXCAMD_PACE_MAX;
        d->paceCount--;
    }
    int tail = (d->paceHead + d->paceCount) % AUXCAMD_PACE_MAX;
    d->paceQueue[tail] = image;
    d->paceCount++;
    pthread_mutex_unlock(&d->mu);
}

static void decode_one(Daemon *d, const uint8_t *data, size_t length) {
    CVPixelBufferRef image = NULL;
    double t0 = monotonic_now();
    int32_t r = auxh264_decode(d->decoder, data, (int32_t)length, &image);
    double ms = (monotonic_now() - t0) * 1000.0;
    pthread_mutex_lock(&d->mu);
    d->decodeTimed++;
    d->decodeMsSum += ms;
    if (ms > d->decodeMsMax) d->decodeMsMax = ms;
    pthread_mutex_unlock(&d->mu);
    if (image != NULL) {
        if (r == 1) {
            pace_push(d, image);
            pthread_mutex_lock(&d->mu);
            d->decoded++;
            pthread_mutex_unlock(&d->mu);
        } else {
            CVPixelBufferRelease(image);
        }
    } else if (r < 0) {
        pthread_mutex_lock(&d->mu);
        d->decodeErrors++;
        uint64_t n = d->decodeErrors;
        pthread_mutex_unlock(&d->mu);
        if (n <= 3 || n % 150 == 0) {
            vcu1_log(d->logPath, "decode error r=%d #%llu", r, (unsigned long long)n);
        }
    }
}

// 发布线程：每 1/30 秒从队列里取一帧发布。队列还没攒够 2 帧时不发，省得一开始就断断续续。
static void *pace_loop(void *arg) {
    Daemon *d = (Daemon *)arg;
    struct timespec next;
    clock_gettime(CLOCK_MONOTONIC, &next);
    for (;;) {
        next.tv_nsec += AUXCAMD_FRAME_INTERVAL_NS;
        while (next.tv_nsec >= 1000000000L) {
            next.tv_sec++;
            next.tv_nsec -= 1000000000L;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long long waitNs = (long long)(next.tv_sec - now.tv_sec) * 1000000000LL + (next.tv_nsec - now.tv_nsec);
        if (waitNs > 0) {
            struct timespec wait = {.tv_sec = (time_t)(waitNs / 1000000000LL), .tv_nsec = (long)(waitNs % 1000000000LL)};
            nanosleep(&wait, NULL);
        } else if (waitNs < -100000000LL) {
            next = now;   // 落后超过 100ms（比如睡眠唤醒）就重新对齐，不要连续突发发布
        }

        pthread_mutex_lock(&d->mu);
        if (d->stopping) {
            pthread_mutex_unlock(&d->mu);
            break;
        }
        CVPixelBufferRef out = NULL;
        if (!d->paceReady) {
            if (d->paceCount >= AUXCAMD_PACE_PRIME) d->paceReady = 1;
        } else if (d->paceCount == 0) {
            d->paceUnderruns++;      // 没有新帧：相机插件会继续显示上一帧，这里不发
        } else {
            out = d->paceQueue[d->paceHead];
            d->paceHead = (d->paceHead + 1) % AUXCAMD_PACE_MAX;
            d->paceCount--;
        }
        pthread_mutex_unlock(&d->mu);

        if (out != NULL) {
            auxcam_publish_shared_frame(out);
            CVPixelBufferRelease(out);
        }
    }
    return NULL;
}

static void *decode_loop(void *arg) {
    Daemon *d = (Daemon *)arg;
    for (;;) {
        pthread_mutex_lock(&d->mu);
        while (!d->stopping && d->queueCount == 0 && !d->pendingConfig && !d->resync) {
            pthread_cond_wait(&d->cv, &d->mu);
        }
        if (d->stopping) {
            pthread_mutex_unlock(&d->mu);
            break;
        }
        if (d->resync) {
            d->resync = 0;
            d->waitingKeyframe = 1;
        }
        int hasConfig = d->pendingConfig;
        VCU1ParamSet sps = d->pendingSps;
        VCU1ParamSet pps = d->pendingPps;
        d->pendingConfig = 0;
        DecodeItem item = {NULL, 0, 0};
        if (d->queueCount > 0) {
            item = d->queue[d->queueHead];
            d->queueHead = (d->queueHead + 1) % AUXCAMD_DECODE_QUEUE_DEPTH;
            d->queueCount--;
        }
        pthread_mutex_unlock(&d->mu);

        if (hasConfig) rebuild_decoder(d, &sps, &pps);
        if (item.data != NULL) {
            if (d->decoder != NULL && (!d->waitingKeyframe || item.keyframe)) {
                if (item.keyframe) d->waitingKeyframe = 0;
                decode_one(d, item.data, item.length);
            }
            free(item.data);
        }
    }
    if (d->decoder != NULL) {
        auxh264_destroy(d->decoder);
        d->decoder = NULL;
    }
    return NULL;
}

// 收包线程调用：把一帧放进解码队列。队列满了就清空、标记要等关键帧，宁可丢帧也不阻塞收包。
static void enqueue_frame(Daemon *d, const uint8_t *payload, size_t length, int keyframe) {
    uint8_t *copy = malloc(length > 0 ? length : 1);
    if (copy == NULL) return;
    memcpy(copy, payload, length);

    pthread_mutex_lock(&d->mu);
    if (d->queueCount == AUXCAMD_DECODE_QUEUE_DEPTH) {
        while (d->queueCount > 0) {
            free(d->queue[d->queueHead].data);
            d->queueHead = (d->queueHead + 1) % AUXCAMD_DECODE_QUEUE_DEPTH;
            d->queueCount--;
        }
        d->resync = 1;
        d->dropped++;
    }
    int tail = (d->queueHead + d->queueCount) % AUXCAMD_DECODE_QUEUE_DEPTH;
    d->queue[tail].data = copy;
    d->queue[tail].length = length;
    d->queue[tail].keyframe = keyframe;
    d->queueCount++;
    pthread_cond_signal(&d->cv);
    pthread_mutex_unlock(&d->mu);
}

// ---------- 收包线程 ----------

static void handle_config(Daemon *d, const uint8_t *payload, uint32_t length) {
    VCU1ParamSet sps, pps;
    if (vcu1_parse_avcc(payload, length, &sps, &pps) != 0) {
        vcu1_log(d->logPath, "type1 config unparsed len=%u", length);
        return;
    }
    vcu1_log(d->logPath, "type1 config, sps=%zu pps=%zu", sps.length, pps.length);
    int changed = !d->haveConfig ||
        sps.length != d->sps.length || pps.length != d->pps.length ||
        memcmp(sps.bytes, d->sps.bytes, sps.length) != 0 ||
        memcmp(pps.bytes, d->pps.bytes, pps.length) != 0;
    d->sps = sps;
    d->pps = pps;
    d->haveConfig = 1;
    if (changed) {
        pthread_mutex_lock(&d->mu);
        d->pendingSps = sps;
        d->pendingPps = pps;
        d->pendingConfig = 1;
        pthread_cond_signal(&d->cv);
        pthread_mutex_unlock(&d->mu);
    }
}

static void handle_video(Daemon *d, const VCU1Header *h, const uint8_t *payload) {
    int keyframe = (h->flags & VCU1_FLAG_KEYFRAME) != 0;
    double now = monotonic_now();
    if (d->lastFrameAt > 0) {
        double gapMs = (now - d->lastFrameAt) * 1000.0;
        d->gapCount++;
        if (gapMs > d->gapMax) d->gapMax = gapMs;
        if (gapMs > 50) d->gapOver50++;
        if (gapMs < 15) d->gapUnder15++;
        if (d->gapCount >= AUXCAMD_GAP_WINDOW) {
            vcu1_log(d->logPath, "到包间隔 近90帧: 最大=%dms 超过50ms=%d次 小于15ms=%d次",
                     (int)d->gapMax, d->gapOver50, d->gapUnder15);
            d->gapMax = 0;
            d->gapCount = 0;
            d->gapOver50 = 0;
            d->gapUnder15 = 0;
        }
    }
    d->lastFrameAt = now;
    d->frames++;
    d->fpsFrames++;
    d->bytes += h->length;

    if (keyframe) vcu1_log(d->logPath, "type2 KEYFRAME len=%u", h->length);
    // 先落盘（不会阻塞），再交给解码线程。配置没到之前没有解码器，不排队。
    vcu1_ring_append(&d->ring, payload, h->length, keyframe, &d->sps, &d->pps);
    if (d->haveConfig) enqueue_frame(d, payload, h->length, keyframe);
}

static void handle_packet(Daemon *d, const VCU1Header *h, const uint8_t *payload) {
    switch (h->type) {
    case VCU1_TYPE_CONFIG:
        handle_config(d, payload, h->length);
        break;
    case VCU1_TYPE_VIDEO:
        handle_video(d, h, payload);
        break;
    case VCU1_TYPE_HEARTBEAT:
        d->lastHeartbeatAt = monotonic_now();
        break;
    default:
        // 类型 3/4（音频）、10（MJPEG）PC 端现在不发，只记一次。
        if (!d->seenType[h->type]) {
            d->seenType[h->type] = 1;
            vcu1_log(d->logPath, "type %u not handled by auxcamd, skipped", h->type);
        }
        break;
    }
}

static void serve_connection(Daemon *d, int fd) {
    d->connected = 1;
    d->dropConnection = 0;
    d->lastHeartbeatAt = monotonic_now();
    vcu1_log(d->logPath, "conn accepted");
    write_status(d);

    uint8_t head[VCU1_HEADER_BYTES];
    while (gRunning) {
        if (read_full(d, fd, head, sizeof(head)) != 0) break;
        VCU1Header h;
        int rc = vcu1_parse_header(head, &h);
        if (rc == -1) {
            vcu1_log(d->logPath, "bad magic");
            break;
        }
        if (rc == -2) {
            vcu1_log(d->logPath, "bad ver/len: v=%u len=%u", h.version, h.length);
            break;
        }
        if (h.length > d->payloadCap) {
            size_t want = h.length > 0 ? h.length : 1;
            uint8_t *grown = realloc(d->payload, want);
            if (grown == NULL) break;
            d->payload = grown;
            d->payloadCap = want;
        }
        if (h.length > 0 && read_full(d, fd, d->payload, h.length) != 0) {
            vcu1_log(d->logPath, "payload short");
            break;
        }
        handle_packet(d, &h, d->payload);
        if (d->dropConnection) break;
    }
    d->connected = 0;
    vcu1_log(d->logPath, "conn closed");
    write_status(d);
}

int main(void) {
    const char *dirEnv = getenv("AUXCAMD_DIR");   // 只为本机测试用，launchd 下不设置
    const char *dir = (dirEnv != NULL && dirEnv[0] != '\0') ? dirEnv : AUXCAMD_DEFAULT_DIR;
    Daemon *d = &gDaemon;
    char ringPath[PATH_MAX];
    snprintf(ringPath, sizeof(ringPath), "%s/stream.h264", dir);
    snprintf(d->logPath, sizeof(d->logPath), "%s/.vcu1.log", dir);
    snprintf(d->statusPath, sizeof(d->statusPath), "%s/.auxcamd.status", dir);
    vcu1_ring_init(&d->ring, ringPath);
    d->fpsWindowAt = monotonic_now();
    d->lastStatusAt = d->fpsWindowAt;
    d->lastLogAt = d->fpsWindowAt;
    pthread_mutex_init(&d->mu, NULL);
    pthread_cond_init(&d->cv, NULL);
    if (pthread_create(&d->decodeThread, NULL, decode_loop, d) != 0) {
        vcu1_log(d->logPath, "decode thread create failed");
        return 1;
    }
    if (pthread_create(&d->paceThread, NULL, pace_loop, d) != 0) {
        vcu1_log(d->logPath, "pacer thread create failed");
        return 1;
    }

    signal(SIGPIPE, SIG_IGN);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;   // 不设 SA_RESTART：poll 才能被打断去收尾
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    int listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) {
        vcu1_log(d->logPath, "socket failed errno=%d", errno);
        return 1;
    }
    int on = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(AUXCAMD_PORT);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);   // 只绑回环，不对外
    if (bind(listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        vcu1_log(d->logPath, "bind 127.0.0.1:%d failed errno=%d", AUXCAMD_PORT, errno);
        close(listenFd);
        sleep(2);   // launchd 会拉起重试；旧进程还没退出时 bind 会失败
        return 1;
    }
    if (listen(listenFd, 128) != 0) {
        vcu1_log(d->logPath, "listen failed errno=%d", errno);
        close(listenFd);
        return 1;
    }
    d->listening = 1;
    fprintf(stderr, "auxcamd start dir=%s pid=%d\n", dir, (int)getpid());
    vcu1_log(d->logPath, "auxcamd start pid=%d listening 127.0.0.1:%d", (int)getpid(), AUXCAMD_PORT);
    write_status(d);

    while (gRunning) {
        struct pollfd p = {.fd = listenFd, .events = POLLIN, .revents = 0};
        int r = poll(&p, 1, 1000);
        if (r > 0 && (p.revents & POLLIN)) {
            int cfd = accept(listenFd, NULL, NULL);
            if (cfd >= 0) {
                serve_connection(d, cfd);
                close(cfd);
            }
        }
        tick(d);
    }

    d->listening = 0;
    d->connected = 0;
    vcu1_log(d->logPath, "auxcamd stop");
    write_status(d);
    close(listenFd);

    pthread_mutex_lock(&d->mu);
    d->stopping = 1;
    pthread_cond_broadcast(&d->cv);
    pthread_mutex_unlock(&d->mu);
    pthread_join(d->decodeThread, NULL);
    pthread_join(d->paceThread, NULL);
    while (d->paceCount > 0) {
        CVPixelBufferRelease(d->paceQueue[d->paceHead]);
        d->paceHead = (d->paceHead + 1) % AUXCAMD_PACE_MAX;
        d->paceCount--;
    }
    while (d->queueCount > 0) {
        free(d->queue[d->queueHead].data);
        d->queueHead = (d->queueHead + 1) % AUXCAMD_DECODE_QUEUE_DEPTH;
        d->queueCount--;
    }
    vcu1_ring_close(&d->ring);
    free(d->payload);
    return 0;
}
