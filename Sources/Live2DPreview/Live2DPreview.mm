//
//  Live2DPreview.mm — 主 App Live2D 预览实现（诊断用）
//
//  与 HUD/HUDLive2D.mm 同机制：dlopen CubismDL.dylib → dlsym cb_* →
//  cb_init(cb_load_model) → 绑定 CAMetalLayer 渲染 → 渲染循环。
//  但主 App 是正常前台 UIApplication，MTLCreateSystemDefaultDevice 能拿到 GPU——
//  用于验证 Cubism+Hiyori 渲染链路本身是否可行。
//
#import "Live2DPreview.h"
#import <dlfcn.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

// 与 HUD/cubism/Bridge/cubism_bridge.h 对齐的 C 接口（不链接 dylib，运行时 dlsym）
typedef int (*cb_init_fn)(const char*);
typedef int (*cb_load_model_fn)(const char*, const char*);
typedef int (*cb_attach_layer_fn)(void*, int, int);
typedef int (*cb_start_render_loop_fn)(void);
typedef int (*cb_stop_render_loop_fn)(void);
typedef int (*cb_start_motion_fn)(const char*, int, int);
typedef int (*cb_shutdown_fn)(void);

@interface Live2DPreview () {
    void *_dl;
    cb_init_fn           _cb_init;
    cb_load_model_fn     _cb_load_model;
    cb_attach_layer_fn   _cb_attach_layer;
    cb_start_render_loop_fn _cb_start_render_loop;
    cb_stop_render_loop_fn  _cb_stop_render_loop;
    cb_start_motion_fn   _cb_start_motion;
    cb_shutdown_fn       _cb_shutdown;
    NSString *_resPath;   // Cubism 资源根目录（含结尾 /），Hiyori 在此下
}
@end

@implementation Live2DPreview

@synthesize lastError = _lastError;

- (instancetype)init {
    self = [super init];
    return self;
}

- (void)setError:(NSString*)fmt, ... {
    va_list args; va_start(args, fmt);
    _lastError = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
}

// 诊断日志写 /tmp/live2d_preview.log（覆盖式，8790 shell 可读）
- (void)logLine:(NSString*)fmt, ... {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    [line writeToFile:@"/tmp/live2d_preview.log" atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

/// 主 App bundle 内的 HUD.app 路径：<bundle>/hud/TrollAgentHUD.app
- (NSString*)hudAppPath {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"hud/TrollAgentHUD.app"];
}

- (BOOL)prepare {
    if (_dl) return YES;
    [self logLine:@"prepare begin, dylib=%@", [[self hudAppPath] stringByAppendingPathComponent:@"CubismDL.dylib"]];
    NSString *dylibPath = [[self hudAppPath] stringByAppendingPathComponent:@"CubismDL.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:dylibPath]) {
        [self setError:@"CubismDL.dylib 不在 HUD.app 内: %@", dylibPath];
        [self logLine:@"prepare FAIL: dylib missing"];
        return NO;
    }
    _dl = dlopen(dylibPath.UTF8String, RTLD_NOW);
    [self logLine:@"dlopen %@", _dl ? @"OK" : [NSString stringWithUTF8String:dlerror()]];
    if (!_dl) {
        [self setError:@"dlopen 失败: %s", dlerror()];
        return NO;
    }
    _cb_init               = (cb_init_fn)dlsym(_dl, "cb_init");
    _cb_load_model         = (cb_load_model_fn)dlsym(_dl, "cb_load_model");
    _cb_attach_layer       = (cb_attach_layer_fn)dlsym(_dl, "cb_attach_layer");
    _cb_start_render_loop  = (cb_start_render_loop_fn)dlsym(_dl, "cb_start_render_loop");
    _cb_stop_render_loop   = (cb_stop_render_loop_fn)dlsym(_dl, "cb_stop_render_loop");
    _cb_start_motion       = (cb_start_motion_fn)dlsym(_dl, "cb_start_motion");
    _cb_shutdown           = (cb_shutdown_fn)dlsym(_dl, "cb_shutdown");
    if (!_cb_init || !_cb_load_model || !_cb_attach_layer) {
        [self setError:@"dlsym cb_* 缺失（dylib 版本不符）"];
        [self logLine:@"prepare FAIL: dlsym cb_* missing"];
        return NO;
    }
    _resPath = [[self hudAppPath] stringByAppendingString:@"/"];
    [self logLine:@"prepare OK, res=%@", _resPath];
    return YES;
}

- (BOOL)startInView:(UIView*)view {
    if (!_dl) return NO;
    [self logLine:@"startInView begin (thread=%@)", NSThread.isMainThread ? @"main" : @"bg"];
    // 用 CAMetalLayer 作为 view 的底层 layer
    CAMetalLayer *ml = (CAMetalLayer*)view.layer;
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) {
        // 主 App 正常前台，应能拿到 GPU
        if (!ml.device) ml.device = MTLCreateSystemDefaultDevice();
        [self logLine:@"MTLCreateSystemDefaultDevice %@", ml.device ? @"OK" : @"nil"];
        if (!ml.device) {
            [self setError:@"MTLCreateSystemDefaultDevice 返回 nil（主 App 无 GPU？）"];
            return NO;
        }
        CGFloat scale = UIScreen.mainScreen.scale;
        CGFloat w = CGRectGetWidth(view.bounds), h = CGRectGetHeight(view.bounds);
        ml.drawableSize = CGSizeMake(w * scale, h * scale);
        ml.opaque = NO;
        ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ml.framebufferOnly = YES;
        // 桥接层需要 device 传入（cb_attach_layer 内部用 layer.device）
    } else {
        [self setError:@"view.layer 不是 CAMetalLayer（宿主 layerClass 未配置）"];
        return NO;
    }
    [self logLine:@"cb_init call res=%@", _resPath];
    if (_cb_init(_resPath.UTF8String) != 0) {
        [self setError:@"cb_init 失败 (res=%@)", _resPath];
        [self logLine:@"cb_init FAILED"];
        return NO;
    }
    int w = (int)CGRectGetWidth(view.bounds), h = (int)CGRectGetHeight(view.bounds);
    [self logLine:@"cb_attach_layer call (%dx%d)", w, h];
    if (_cb_attach_layer((__bridge void*)ml, w, h) != 0) {
        [self setError:@"cb_attach_layer 失败 (%dx%d)", w, h];
        [self logLine:@"cb_attach_layer FAILED"];
        return NO;
    }
    [self logLine:@"cb_load_model call Hiyori"];
    if (_cb_load_model("Hiyori", "Hiyori.model3.json") != 0) {
        [self setError:@"cb_load_model 失败（Hiyori 资源/模型问题）"];
        [self logLine:@"cb_load_model FAILED"];
        return NO;
    }
    if (_cb_start_render_loop) _cb_start_render_loop();
    [self logLine:@"startInView OK (render loop started)"];
    return YES;
}

- (BOOL)playMotion:(NSString*)group no:(int)no priority:(int)pri {
    if (_cb_start_motion) return _cb_start_motion(group.UTF8String, no, pri) == 0;
    return NO;
}

- (void)stop {
    if (_cb_stop_render_loop) _cb_stop_render_loop();
    if (_cb_shutdown) _cb_shutdown();
    if (_dl) { dlclose(_dl); _dl = NULL; }
}

- (void)dealloc {
    [self stop];
}

@end

@implementation L2DHostView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

@end
