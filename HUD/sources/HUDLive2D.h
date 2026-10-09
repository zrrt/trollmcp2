//
//  HUDLive2D.h — TrollAgent HUD 桌面悬浮 Live2D 接入（方案 A：dylib + dlopen）
//
#ifndef HUDLIVE2D_H
#define HUDLIVE2D_H

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface HUDLive2D : NSObject

// 单例
+ (instancetype)shared;

// dylib 是否已加载可用
- (BOOL)isAvailable;

// dlopen CubismDL.dylib（HUD.app 内）并取函数指针
- (BOOL)loadLibrary;

// 初始化 Cubism + 加载 Hiyori + 绑定渲染 layer + 启动渲染循环
- (BOOL)activateWithLayer:(CALayer*)layer width:(int)width height:(int)height;

// 播放动作 / 表情
- (void)playMotion:(NSString*)group no:(int)no priority:(int)pri;
- (void)setExpression:(NSString*)eid;

@end

#endif
