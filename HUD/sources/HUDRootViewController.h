//
//  HUDRootViewController.h
//  TrollAgent
//
//  悬浮窗内容视图（替换 TrollSpeed 自带按钮球）——放粉色萝莉塔小女孩
//  本文件为最小替代实现，满足 HUDMainWindow/HUDMainApplicationDelegate 对
//  HUDRootViewController 的引用（passthroughMode 类方法 + init）。
//

#import <UIKit/UIKit.h>

@interface HUDRootViewController : UIViewController

/// 是否穿透触摸（悬浮窗内容之外区域是否透传给下层）
+ (BOOL)passthroughMode;
+ (void)setPassthroughMode:(BOOL)enabled;

@end
