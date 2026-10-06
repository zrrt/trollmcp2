# HUD —— 桌面悬浮窗框架（抄自 TrollSpeed，MIT）

本目录是 **TrollSpeed**（https://github.com/Lessica/TrollSpeed ，MIT License, Copyright (c) 2023 Lessica）的 HUD（悬浮窗）框架源码与私有头文件，复制进 TrollAgent 工程用于实现「桌面悬浮小女孩」。

## 架构
- `HUDApp.mm` —— HUD 独立进程的 `main`（`-hud` 参数分支，自己初始化 UIApplication）
- `HUDMainApplication.mm` —— HUD 的 UIApplication 子类（装 HID 事件源，接收触摸）
- `HUDMainWindow.mm` —— 全局系统窗口（`_isSystemWindow` 等私有方法）
- `HUDHelper.mm` —— `posix_spawn` + root persona 拉起 HUD 进程
- `MainApplication.mm` / `MainApplicationDelegate.mm` —— 主 App 入口与 spawn 触发（参考）
- `headers/` —— 私有框架头文件（UIAutoRotatingWindow / UIEventDispatcher / SBSAccessibilityWindowHostingController 等）
- `supports/entitlements.plist` —— HUD 进程系统级 entitlements（persona-mgmt / no-sandbox / hid.client / springboard.accessibility-window-hosting 等）

## 版权
TrollSpeed 是 MIT 开源，核心框架直接抄用，保留原版权声明。本目录文件保留原作者的 header 注释。

## 集成方式（本工程选型）
主 App（SwiftPM Swift 工程）与 HUD 分离：
- HUD 作为**独立二进制**，用 theos 编译（参考 TrollSpeed Makefile，只编 HUD 部分），带 `supports/entitlements.plist` 独立签名
- 主 App 设置里加「桌面悬浮」开关 → 用 `posix_spawn` + root persona 拉起 HUD 二进制
- HUD 窗口里放小女孩多帧动画（读主 App bundle 的 girl_*.png）
