//
//  Live2DPreview.h — TrollAgent 主 App Live2D 预览（诊断用）
//
//  主 App 在正常 GPU 环境下 dlopen HUD.app 内的 CubismDL.dylib，渲染 Hiyori。
//  用于定位：Cubism + Hiyori 资源渲染链路在主 App 能否跑通（HUD root 进程拿不到 GPU）。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface Live2DPreview : NSObject

/// 准备：找到 CubismDL.dylib（主 App bundle 内 hud/TrollAgentHUD.app/）
- (BOOL)prepare;

/// 在给定 UIView（将作为 CAMetalLayer 宿主）上开始渲染 Hiyori。返回 YES 表示渲染激活。
- (BOOL)startInView:(UIView*)view;

/// 播放动作（group: Idle / TapBody 等，no=序号，priority=优先级）
- (BOOL)playMotion:(NSString*)group no:(int)no priority:(int)pri;

/// 停止渲染并释放资源
- (void)stop;

/// 最近错误描述（供 UI 展示）
@property(nonatomic, strong, readonly, nullable) NSString* lastError;

@end

/// 预览宿主视图：layer 为 CAMetalLayer，供 SwiftUI 预览页使用
@interface L2DHostView : UIView
@end

NS_ASSUME_NONNULL_END
