//
//  HUDRootViewController.mm
//  TrollAgent
//
//  悬浮窗内容：粉色萝莉塔小女孩（多帧动画 + 可拖动 + 点击换表情）
//  最小替代实现，替换 TrollSpeed 自带按钮球 UI。
//

#import "HUDRootViewController.h"
#import "HUDMainWindow.h"
#import <string.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>

// v6.0.7：SpringBoardServices 是私有 framework（Xcode SDK 无头文件），直接 extern 声明原型，
// 符号由 HUD/libraries/SpringBoardServices.framework/SpringBoardServices.tbd 链接提供（Makefile PRIVATE_FRAMEWORKS 已含）
extern mach_port_t SBSSpringBoardServerPort(void);
extern void SBGetScreenLockStatus(mach_port_t port, BOOL *isLocked, BOOL *isPasscodeSet);

// v6.0.7：锁屏保活（抄 TrollSpeed HUDRootViewController）——监听 springboard.lockstate，
// 锁屏时隐藏悬浮、解锁时恢复显示（进程本身是 posix_spawn 无沙盒 root 通常不被杀，窗口需锁屏隐藏/解锁恢复）
#define NOTIFY_UI_LOCKSTATE "com.apple.springboard.lockstate"

static BOOL _passthrough = NO;

@interface HUDRootViewController ()
- (void)lockHide;
- (void)unlockShow;
- (void)registerNotifications;
@end

// 锁屏状态回调（TrollSpeed 正解）：锁屏隐藏悬浮视图，解锁恢复显示
static void SpringBoardLockStatusChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    HUDRootViewController *vc = (__bridge HUDRootViewController *)observer;
    NSString *lockState = (__bridge NSString *)name;
    if ([lockState isEqualToString:@NOTIFY_UI_LOCKSTATE]) {
        mach_port_t sbsPort = SBSSpringBoardServerPort();
        if (sbsPort == MACH_PORT_NULL) return;
        BOOL isLocked = NO, isPasscodeSet = NO;
        SBGetScreenLockStatus(sbsPort, &isLocked, &isPasscodeSet);
        if (!isLocked) [vc unlockShow];
        else [vc lockHide];
    }
}

// v6.0.7：悬浮小女孩显示尺寸（pt），由主 App 启动时 -size N 传入（HUDMain.mm 解析），默认 150
extern "C" double g_hud_size;
// v6.0.7：悬浮角色（girl=小萝莉 / rabit=御姐兔女郎），由主 App 启动时 -char 传入（HUDMain.mm 解析）
extern "C" const char *g_hud_char;

@implementation HUDRootViewController {
    UIImageView *_girlView;
    NSArray<UIImage *> *_idleFrames;
    NSArray<UIImage *> *_happyFrames;
    NSArray<UIImage *> *_thinkFrames;
    BOOL _isDragging;
    CGPoint _dragOffset;
    int _emojiTimer;      // 点击表情显示计时
}

+ (BOOL)passthroughMode { return _passthrough; }
+ (void)setPassthroughMode:(BOOL)enabled { _passthrough = enabled; }

- (instancetype)init {
    if (self = [super init]) {
        // v6.0.7：按当前角色加载多帧图（girl_小萝莉 / rabit_御姐兔女郎，HUD bundle 内）
        BOOL isRabbit = (g_hud_char && strcmp(g_hud_char, "rabit") == 0);
        NSString *prefix = isRabbit ? @"rabit" : @"girl";
        UIImage *idle  = [UIImage imageNamed:[NSString stringWithFormat:@"%@_idle", prefix]];
        UIImage *happy = [UIImage imageNamed:[NSString stringWithFormat:@"%@_happy", prefix]];
        UIImage *think = [UIImage imageNamed:[NSString stringWithFormat:@"%@_think", prefix]];
        UIImage *talk  = [UIImage imageNamed:[NSString stringWithFormat:@"%@_talk", prefix]];
        if (idle)  _idleFrames  = @[idle];
        if (happy) _happyFrames = @[happy];
        if (think) _thinkFrames = @[think];
        if (talk)  _thinkFrames = @[talk];   // 说话帧暂并入 think 备用
        if (!idle) {
            // 兜底：纯色圆（资源缺失时仍可见）
            _idleFrames = @[ [self _placeholderCircle] ];
        }
    }
    return self;
}

