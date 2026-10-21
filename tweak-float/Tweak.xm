// AuxCamFloat —— 系统级悬浮小窗（注入 SpringBoard，所以在任何界面都能看到）
// 平时是小圆球；点一下展开小卡片：开始/停止 + 镜像 + 旋转 + 恢复 + 打开 App。
// 和 AuxCam App 的通信（都走 /var/mobile/Media/DCIM）：
//   .auxcam-float.state  App 每秒写一次（visible/live/ts）；超过 4 秒没更新 = App 没开 -> 小窗自动隐藏
//   .auxcam-float.cmd    小窗写指令（cmd/id/ts），App 每秒读一次并执行
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define AUX_BALL 46.0
#define AUX_CARD_W 214.0
#define AUX_CARD_H 178.0
#define AUX_APP_ID @"com.auxcam.app"

static NSString *const kStatePath = @"/var/mobile/Media/DCIM/.auxcam-float.state";
static NSString *const kCmdPath = @"/var/mobile/Media/DCIM/.auxcam-float.cmd";

static UIWindow *gWin = nil;
static UIButton *gStart = nil;
static UIView *gDot = nil;
static UILabel *gStatus = nil;
static UIView *gCard = nil;
static UIButton *gBall = nil;
static int gCmdSeq = 0;

static void SendCmd(NSString *cmd) {
    gCmdSeq++;
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    NSString *t = [NSString stringWithFormat:@"cmd=%@\nid=%lld-%d\nts=%lld\n", cmd, now, gCmdSeq, now];
    [t writeToFile:kCmdPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// 读 App 写的状态：返回 App 是否还活着，live 是否在推
static BOOL ReadState(BOOL *live) {
    NSString *t = [NSString stringWithContentsOfFile:kStatePath encoding:NSUTF8StringEncoding error:nil];
    if (!t) return NO;
    long long ts = 0;
    BOOL l = NO;
    for (NSString *line in [t componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"ts="]) ts = [[line substringFromIndex:3] longLongValue];
        if ([line hasPrefix:@"live="]) l = [[line substringFromIndex:5] intValue] == 1;
    }
    if (live) *live = l;
    long long now = (long long)[[NSDate date] timeIntervalSince1970];
    return (now - ts) <= 4;
}

static void OpenApp(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [cls performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (ws && [ws respondsToSelector:sel]) {
        [ws performSelector:sel withObject:AUX_APP_ID];
    }
}

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
    UIView *root = [[UIView alloc] initWithFrame:CGRectMake(0, 0, AUX_BALL, AUX_BALL)];
    root.backgroundColor = [UIColor clearColor];
    self.view = root;

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
    [root addSubview:gBall];

    gDot = [[UIView alloc] initWithFrame:CGRectMake(AUX_BALL - 14, 4, 10, 10)];
    gDot.backgroundColor = [UIColor grayColor];
    gDot.layer.cornerRadius = 5;
    gDot.userInteractionEnabled = NO;
    [root addSubview:gDot];

    gCard = [[UIView alloc] initWithFrame:CGRectMake(0, 0, AUX_CARD_W, AUX_CARD_H)];
    gCard.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
    gCard.layer.cornerRadius = 16;
    gCard.layer.masksToBounds = YES;
    gCard.layer.borderWidth = 1;
    gCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    gCard.hidden = YES;
    [root addSubview:gCard];

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

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(move:)];
    [root addGestureRecognizer:pan];

    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        BOOL live = NO;
        BOOL alive = ReadState(&live);
        gWin.hidden = !alive;          // App 没开就整个藏起来
        if (!alive) return;
        [gStart setTitle:live ? @"停止" : @"开始" forState:UIControlStateNormal];
        gStart.backgroundColor = live ? [UIColor colorWithRed:0.85 green:0.25 blue:0.22 alpha:1]
                                      : [UIColor colorWithRed:0.20 green:0.72 blue:0.62 alpha:1];
        gDot.backgroundColor = live ? [UIColor greenColor] : [UIColor grayColor];
        gStatus.text = live ? @"推流中" : @"未开始";
    }];
}

- (void)toggle {
    BOOL expand = gCard.hidden;
    gCard.hidden = !expand;
    gBall.hidden = expand;
    gDot.hidden = expand;
    CGRect f = gWin.frame;
    CGFloat sw = UIScreen.mainScreen.bounds.size.width;
    CGFloat sh = UIScreen.mainScreen.bounds.size.height;
    f.size = expand ? CGSizeMake(AUX_CARD_W, AUX_CARD_H) : CGSizeMake(AUX_BALL, AUX_BALL);
    if (f.origin.x + f.size.width > sw) f.origin.x = sw - f.size.width - 4;
    if (f.origin.y + f.size.height > sh) f.origin.y = sh - f.size.height - 4;
    gWin.frame = f;
    self.view.frame = CGRectMake(0, 0, f.size.width, f.size.height);
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
    static CGPoint off = {0, 0};
    if (pan.state == UIGestureRecognizerStateBegan) {
        off = [pan locationInView:gWin];
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [pan locationInView:nil];
        CGRect f = gWin.frame;
        f.origin.x = p.x - off.x;
        f.origin.y = p.y - off.y;
        gWin.frame = f;
    }
}

@end

static void AuxCreateWindow(void) {
    if (gWin) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    }
    CGFloat sw = UIScreen.mainScreen.bounds.size.width;
    CGFloat sh = UIScreen.mainScreen.bounds.size.height;
    CGRect f = CGRectMake(sw - AUX_BALL - 10, sh * 0.55, AUX_BALL, AUX_BALL);
    gWin = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:f];
    gWin.frame = f;
    gWin.windowLevel = 10000000;
    gWin.backgroundColor = [UIColor clearColor];
    gWin.rootViewController = [AuxFloatVC new];
    gWin.hidden = YES;     // 等 App 状态文件出现再显示
}

__attribute__((constructor)) static void AuxFloatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AuxCreateWindow();
    });
}
