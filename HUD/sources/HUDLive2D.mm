//
//  HUDLive2D.mm — TrollAgent HUD 桌面悬浮 Live2D 接入
//
//  方案 A：Cubism 编成独立 CubismDL.dylib（隔离 __completeAndRunAsPlugin 崩溃）。
//  HUD 主进程窗口建立后（viewDidLoad 之后）dlopen 该 dylib，建 CAMetalLayer 渲染 Hiyori。
//  dylib 编译失败/缺失时静默降级：HUD 继续用原有 PNG 帧（_girlView），不影响悬浮窗。
//
#import "HUDLive2D.h"
#import <dlfcn.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

// 与 HUD/cubism/Bridge/cubism_bridge.h 对齐的 C 接口（HUD 侧只声明，不链接 dylib 符号——运行时 dlsym）
typedef int (*cb_init_fn)(const char*);
typedef int (*cb_load_model_fn)(const char*, const char*);
typedef int (*cb_attach_layer_fn)(void*, int, int);
typedef int (*cb_render_fn)(void);
typedef int (*cb_start_render_loop_fn)(void);
typedef int (*cb_stop_render_loop_fn)(void);
typedef int (*cb_start_motion_fn)(const char*, int, int);
typedef int (*cb_set_expression_fn)(const char*);
typedef int (*cb_shutdown_fn)(void);

@interface HUDLive2D () {
    void *_dl;
    cb_init_fn           _cb_init;
    cb_load_model_fn     _cb_load_model;
    cb_attach_layer_fn   _cb_attach_layer;
    cb_start_render_loop_fn _cb_start_render_loop;
    cb_start_motion_fn   _cb_start_motion;
    cb_set_expression_fn _cb_set_expression;
}
@end

@implementation HUDLive2D

+ (instancetype)shared {
    static HUDLive2D *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[HUDLive2D alloc] init]; });
    return s;
}

- (BOOL)isAvailable {
    return _dl != NULL;
}

// dlopen CubismDL.dylib（在 HUD.app 内）并取函数指针
- (BOOL)loadLibrary {
    if (_dl) return YES;
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *dylibPath = [bundleDir stringByAppendingPathComponent:@"CubismDL.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
        [self _log:@"[HUDLive2D] CubismDL.dylib missing, fallback to PNG"];
        return NO;
    }
    _dl = dlopen([dylibPath UTF8String], RTLD_NOW);
    if (!_dl) {
        [self _log:@"[HUDLive2D] dlopen failed: %s", dlerror()];
        return NO;
    }
    _cb_init             = (cb_init_fn)dlsym(_dl, "cb_init");
    _cb_load_model       = (cb_load_model_fn)dlsym(_dl, "cb_load_model");
    _cb_attach_layer     = (cb_attach_layer_fn)dlsym(_dl, "cb_attach_layer");
    _cb_start_render_loop= (cb_start_render_loop_fn)dlsym(_dl, "cb_start_render_loop");
    _cb_start_motion     = (cb_start_motion_fn)dlsym(_dl, "cb_start_motion");
    _cb_set_expression   = (cb_set_expression_fn)dlsym(_dl, "cb_set_expression");
    [self _log:@"[HUDLive2D] dlopen OK: %@", dylibPath];
    return YES;
}

// 初始化 Cubism + 加载 Hiyori + 绑定渲染 layer + 启动渲染循环。
// 返回 YES 表示 Live2D 渲染激活（调用方应隐藏 PNG _girlView）。
- (BOOL)activateWithLayer:(CALayer*)layer width:(int)width height:(int)height {
    if (!_dl) return NO;
    // CAMetalLayer 需要 device + drawableSize 才能 nextDrawable
    if ([layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *ml = (CAMetalLayer*)layer;
        if (!ml.device) ml.device = MTLCreateSystemDefaultDevice();
        [self _log:@"[HUDLive2D] CAMetalLayer device %@ (isKind MetalLayerHost=%d)", ml.device, [layer isKindOfClass:[CAMetalLayer class]]];
        // [TrollAgent diag] 独立文件记录 device 诊断（不被 cb_attach failed 覆盖）：root 提权进程 MTLCreateSystemDefaultDevice 可能返回 nil
        {
            id<MTLDevice> d0 = ml.device;
            id<MTLDevice> d1 = nil;
            if (!d0) { d1 = MTLCreateSystemDefaultDevice(); }
            NSString *diag = [NSString stringWithFormat:
                @"metalHost.layer=%@ isCAMetal=%d ml.device=%p mtlCreate=%p (ml.device==mtlCreate->same=%d)\n",
                layer, [layer isKindOfClass:[CAMetalLayer class]], ml.device, d0?d0:d1, (d0&&d0==(d1?d1:d0))];
            [diag writeToFile:@"/var/mobile/Library/Caches/hudl2d_diag.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        CGFloat scale = [UIScreen mainScreen].scale;
        ml.drawableSize = CGSizeMake((CGFloat)width * scale, (CGFloat)height * scale);
        ml.opaque = NO;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
    }
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *resPath = [bundleDir stringByAppendingString:@"/"];
    if (_cb_init && _cb_init(resPath.UTF8String) == 0) {
        [self _log:@"[HUDLive2D] cb_init OK (res=%@)", resPath];
    } else {
        [self _log:@"[HUDLive2D] cb_init failed"];
        return NO;
    }
    // [TrollAgent fix] 必须先 attach（设 g_layer/g_w/g_h/device），再 load_model——
    // cb_load_model 里 LAppModel LoadAssets 需要 g_mgr.device（来自 layer），顺序反了会因 device nil 崩。
    if (_cb_attach_layer && _cb_attach_layer((__bridge void*)layer, width, height) == 0) {
        [self _log:@"[HUDLive2D] cb_attach_layer OK (%d x %d)", width, height];
    } else {
        [self _log:@"[HUDLive2D] cb_attach_layer failed"];
        {
            NSString *errDiag = [NSString stringWithFormat:@"cb_attach FAILED: ml.device=%p layerClass=%@ isCAM=%d width=%d height=%d",
                ml.device, NSStringFromClass([layer class]), [layer isKindOfClass:[CAMetalLayer class]], width, height];
            [errDiag writeToFile:@"/var/mobile/Library/Caches/hudl2d_diag.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return NO;
    }
    // Hiyori 模型目录在 bundle/Hiyori/Hiyori.model3.json
    if (_cb_load_model && _cb_load_model("Hiyori", "Hiyori.model3.json") == 0) {
        [self _log:@"[HUDLive2D] cb_load_model OK"];
    } else {
        [self _log:@"[HUDLive2D] cb_load_model failed"];
        return NO;
    }
    if (_cb_start_render_loop) _cb_start_render_loop();
    [self _log:@"[HUDLive2D] render loop started"];
    return YES;
}

// 播放动作（group: Idle/TapBody 等）
- (void)playMotion:(NSString*)group no:(int)no priority:(int)pri {
    if (_cb_start_motion) _cb_start_motion(group.UTF8String, no, pri);
}
- (void)setExpression:(NSString*)eid {
    if (_cb_set_expression) _cb_set_expression(eid.UTF8String);
}

- (void)_log:(NSString*)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // [TrollAgent fix] NSFileHandle 追加在 completeAndRunAsPlugin 后被沙盒掐断（hudapp.log 只留 HUDApp 首行），
    // 改用 writeToFile atomically 覆盖（与 HUDApp 相同，验证可写），写独立状态文件 hudl2d.log —— 读最后一行即可定位激活到哪一步。
    [msg writeToFile:@"/var/mobile/Library/Caches/hudl2d_step.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@end
