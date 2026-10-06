//
//  HUDRootViewController.mm
//  TrollAgent
//
//  悬浮窗内容：粉色萝莉塔小女孩（多帧动画 + 可拖动 + 点击换表情）
//  最小替代实现，替换 TrollSpeed 自带按钮球 UI。
//

#import "HUDRootViewController.h"
#import "HUDMainWindow.h"

static BOOL _passthrough = NO;

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
        // 加载小女孩多帧图（HUD bundle 内的 girl_*.png）
        UIImage *idle  = [UIImage imageNamed:@"girl_idle"];
        UIImage *happy = [UIImage imageNamed:@"girl_happy"];
        UIImage *think = [UIImage imageNamed:@"girl_think"];
        UIImage *talk  = [UIImage imageNamed:@"girl_talk"];
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

    CGFloat size = 150.0;   // 悬浮小女孩显示尺寸
    _girlView.frame = CGRectMake((self.view.bounds.size.width - size)/2,
                                 (self.view.bounds.size.height - size)/2,
                                 size, size);

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

- (void)_startBreathing {
    [UIView animateWithDuration:2.4 delay:0 options:UIViewAnimationOptionAutoreverse | UIViewAnimationOptionRepeat | UIViewAnimationOptionCurveEaseInOut animations:^{
        self->_girlView.transform = CGAffineTransformMakeScale(1.03, 1.03);
    } completion:nil];
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
        c.x = MAX(_girlView.bounds.size.width/2, MIN(c.x, v.width - _girlView.bounds.size.width/2));
        c.y = MAX(_girlView.bounds.size.height/2, MIN(c.y, v.height - _girlView.bounds.size.height/2));
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
