// AuxCamTweak — 把相机画面换成电脑推过来的视频
// 原理：钩住 AVCaptureVideoDataOutput 的取帧回调，把真帧换成我们自己的帧
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kConfPath = @"/var/mobile/auxcam.conf";
static NSString *const kLogPath  = @"/var/mobile/auxcam.log";

static AVPlayer *gPlayer = nil;
static AVPlayerItemVideoOutput *gOut = nil;
static NSString *gURL = nil;
static BOOL gOn = NO;
static BOOL gLogged = NO;

static void ALog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[AuxCam] %@", s);
    FILE *f = fopen(kLogPath.UTF8String, "a");
    if (f) {
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDate date], s];
        fputs(line.UTF8String, f);
        fclose(f);
    }
}

// ---------- 造一帧（从电脑推来的流里取）----------
static CMSampleBufferRef AuxCamMakeBuffer(void) {
    if (!gOut || !gPlayer) return NULL;

    CMTime t = [gOut itemTimeForHostTime:CACurrentMediaTime()];
    CVPixelBufferRef pb = NULL;

    if ([gOut hasNewPixelBufferForItemTime:t]) {
        pb = [gOut copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
    }
    if (!pb) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(pb);
        return NULL;
    }

    CMSampleTimingInfo timing = {
        .duration              = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600),
        .decodeTimeStamp       = kCMTimeInvalid
    };

    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb);

    CFRelease(fmt);
    CVPixelBufferRelease(pb);

    if (st != noErr || !sb) return NULL;
    return sb;
}

// ---------- 起流 ----------
static void AuxCamStartStream(NSString *urlStr) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { ALog(@"地址不对: %@", urlStr); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (gPlayer) { [gPlayer pause]; gPlayer = nil; gOut = nil; }

            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            item.preferredForwardBufferDuration = 1.0;

            gPlayer = [AVPlayer playerWithPlayerItem:item];
            gPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            gPlayer.muted = YES;
            gPlayer.automaticallyWaitsToMinimizeStalling = YES;

            NSDictionary *attrs = @{
                (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            gOut = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
            [item addOutput:gOut];
            [gPlayer play];

            ALog(@"开始收流: %@", urlStr);
        } @catch (NSException *e) {
            ALog(@"起流崩了: %@", e);
        }
    });
}

// ---------- 读配置 ----------
static void AuxCamLoadConf(void) {
    NSString *s = [NSString stringWithContentsOfFile:kConfPath encoding:NSUTF8StringEncoding error:nil];
    if (!s) { gOn = NO; return; }

    NSString *url = nil;
    BOOL on = NO;

    for (NSString *raw in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        NSString *low = t.lowercaseString;
        if ([low isEqualToString:@"on"])  { on = YES; continue; }
        if ([low isEqualToString:@"off"]) { on = NO;  continue; }
        if ([low hasPrefix:@"http"])      { url = t;  continue; }
    }

    if (url.length > 0 && ![url isEqualToString:gURL]) {
        gURL = url;
        AuxCamStartStream(url);
    }
    gOn = (on && gURL.length > 0);

    if (!gLogged) {
        gLogged = YES;
        ALog(@"配置: on=%d url=%@", on, gURL ?: @"(空)");
    }
}

// ---------- 代理：接住 App 的取帧回调，把帧换掉再转发 ----------
@interface AuxCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id orig;
@end

@implementation AuxCamProxy

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CMSampleBufferRef use = sampleBuffer;
    CMSampleBufferRef fake = NULL;

    if (gOn && [output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        fake = AuxCamMakeBuffer();
        if (fake) use = fake;
    }

    id o = self.orig;
    if (o && [o respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        @try {
            [o captureOutput:output didOutputSampleBuffer:use fromConnection:connection];
        } @catch (NSException *e) {
            ALog(@"转发崩了: %@", e);
        }
    }

    if (fake) CFRelease(fake);
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id o = self.orig;
    if (o && [o respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [o captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

// ---------- 钩子 ----------
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    id use = delegate;
    if (delegate) {
        AuxCamProxy *p = [AuxCamProxy new];
        p.orig = delegate;
        use = p;
        ALog(@"已接管取帧 (orig=%@)", NSStringFromClass([delegate class]));
    }
    %orig(use, queue);
}

%end

// ---------- 启动 ----------
%ctor {
    ALog(@"插件已加载");
    AuxCamLoadConf();

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            AuxCamLoadConf();
        }];
    });
}
