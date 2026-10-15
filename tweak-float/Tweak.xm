// AuxCamFloat —— 抖音里的悬浮控制条
// 注入抖音进程（TweakLoader），屏幕下沿浮一条：开始/停止 + 镜像 + 旋转 + 恢复
// 指令/状态走抖音自己的 Documents/auxcam.cmd、auxcam.stat（内核会读写这个容器）
// 拖住条子可以移动位置
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static UIWindow *gWin = nil;
static UIButton *gStart = nil;
static UIView *gDot = nil;

static NSString *StatPath(void) {
    static NSString *p = nil;
    if (!p) {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        p = [d stringByAppendingPathComponent:@"auxcam.stat"];
    }
    return p;
}

static NSString *CmdPath(void) {
    static NSString *p = nil;
    if (!p) {
        NSString *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        p = [d stringByAppendingPathComponent:@"auxcam.cmd"];
    }
    return p;
}

// 只发 cmd（不带 mode/url，内核会保持 App 里选的模式）
static void Send(NSString *cmd) {
    NSString *t = [NSString stringWithFormat:@"cmd=%@\nts=%lld\n", cmd, (long long)[[NSDate date] timeIntervalSince1970]];
    [t writeToFile:CmdPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static BOOL IsStreaming(void) {
    NSString *t = [NSString stringWithContentsOfFile:StatPath() encoding:NSUTF8StringEncoding error:nil];
    if (!t) return NO;
    for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"playing="]) {
            NSString *v = [line substringFromIndex:8];
            return !([v containsString:@"正常相机"]);
        }
    }
    return NO;
}

@interface AuxFloatVC : UIViewController
@end

@implementation AuxFloatVC

- (void)loadView {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 256, 50)];
    bar.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.88];
    bar.layer.cornerRadius = 25;
    bar.layer.masksToBounds = YES;
    bar.layer.borderWidth = 1;
    bar.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    self.view = bar;

    gDot = [[UIView alloc] initWithFrame:CGRectMake(12, 20, 10, 10)];
    gDot.backgroundColor = [UIColor grayColor];
    gDot.layer.cornerRadius = 5;
    [bar addSubview:gDot];

    NSArray *titles = @[@"开始", @"镜像", @"旋转", @"恢复"];
    NSArray *cmds = @[@"start", @"mirror", @"rotate", @"reset"];
    CGFloat x = 30;
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 6, 52, 38);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
        b.layer.cornerRadius = 10;
        b.tag = i;
        [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:b];
        if (i == 0) gStart = b;
        x += 58;
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(move:)];
    [bar addGestureRecognizer:pan];

    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
        BOOL s = IsStreaming();
        [gStart setTitle:s ? @"停止" : @"开始" forState:UIControlStateNormal];
        gStart.backgroundColor = s ? [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:0.9]
                                   : [UIColor colorWithWhite:1 alpha:0.14];
        gDot.backgroundColor = s ? [UIColor greenColor] : [UIColor grayColor];
    }];
}

- (void)tap:(UIButton *)b {
    NSArray *cmds = @[@"start", @"mirror", @"rotate", @"reset"];
    NSString *c = cmds[b.tag];
    if ([c isEqualToString:@"start"] && IsStreaming()) c = @"stop";
    Send(c);
}

- (void)move:(UIPanGestureRecognizer *)pan {
    static CGPoint off = {0, 0};
    if (pan.state == UIGestureRecognizerStateBegan) {
        off = [pan locationInView:gWin];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [pan locationInView:nil];       // nil = 屏幕坐标
        CGRect f = gWin.frame;
        f.origin.x = p.x - off.x;
        f.origin.y = p.y - off.y;
        gWin.frame = f;
    }
}

@end

__attribute__((constructor)) static void AuxFloatInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gWin) return;
            UIWindowScene *scene = nil;
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
            }
            gWin = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                         : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            gWin.windowLevel = UIWindowLevelAlert + 2;
            gWin.rootViewController = [AuxFloatVC new];
            CGFloat sw = UIScreen.mainScreen.bounds.size.width;
            CGFloat sh = UIScreen.mainScreen.bounds.size.height;
            gWin.frame = CGRectMake(sw - 268, sh - 210, 256, 50);
            gWin.hidden = NO;
        });
    });
}
