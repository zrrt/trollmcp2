//
//  CubismBridge.mm  —  TrollAgent HUD Live2D C 桥接实现
//
//  独立编成 CubismDL.dylib，HUD 主进程 dlopen 后通过 cubism_bridge.h 的 C 函数调用。
//  渲染流程复刻官方 ViewController renderToMetalLayer + LAppLive2DManager onUpdate。
//
#import "cubism_bridge.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "CubismFramework.hpp"
#import "LAppLive2DManager.h"
#import "LAppDefine.h"
#import "LAppPal.h"
#import "LAppAllocator.h"
#import "LAppModel.h"
#import "Math/CubismMatrix44.hpp"
#import "CubismDefaultParameterId.hpp"

using namespace Csm;

// ---- 静态上下文（dylib 内部单例）----
static LAppAllocator  s_allocator;
static LAppLive2DManager* g_mgr = NULL;
static id <MTLCommandQueue> g_queue = NULL;
static CAMetalLayer*   g_layer = NULL;
static id <MTLTexture> g_depth = NULL;
static CubismMatrix44* g_viewMatrix = NULL;
static int g_w = 0, g_h = 0;
static BOOL g_frameworkInit = NO;

// CADisplayLink 需要 ObjC target——用内部驱动类
@interface CubismRenderDriver : NSObject {
    CADisplayLink *_link;
}
@end
@implementation CubismRenderDriver
- (instancetype)init {
    self = [super init];
    return self;
}
- (void)start {
    if (_link) return;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _link.preferredFramesPerSecond = 30;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}
- (void)stop {
    [_link invalidate];
    _link = nil;
}
- (void)tick {
    @autoreleasepool { cb_render(); }
}
@end
static CubismRenderDriver* g_driver = NULL;

// 官方 renderToMetalLayer 的核心逻辑（去掉背景 sprite，透明清屏）
int cb_render(void)
{
    if (!g_layer || !g_mgr || !g_queue) return -1;
    LAppPal::UpdateTime();

    id <MTLCommandBuffer> commandBuffer = [g_queue commandBuffer];
    id<CAMetalDrawable> currentDrawable = [g_layer nextDrawable];
    if (!currentDrawable) return -2;

    MTLRenderPassDescriptor *rpd = [[MTLRenderPassDescriptor alloc] init];
    rpd.colorAttachments[0].texture = currentDrawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0); // 透明背景

    id <MTLRenderCommandEncoder> enc = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc endEncoding];

    [g_mgr SetViewMatrix:g_viewMatrix];
    [g_mgr onUpdate:commandBuffer currentDrawable:currentDrawable depthTexture:g_depth];

    [commandBuffer presentDrawable:currentDrawable];
    [commandBuffer commit];
    return 0;
}

int cb_init(const char* resourcesPath)
{
    if (g_frameworkInit) return 0;
    // 1) 模型资源根（绝对路径，含结尾 /）
    if (resourcesPath) {
        std::string rp = resourcesPath;
        if (!rp.empty() && rp.back() != '/') rp += "/";
        LAppDefine::ResourcesPath = (csmChar*)strdup(rp.c_str());
    }
    // 2) Cubism Framework 初始化（官方 AppDelegate.mm:50-52）
    CubismFramework::Option opt;
    memset(&opt, 0, sizeof(opt));
    opt.LogFunction = LAppPal::PrintMessageLn;
    opt.LoggingLevel = CubismFramework::Option::LogLevel_Verbose;
    CubismFramework::StartUp(&s_allocator, &opt);
    CubismFramework::Initialize();
    g_frameworkInit = YES;
    // 3) 渲染管理器 + view 矩阵
    g_mgr = [LAppLive2DManager getInstance];
    g_viewMatrix = new CubismMatrix44();
    return 0;
}

int cb_load_model(const char* dir, const char* file)
{
    if (!g_mgr || !dir || !file) return -1;
    g_mgr.viewWidth  = g_w;
    g_mgr.viewHeight = g_h;
    g_mgr.device = g_layer ? [g_layer device] : nil;
    [g_mgr setUpModel];
    // 只加载指定模型（changeScene(0) 会按 modelDir[0] 加载；这里直接取 0 号）
    [g_mgr changeScene:0];
    // 让第一个模型 LoadAssets 到指定 dir/file（若 changeScene 未正确取 dir，显式补设）
    LAppModel* m = [g_mgr getModel:0];
    if (m) {
        m->LoadAssets(dir, file);
        [g_mgr releaseAllModel];
        [g_mgr setUpModel];
        [g_mgr changeScene:0];
    }
    return 0;
}

int cb_attach_layer(void* cametalLayer, int width, int height)
{
    g_layer = (CAMetalLayer*)cametalLayer;
    g_w = width; g_h = height;
    if (!g_layer) return -1;

    id <MTLDevice> device = [g_layer device];
    if (!device) return -2;
    g_queue = [device newCommandQueue];

    // depth 纹理
    MTLTextureDescriptor* dtd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                   width:width height:height mipmapped:false];
    dtd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    dtd.storageMode = MTLStorageModePrivate;
    g_depth = [device newTextureWithDescriptor:dtd];

    if (g_mgr) { g_mgr.viewWidth = width; g_mgr.viewHeight = height; g_mgr.device = device; }
    return 0;
}

int cb_start_render_loop(void)
{
    if (!g_driver) g_driver = [[CubismRenderDriver alloc] init];
    [g_driver start];
    return 0;
}

int cb_stop_render_loop(void)
{
    [g_driver stop];
    return 0;
}

int cb_start_motion(const char* group, int no, int priority)
{
    if (!g_mgr) return -1;
    LAppModel* m = [g_mgr getModel:0];
    if (!m) return -2;
    m->StartMotion(group, no, priority);
    return 0;
}

int cb_set_expression(const char* expressionID)
{
    if (!g_mgr) return -1;
    LAppModel* m = [g_mgr getModel:0];
    if (!m) return -2;
    m->SetExpression(expressionID);
    return 0;
}

int cb_shutdown(void)
{
    [g_driver stop];
    [LAppLive2DManager releaseInstance];
    CubismFramework::Dispose();
    g_frameworkInit = NO;
    return 0;
}