- (UIImage *)_placeholderCircle {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(120, 120), NO, 0);
    [[UIColor systemPinkColor] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 120, 120)] fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    _girlView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _girlView.image = _idleFrames.firstObject;
    _girlView.contentMode = UIViewContentModeScaleAspectFit;
    _girlView.userInteractionEnabled = YES;
    [self.view addSubview:_girlView];

    CGFloat size = (CGFloat)g_hud_size;   // 悬浮小女孩显示尺寸（v6.0.7 可调，默认 150）
    _girlView.frame = CGRectMake((self.view.bounds.size.width - size)/2,
                                 (self.view.bounds.size.height - size)/2,
                                 size, size);

    // v6.0.7：注册锁屏/解锁监听（锁屏隐藏悬浮、解锁恢复，抄 TrollSpeed）
    [self registerNotifications];

    // 呼吸动画（idle 缩放循环）
    [self _startBreathing];

    // 拖动 + 点击
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_pan:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tap:)];
    [_girlView addGestureRecognizer:pan];
    [_girlView addGestureRecognizer:tap];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 窗口全屏，内容透明
    self.view.frame = [UIScreen mainScreen].bounds;
}

// v6.0.7：上下漂浮动画（原来呼吸缩放改成上下飘——用户要求对齐 app 里的漂浮效果）
- (void)_startBreathing {
    [_girlView.layer removeAllAnimations];   // 防重复调用叠加动画
    [UIView animateWithDuration:2.6 delay:0 options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat | UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_girlView.transform = CGAffineTransformMakeTranslation(0, -14);
    } completion:nil];
}

// v6.0.7：注册 springboard 锁屏状态监听（抄 TrollSpeed HUDRootViewController）
- (void)registerNotifications {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, (__bridge const void *)self, SpringBoardLockStatusChanged, CFSTR(NOTIFY_UI_LOCKSTATE), NULL, CFNotificationSuspensionBehaviorCoalesce);
}

// 锁屏：隐藏悬浮 + 停止动画
- (void)lockHide {
    _girlView.hidden = YES;
    [_girlView.layer removeAllAnimations];
}

// 解锁：恢复显示 + 重启动画
- (void)unlockShow {
    _girlView.hidden = NO;
    [self _startBreathing];
}

// 拖动悬浮小女孩
- (void)_pan:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    if (g.state == UIGestureRecognizerStateBegan) {
        _isDragging = YES;
        _dragOffset = CGPointMake(p.x - _girlView.center.x, p.y - _girlView.center.y);
    } else if (g.state == UIGestureRecognizerStateChanged && _isDragging) {
        CGPoint c = CGPointMake(p.x - _dragOffset.x, p.y - _dragOffset.y);
        CGSize v = self.view.bounds.size;
        // v6.0.7 修复：边界用显示尺寸（frame.size）而非图片固有尺寸（bounds 是 600×900）——
        // 旧代码用 bounds 导致角色拖不到屏幕边缘。改用 frame 后角色可紧贴屏幕边。
        CGSize gs = _girlView.frame.size;
        c.x = MAX(gs.width/2, MIN(c.x, v.width - gs.width/2));
        c.y = MAX(gs.height/2, MIN(c.y, v.height - gs.height/2));
        _girlView.center = c;
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _isDragging = NO;
    }
}

// 点击切表情：开心→思考→待机
- (void)_tap:(UITapGestureRecognizer *)g {
    if (_isDragging) return;
    static int seq = 0;
    if (seq == 0) _girlView.image = _happyFrames.firstObject ?: _idleFrames.firstObject;
    else if (seq == 1) _girlView.image = _thinkFrames.firstObject ?: _idleFrames.firstObject;
    else _girlView.image = _idleFrames.firstObject;
    seq = (seq + 1) % 3;
    _emojiTimer = 2;   // 约 1.6s 后回待机
    [self _resetAfterEmoji];
}

- (void)_resetAfterEmoji {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_isDragging) {
            self->_girlView.image = self->_idleFrames.firstObject;
        }
    });
}

@end
