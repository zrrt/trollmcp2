//
//  cubism_bridge.h  —  TrollAgent HUD Live2D C 桥接接口
//
//  HUD 主进程（不含 Cubism）dlopen CubismDL.dylib 后通过这些 C 函数调用，
//  把 CubismFramework 初始化/模型加载/Metal 渲染隔离在独立 dylib 里，
//  避免编入 HUD 主二进制导致 __completeAndRunAsPlugin 启动崩溃。
//
#ifndef CUBISM_BRIDGE_H
#define CUBISM_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// 初始化 CubismFramework（StartUp + Initialize）。resourcesPath 为模型资源根目录绝对路径（含结尾 /）。
int cb_init(const char* resourcesPath);

// 加载模型。dir 相对 resourcesPath，如 "Hiyori"；file 形如 "Hiyori.model3.json"。
int cb_load_model(const char* dir, const char* file);

// 绑定渲染目标：cametalLayer 是 HUD 传入的 CAMetalLayer*；width/height 为逻辑像素尺寸。
int cb_attach_layer(void* cametalLayer, int width, int height);

// 手动渲染一帧（HUD 驱动时用）。CADisplayLink 自动驱动时可不调。
int cb_render(void);

// 开始自动渲染循环（CADisplayLink 驱动）。
int cb_start_render_loop(void);

// 停止渲染循环。
int cb_stop_render_loop(void);

// 播放动作。group="Idle"/"TapBody" 等，no=动作序号，pri=优先级(0 低/1 中/2 高)。
int cb_start_motion(const char* group, int no, int priority);

// 设置表情。
int cb_set_expression(const char* expressionID);

// 销毁资源（模型/渲染/框架）。
int cb_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* CUBISM_BRIDGE_H */
