// AuxCamFloat —— 系统级悬浮小窗（注入 SpringBoard，所以在任何界面都能看到）
// 平时是小圆球；点一下展开小卡片：开始/停止 + 镜像 + 旋转 + 恢复 + 打开 App。
// 窗口是全屏透明的（点到空白处直接穿透给下面的界面），圆球/卡片是窗口里面的小方块，
// 拖动时只移动小方块，不动窗口本身，所以不会有残影。
// 和 AuxCam App 的通信（都走 /var/mobile/Media/DCIM）：
//   .auxcam-float.state  App 每 0.5 秒写一次（live/ack/ts）
//   .auxcam-float.cmd    小窗写指令（cmd/id/ts），App 读到后执行，并把 id 写回 state 的 ack
// 状态文件 4 秒没更新 = App 休眠了（圆球小点变橙色）；60 秒没更新 = App 被关掉了（圆球消失）。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define AUX_BALL 46.0
#define AUX_CARD_W 214.0
#define AUX_CARD_H 178.0
#define AUX_APP_ID @"com.auxcam.app"

static NSString *const kStatePath = @"/var/mobile/Media/DCIM/.auxcam-float.state";
static NSString *const kCmdPath = @"/var/mobile/Media/DCIM/.auxcam-float.cmd";
static NSString *const kLogPath = @"/var/mobile/Media/DCIM/.auxcam-float.log";

static UIWindow *gWin = nil;
static UIView *gHolder = nil;     // 会移动的小方块（圆球或卡片）
static UIButton *gStart = nil;
static UIView *gDot = nil;
static UILabel *gStatus = nil;
static UIView *gCard = nil;
static UIButton *gBall = nil;
static int gCmdSeq = 0;
static NSString *gLastCmdID = nil;

static void AuxLog(NSString *msg) {
    static int n = 0;
    if (n++ > 400) return;
    NSString *line = [NSString stringWithFormat:@"%lld %@\n", (long long)[[NSDate date] timeIntervalSince1970], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!h) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void SendCmd(NSString *cmd) {
    gCmdSeq++;
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *cid = [NSString stringWithFormat:@"%lld-%d", now, gCmdSeq];
    NSString *t = [NSString stringWithFormat:@"cmd=%@\nid=%@\nts=%lld\n", cmd, cid, now];
    BOOL ok = [t writeToFile:kCmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gLastCmdID = cid;
    AuxLog([NSString stringWithFormat:@"click -> cmd=%@ id=%@ write=%d", cmd, cid, ok]);
}

// 读 App 写的状态。返回：0 = App 没开（60秒没更新），1 = 休眠（4秒没更新），2 = 正常
static int ReadState(BOOL *live, NSString **ack) {
    NSString *t = [NSString stringWithContentsOfFile:kStatePath encoding:NSUTF8StringEncoding error:nil];
    if (!t) return 0;
    long long ts = 0;
    BOOL l = NO;
    NSString *a = @"";
    for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"ts="]) ts = [[line substringFromIndex:3] longLongValue];
        if ([line hasPrefix:@"live="]) l = [[line substringFromIndex:5] intValue] == 1;
        if ([line hasPrefix:@"ack="]) a = [line substringFromIndex:4];
    }
    if (live) *live = l;
    if (ack) *ack = a;
    long long age = (long long)[[NSDate date] timeIntervalSince1970] - ts;
    if (age > 60) return 0;
    if (age > 4) return 1;
    return 2;
}

static void OpenApp(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    BOOL can = ws && [ws respondsToSelector:sel];
    AuxLog([NSString stringWithFormat:@"click -> open app, workspace=%d", can]);
    if (can) [ws performSelector:sel withObject:AUX_APP_ID];
}

// 全屏透明窗口：只有点到圆球/卡片才响应，其余地方穿透
@interface AuxPassWindow : UIWindow
@end
@implementation AuxPassWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface AuxFloatVC : UIViewController
@end

@implementation AuxFloatVC

