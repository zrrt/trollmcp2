# 桌面悬浮 HUD 独立二进制（theos application.mk）
# 参考 TrollSpeed Makefile，只编 HUD 部分。产物 TrollAgentHUD.app，带系统 entitlements 独立签名。
# 由主 App 用 posix_spawn + root persona 拉起；HUD 窗口放小女孩。

ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TrollAgentHUD

TrollAgentHUD_USE_MODULES := 0

TrollAgentHUD_FILES = \
    sources/HUDApp.mm \
    sources/HUDMainApplication.mm \
    sources/HUDMainWindow.mm \
    sources/HUDMainApplicationDelegate.mm \
    sources/HUDHelper.mm \
    sources/TSEventFetcher.mm \
    sources/HUDRootViewController.mm \
    sources/HUDLive2D.mm \
    sources/UITouch-KIFAdditions.m \
    sources/IOHIDEvent+KIF.m \
    sources/HUDMain.mm

# ---- Cubism Live2D SDK (CubismSdkForNative-5-r.5) ----
# 排除实验（2026-10-09）：USE_CUBISM=0 临时禁用 Cubism 编译，验证 HUD 启动崩溃是否由 Cubism 编入引起。
# 确认后置 1 恢复，并按独立进程/动态加载方式接入。
USE_CUBISM := 0
ifeq ($(USE_CUBISM),1)
CUBISM_ROOT = cubism
CUBISM_CORE = $(CUBISM_ROOT)/Core/lib/ios/Release-iphoneos/libLive2DCubismCore.a
# 只编核心 Framework + Metal 渲染器；排除 OpenGL/D3D9/D3D11/Vulkan（iOS 不需要，OpenGL 还需已废弃的 OpenGLES.framework）
CUBISM_FW_SRC = $(shell find $(CUBISM_ROOT)/Framework/src -name '*.cpp' | grep -v -E '(Rendering/(OpenGL|D3D9|D3D11|Vulkan)|Rendering/[^/]*/Shaders)')
CUBISM_FW_METAL_SRC = $(shell find $(CUBISM_ROOT)/Framework/src/Rendering/Metal -name '*.mm')
CUBISM_LAPP_SRC = $(shell find $(CUBISM_ROOT)/LApp -name '*.mm' -o -name '*.m')
TrollAgentHUD_FILES += $(CUBISM_FW_SRC) $(CUBISM_FW_METAL_SRC) $(CUBISM_LAPP_SRC)
TrollAgentHUD_CFLAGS += -I$(CUBISM_ROOT)/Framework/src -I$(CUBISM_ROOT)/Core/include -I$(CUBISM_ROOT)/LApp
# Cubism Framework 需要 C++14
TrollAgentHUD_CFLAGS += -std=gnu++14
# Cubism Live2D 渲染：仅 Metal（iOS 主渲染）。不链 OpenGLES——iOS 17+ 已废弃/移除，链入会启动崩溃
TrollAgentHUD_FRAMEWORKS += Metal
# 链接 Cubism Core 静态库
TrollAgentHUD_LDFLAGS += $(CUBISM_CORE)
endif

TrollAgentHUD_CFLAGS += -fobjc-arc
TrollAgentHUD_CFLAGS += -Iheaders
TrollAgentHUD_CFLAGS += -Isources
TrollAgentHUD_CFLAGS += -include supports/hudapp-prefix.pch
TrollAgentHUD_CFLAGS += -Wno-error -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function

TrollAgentHUD_FRAMEWORKS += CoreGraphics CoreServices QuartzCore IOKit UIKit Metal MetalKit
TrollAgentHUD_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices SpringBoardServices
# 私有 framework 符号由 TrollSpeed libraries/*.tbd 提供（Xcode SDK 无私有 tbd）：
# -F 指向 HUD/libraries/<fw>.framework/<fw>，配合 PRIVATE_FRAMEWORKS 生成的 -framework 链上
TrollAgentHUD_LDFLAGS += -Flibraries
TrollAgentHUD_CODESIGN_FLAGS += -Ssupports/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
