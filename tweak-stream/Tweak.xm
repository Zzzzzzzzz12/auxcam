// AuxCamStream —— 手机侧"采集电脑推流 → 替换相机画面"的插件
// 目标进程：系统相机服务（cameracaptured）
// 原理：钩住相机图里"出画面"的那一步（BWNodeOutput -emitSampleBuffer:），
//       把电脑推来的 HLS 流里的最新一帧拷进相机帧的像素缓冲。
// 声音完全不管：不碰任何音频通路。
//
// 依赖：只用 ObjC runtime 交换方法实现，不需要 substrate/ellekit 链接
// 配置：/var/mobile/Media/AuxCamInstall/agent.conf 里的 url=（改完 5 秒生效，不需重装）
// 心跳：/var/mobile/Media/DCIM/.auxcam-stream-heartbeat（电脑可读，用来确认它活着）

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>

static NSString *const kConfPath = @"/var/mobile/Media/AuxCamInstall/agent.conf";
static NSString *const kBeatPath = @"/var/mobile/Media/DCIM/.auxcam-stream-heartbeat";
static NSString *const kLogPath  = @"/var/mobile/Media/DCIM/.auxcam-stream.log";

static AVPlayer *gPlayer = nil;
static AVPlayerItemVideoOutput *gOut = nil;
static NSString *gURL = nil;
static BOOL gOn = NO;
static int gFrames = 0;
static int gCopied = 0;

static void SLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AuxCamStream] %@", s);
    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (f) {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], s];
        fputs(line.UTF8String, f);
        fclose(f);
    }
}

// ---------- 读配置 ----------
static void LoadConf(void) {
    NSString *txt = [NSString stringWithContentsOfFile:kConfPath encoding:NSUTF8StringEncoding error:nil];
    if (!txt) { gOn = NO; return; }
    NSString *url = nil;
    for (NSString *raw in [txt componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"url"] && [t rangeOfString:@"="].location != NSNotFound) {
            url = [[t componentsSeparatedByString:@"="] lastObject];
            url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    if (url.length == 0) { gOn = NO; gURL = nil; return; }
    if (![url isEqualToString:gURL]) {
        gURL = url;
        SLog(@"发现流地址: %@", url);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (gPlayer) { [gPlayer pause]; gPlayer = nil; gOut = nil; }
                AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:url] options:nil];
                AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
                item.preferredForwardBufferDuration = 1.0;
                gPlayer = [AVPlayer playerWithPlayerItem:item];
                gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
                gPlayer.muted = YES;
                gPlayer.automaticallyWaitsToMinimizeStalling = YES;
                NSDictionary *attrs = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
                };
                gOut = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
                [item addOutput:gOut];
                [gPlayer play];
                gOn = YES;
                SLog(@"开始拉流: %@", url);
            } @catch (NSException *e) {
                SLog(@"起流异常: %@", e);
                gOn = NO;
            }
        });
    } else {
        gOn = YES;
    }
}

// ---------- 像素搬运（填充 + 居中裁切，简单缩放） ----------
static void CopyPlane(UInt8 *d, size_t dRow, int dx, int dy, int dw, int dh,
                      UInt8 *s, size_t sRow, int sw, int sh, int planeW, int planeH) {
    // 目标区域里逐点取源（最近邻）；dx/dy/dw/dh 是目标平面里的可见区域
    for (int y = 0; y < dh; y++) {
        int sy = (int)((float)y * sh / dh);
        if (sy < 0) sy = 0; if (sy >= sh) sy = sh - 1;
        UInt8 *dp = d + (size_t)(y + dy) * dRow + dx;
        UInt8 *sp = s + (size_t)sy * sRow;
        for (int x = 0; x < dw; x++) {
            int sx = (int)((float)x * sw / dw);
            if (sx < 0) sx = 0; if (sx >= sw) sx = sw - 1;
            dp[x] = sp[sx];
        }
    }
}