- (UIButton *)makeButton:(NSString *)title frame:(CGRect)f tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    b.backgroundColor = [UIColor colorWithRed:0.20 green:0.72 blue:0.62 alpha:1];
    b.layer.cornerRadius = 10;
    b.tag = tag;
    [b addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)loadView {
    CGRect screen = UIScreen.mainScreen.bounds;
    UIView *root = [[UIView alloc] initWithFrame:screen];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;

    gHolder = [[UIView alloc] initWithFrame:CGRectMake(screen.size.width - AUX_BALL - 10, screen.size.height * 0.55, AUX_BALL, AUX_BALL)];
    gHolder.backgroundColor = [UIColor clearColor];
    [root addSubview:gHolder];

    gBall = [UIButton buttonWithType:UIButtonTypeSystem];
    gBall.frame = CGRectMake(0, 0, AUX_BALL, AUX_BALL);
    gBall.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    gBall.layer.cornerRadius = AUX_BALL / 2;
    gBall.layer.borderWidth = 1;
    gBall.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    [gBall setTitle:@"Aux" forState:UIControlStateNormal];
    [gBall setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    gBall.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gBall addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [gHolder addSubview:gBall];

    gDot = [[UIView alloc] initWithFrame:CGRectMake(AUX_BALL - 14, 4, 10, 10)];
    gDot.backgroundColor = [UIColor grayColor];
    gDot.layer.cornerRadius = 5;
    gDot.userInteractionEnabled = NO;
    [gHolder addSubview:gDot];

    gCard = [[UIView alloc] initWithFrame:CGRectMake(0, 0, AUX_CARD_W, AUX_CARD_H)];
    gCard.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    gCard.layer.cornerRadius = 16;
    gCard.layer.masksToBounds = YES;
    gCard.layer.borderWidth = 1;
    gCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    gCard.hidden = YES;
    [gHolder addSubview:gCard];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 60, 22)];
    title.text = @"AuxCam";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    [gCard addSubview:title];

    gStatus = [[UILabel alloc] initWithFrame:CGRectMake(72, 8, 100, 22)];
    gStatus.text = @"未开始";
    gStatus.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    gStatus.font = [UIFont systemFontOfSize:12];
    [gCard addSubview:gStatus];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(AUX_CARD_W - 44, 4, 40, 30);
    [close setTitle:@"收起" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1 alpha:0.8] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:12];
    [close addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [gCard addSubview:close];

    NSArray *titles = @[@"开始", @"镜像", @"旋转", @"恢复"];
    for (int i = 0; i < 4; i++) {
        CGFloat bx = 12 + (i % 2) * 94;
        CGFloat by = 38 + (i / 2) * 46;
        UIButton *b = [self makeButton:titles[i] frame:CGRectMake(bx, by, 88, 40) tag:i];
        if (i == 1) b.backgroundColor = [UIColor colorWithRed:0.35 green:0.55 blue:0.75 alpha:1];
        if (i == 2) b.backgroundColor = [UIColor colorWithRed:0.55 green:0.35 blue:0.75 alpha:1];
        if (i == 3) b.backgroundColor = [UIColor colorWithRed:0.90 green:0.55 blue:0.15 alpha:1];
        [gCard addSubview:b];
        if (i == 0) gStart = b;
    }

    UIButton *open = [self makeButton:@"打开 AuxCam" frame:CGRectMake(12, 132, 190, 36) tag:4];
    open.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    [gCard addSubview:open];

    // 拖动：只移动小方块 gHolder
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(move:)];
    pan.cancelsTouchesInView = NO;
    [gHolder addGestureRecognizer:pan];
}

- (void)toggle {
    BOOL expand = gCard.hidden;
    gCard.hidden = !expand;
    gBall.hidden = expand;
    gDot.hidden = expand;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect f = gHolder.frame;
    f.size = expand ? CGSizeMake(AUX_CARD_W, AUX_CARD_H) : CGSizeMake(AUX_BALL, AUX_BALL);
    if (f.origin.x + f.size.width > screen.size.width) f.origin.x = screen.size.width - f.size.width - 4;
    if (f.origin.y + f.size.height > screen.size.height) f.origin.y = screen.size.height - f.size.height - 4;
    gHolder.frame = f;
    AuxLog([NSString stringWithFormat:@"click -> %@", expand ? @"expand" : @"collapse"]);
}

