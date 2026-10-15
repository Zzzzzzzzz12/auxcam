// AuxCamBoot —— 开机/越狱后自动把内核（agent12.sh）拉起来
//
// 为什么需要它：内核是 root 脚本，重启+重新越狱后 launchd 不一定把它拉起来。
// 这个插件被注入到"系统进程"里，只要有一个 root 进程带着它起来，它就把内核起回来。
// 目标进程（靠 AuxCamBoot.plist 过滤表限制）：
//   cameracaptured   —— root，你一开相机它就加载（最可靠）
//   backboardd       —— root，开机就有的系统进程
//   SpringBoard      —— 普通权限，做不了事，只写日志（留着看注入有没有生效）
//   jailbreakd       —— root，越狱自己用的进程
//
// 安全设计（绝不影响手机正常用）：
//   1) 只在 root 进程里动手；普通进程立刻返回
//   2) 动手前先看内核心跳，还活着就不重复启动
//   3) 任何一步失败都静默退出，不抛异常、不阻塞、不卡启动
//   4) 日志写 /var/mobile/Media/DCIM/.auxcam-boot.log（电脑能读）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <glob.h>
#include <fcntl.h>
#include <time.h>
#include <pthread.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>

extern char **environ;

static const char *kLogPath  = "/private/var/mobile/Media/DCIM/.auxcam-boot.log";
static const char *kBeatPath = "/private/var/mobile/Media/DCIM/.auxcam-agent-heartbeat";
static const char *kScriptDCIM = "/private/var/mobile/Media/DCIM/agent12.sh";

static void BLog(const char *fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
    va_end(ap);

    FILE *f = fopen(kLogPath, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d pid=%d uid=%d] %s\n",
            tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
            tmv.tm_hour, tmv.tm_min, tmv.tm_sec, getpid(), getuid(), buf);
    fclose(f);
}

static int StatFresh(const char *path, int maxAgeSec) {
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    time_t now = time(NULL);
    if (st.st_mtime <= 0) return 0;
    if (now - st.st_mtime <= maxAgeSec) return 1;
    return 0;
}

// 内核还活着吗：心跳文件 90 秒内更新过就算活着
static int AgentAlive(void) {
    return StatFresh(kBeatPath, 90);
}

// 找 jbroot（每次重新越狱名字都会变，所以只能现场找）
static int FindJB(char *out, size_t outsz) {
    const char *pats[3] = {
        "/private/var/containers/Bundle/Application/.jbroot-*",
        "/private/var/.jbroot-*",
        "/var/containers/Bundle/Application/.jbroot-*"
    };
    for (int i = 0; i < 3; i++) {
        glob_t g;
        memset(&g, 0, sizeof(g));
        if (glob(pats[i], 0, NULL, &g) == 0 && g.gl_pathc > 0) {
            for (size_t j = 0; j < g.gl_pathc; j++) {
                struct stat st;
                if (stat(g.gl_pathv[j], &st) == 0 && S_ISDIR(st.st_mode)) {
                    snprintf(out, outsz, "%s", g.gl_pathv[j]);
                    globfree(&g);
                    return 1;
                }
            }
        }
        globfree(&g);
    }
    return 0;
}

static int SpawnDetached(const char *exe, char *const argv[]) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    short flags = POSIX_SPAWN_SETSID;
    posix_spawnattr_setflags(&at, flags);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, exe, &fa, &at, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    if (rc != 0) { BLog("posix_spawn 失败 rc=%d (%s) exe=%s", rc, strerror(rc), exe); return 0; }
    BLog("已拉起内核 pid=%d exe=%s", (int)pid, exe);
    return 1;
}

static int StartKernel(void) {
    char jb[512]; jb[0] = 0;
    if (!FindJB(jb, sizeof(jb))) { BLog("没找到 jbroot 目录"); return 0; }
    BLog("jbroot=%s", jb);

    // 脚本位置：优先用 DCIM 里那份（路径固定，不受重新越狱改名影响）
    char script[600];
    struct stat st;
    if (stat(kScriptDCIM, &st) == 0) {
        snprintf(script, sizeof(script), "%s", kScriptDCIM);
    } else {
        snprintf(script, sizeof(script), "%s/var/auxcam/agent12.sh", jb);
    }
    if (stat(script, &st) != 0) { BLog("脚本不存在: %s", script); return 0; }

    const char *shells[5];
    char s0[600], s1[600], s2[600], s3[600];
    snprintf(s0, sizeof(s0), "%s/usr/bin/sh", jb);
    snprintf(s1, sizeof(s1), "%s/bin/sh", jb);
    snprintf(s2, sizeof(s2), "%s/usr/bin/bash", jb);
    snprintf(s3, sizeof(s3), "%s/bin/bash", jb);
    shells[0] = s0; shells[1] = s1; shells[2] = s2; shells[3] = s3; shells[4] = NULL;

    for (int i = 0; i < 4; i++) {
        if (stat(shells[i], &st) != 0) continue;
        char *argv[3];
        argv[0] = (char *)shells[i];
        argv[1] = script;
        argv[2] = NULL;
        if (SpawnDetached(shells[i], argv)) return 1;
    }
    BLog("找不到可用的 sh（4 个候选都没有）");
    return 0;
}

static void *BootThread(void *arg) {
    (void)arg;
    sleep(6);                      // 等系统站稳
    if (AgentAlive()) { BLog("内核已经在跑，不动它"); return NULL; }
    BLog("内核不在跑 → 我来起");
    for (int i = 0; i < 3; i++) {
        StartKernel();
        sleep(12);
        if (AgentAlive()) { BLog("内核起来了（第 %d 次尝试）", i + 1); return NULL; }
    }
    BLog("三次都没拉起来（交给 launchd 那边）");
    return NULL;
}

__attribute__((constructor)) static void AuxCamBootInit(void) {
    BLog("AuxCamBoot 已加载 pid=%d uid=%d euid=%d", getpid(), getuid(), geteuid());
    if (geteuid() != 0) {
        BLog("普通权限进程，什么都不做");
        return;
    }
    pthread_t t;
    if (pthread_create(&t, NULL, BootThread, NULL) == 0) pthread_detach(t);
}