static void Blit(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return;
    OSType sf = CVPixelBufferGetPixelFormatType(src);
    OSType df = CVPixelBufferGetPixelFormatType(dst);
    BOOL sPlanar = (sf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                    sf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    BOOL dPlanar = (df == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                    df == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    if (!sPlanar || !dPlanar) {
        static int once = 0;
        if (once++ < 3) SLog(@"格式不支持: src=%u dst=%u（这一帧放行）", (unsigned)sf, (unsigned)df);
        return;
    }
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        return;
    }
    int sw = (int)CVPixelBufferGetWidthOfPlane(src, 0);
    int sh = (int)CVPixelBufferGetHeightOfPlane(src, 0);
    int dw = (int)CVPixelBufferGetWidthOfPlane(dst, 0);
    int dh = (int)CVPixelBufferGetHeightOfPlane(dst, 0);
    UInt8 *sp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 0);
    UInt8 *dp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    size_t sRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0);
    size_t dRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    if (sp && dp && sw > 0 && sh > 0 && dw > 0 && dh > 0) {
        CopyPlane(dp, dRow, 0, 0, dw, dh, sp, sRow, sw, sh, dw, dh);
    }
    // 色度平面
    int scw = (int)CVPixelBufferGetWidthOfPlane(src, 1);
    int sch = (int)CVPixelBufferGetHeightOfPlane(src, 1);
    int dcw = (int)CVPixelBufferGetWidthOfPlane(dst, 1);
    int dch = (int)CVPixelBufferGetHeightOfPlane(dst, 1);
    UInt8 *scp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(src, 1);
    UInt8 *dcp = (UInt8 *)CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t scRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1);
    size_t dcRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
    if (scp && dcp && scw > 0 && sch > 0 && dcw > 0 && dch > 0) {
        for (int y = 0; y < dch; y++) {
            int sy = (int)((float)y * sch / dch);
            if (sy >= sch) sy = sch - 1;
            UInt8 *dpp = dcp + (size_t)y * dcRow;
            UInt8 *spp = scp + (size_t)sy * scRow;
            for (int x = 0; x < dcw * 2; x++) {
                int sx = (int)((float)x * (scw * 2) / (dcw * 2));
                if (sx >= scw * 2) sx = scw * 2 - 1;
                dpp[x] = spp[sx];
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
}

// ---------- 钩子 ----------
static IMP gOrigEmit = NULL;

static void AuxEmitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sb) {
    if (gOn && gOut && gPlayer && sb) {
        gFrames++;
        CVPixelBufferRef dst = CMSampleBufferGetImageBuffer(sb);
        if (dst) {
            CMTime t = [gOut itemTimeForHostTime:CACurrentMediaTime()];
            if ([gOut hasNewPixelBufferForItemTime:t]) {
                CVPixelBufferRef src = [gOut copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
                if (src) {
                    Blit(src, dst);
                    CVPixelBufferRelease(src);
                    gCopied++;
                }
            }
        }
        if ((gFrames % 300) == 0) {
            NSString *beat = [NSString stringWithFormat:@"frames=%d copied=%d url=%@ time=%@\n",
                              gFrames, gCopied, gURL ?: @"-", [NSDate date]];
            [beat writeToFile:kBeatPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
    if (gOrigEmit) ((void (*)(id, SEL, CMSampleBufferRef))gOrigEmit)(self, _cmd, sb);
}

__attribute__((constructor)) static void AuxCamStreamInit(void) {
    SLog(@"插件已加载（进程 %@）", [[NSProcessInfo processInfo] processName]);
    LoadConf();
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (;;) {
            @autoreleasepool { LoadConf(); }
            [NSThread sleepForTimeInterval:5.0];
        }
    });
    Class c = objc_getClass("BWNodeOutput");
    if (!c) c = NSClassFromString(@"BWNodeOutput");
    if (!c) { SLog(@"没找到 BWNodeOutput 类（这版系统可能改了名字）"); return; }
    SEL s = NSSelectorFromString(@"emitSampleBuffer:");
    Method m = class_getInstanceMethod(c, s);
    if (!m) { SLog(@"没找到 emitSampleBuffer: 方法"); return; }
    gOrigEmit = method_getImplementation(m);
    method_setImplementation(m, (IMP)AuxEmitSampleBuffer);
    SLog(@"已挂钩 BWNodeOutput -emitSampleBuffer:");
}
