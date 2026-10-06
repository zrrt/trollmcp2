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
    sources/HUDRootViewController.mm

TrollAgentHUD_CFLAGS += -fobjc-arc
TrollAgentHUD_CFLAGS += -Iheaders
TrollAgentHUD_CFLAGS += -Isources
TrollAgentHUD_CFLAGS += -include supports/hudapp-prefix.pch
TrollAgentHUD_CFLAGS += -Wno-error -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function

TrollAgentHUD_FRAMEWORKS += CoreGraphics CoreServices QuartzCore IOKit UIKit
TrollAgentHUD_PRIVATE_FRAMEWORKS += BackBoardServices GraphicsServices SpringBoardServices
TrollAgentHUD_CODESIGN_FLAGS += -Ssupports/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