- (void)tap:(UIButton *)b {
    switch (b.tag) {
        case 0: SendCmd(@"toggle"); break;
        case 1: SendCmd(@"mirror"); break;
        case 2: SendCmd(@"rotate"); break;
        case 3: SendCmd(@"reset"); break;
        case 4: OpenApp(); break;
        default: break;
    }
}

- (void)move:(UIPanGestureRecognizer *)pan {
    static CGPoint startOrigin;
    if (pan.state == UIGestureRecognizerStateBegan) {
        startOrigin = gHolder.frame.origin;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:self.view];
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect f = gHolder.frame;
        f.origin.x = MAX(0, MIN(startOrigin.x + t.x, screen.size.width - f.size.width));
        f.origin.y = MAX(20, MIN(startOrigin.y + t.y, screen.size.height - f.size.height));
        gHolder.frame = f;
    } else if (pan.state == UIGestureRecognizerStateEnded) {
        AuxLog(@"drag end");
    }
}

@end

static int gTries = 0;

static void AuxCreateWindow(void) {
    if (gWin) return;
    gTries++;
    UIWindowScene *scene = nil;
    NSMutableString *desc = [NSMutableString string];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        [desc appendFormat:@"%@;", NSStringFromClass(s.class)];
        if (!scene && [s isKindOfClass:UIWindowScene.class]) scene = (UIWindowScene *)s;
    }
    if (!scene && gTries < 10) {
        if (gTries == 1) AuxLog([NSString stringWithFormat:@"no UIWindowScene yet, scenes=[%@], will retry", desc]);
        return;
    }
    CGRect screen = UIScreen.mainScreen.bounds;
    gWin = scene ? [[AuxPassWindow alloc] initWithWindowScene:scene] : [[AuxPassWindow alloc] initWithFrame:screen];
    gWin.frame = screen;
    gWin.windowLevel = 10000000;
    gWin.backgroundColor = [UIColor clearColor];
    gWin.rootViewController = [AuxFloatVC new];
    [gWin.rootViewController view];
    SEL sec = NSSelectorFromString(@"_setSecure:");
    if ([gWin respondsToSelector:sec]) ((void (*)(id, SEL, BOOL))objc_msgSend)(gWin, sec, YES);
    gWin.hidden = YES;
    AuxLog([NSString stringWithFormat:@"window created scene=%d tries=%d scenes=[%@]", scene ? 1 : 0, gTries, desc]);
}

static void AuxTick(void) {
    AuxCreateWindow();
    if (!gWin) return;
    BOOL live = NO;
    NSString *ack = @"";
    int st = ReadState(&live, &ack);
    static int lastSt = -1;
    if (st != lastSt) {
        lastSt = st;
        AuxLog([NSString stringWithFormat:@"app state=%d (0=closed 1=sleeping 2=ok) -> window %@", st, st ? @"show" : @"hide"]);
    }
    gWin.hidden = (st == 0);
    if (st == 0) return;
    [gStart setTitle:live ? @"停止" : @"开始" forState:UIControlStateNormal];
    gStart.backgroundColor = live ? [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:1]
                                  : [UIColor colorWithRed:0.20 green:0.72 blue:0.62 alpha:1];
    if (st == 1) {
        gDot.backgroundColor = [UIColor orangeColor];
        gStatus.text = @"App休眠，点打开";
    } else {
        gDot.backgroundColor = live ? [UIColor greenColor] : [UIColor grayColor];
        gStatus.text = live ? @"推流中" : @"未开始";
    }
    static NSString *lastAck = nil;
    if (gLastCmdID && ack.length && [ack isEqualToString:gLastCmdID] && ![ack isEqualToString:lastAck]) {
        lastAck = ack;
        AuxLog([NSString stringWithFormat:@"App acked cmd id=%@", ack]);
    }
}

__attribute__((constructor)) static void AuxFloatInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AuxLog(@"AuxCamFloat loaded in SpringBoard");
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { AuxTick(); }];
    });
}
