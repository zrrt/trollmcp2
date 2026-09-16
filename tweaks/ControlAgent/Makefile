ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# v2.9.193: tweak.mk → library.mk（纯 C/ObjC 无 Logos/MSHook）
# tweak.mk 产物强制链接 CydiaSubstrate（/Library/Frameworks/CydiaSubstrate），
# iOS 16.3 TrollStore 环境 substrate 兼容性差 → 注入后目标 App 真闪退（B站实测）。
# library.mk 编纯 dylib，不依赖 substrate，注入即加载。
LIBRARY_NAME = ControlAgent
ControlAgent_FILES = Tweak.x
ControlAgent_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations -Wno-unused-variable
ControlAgent_FRAMEWORKS = Foundation UIKit
ControlAgent_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
