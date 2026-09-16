ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# v2.9.196: library.mk → tweak.mk（回滚）
# library.mk 产物注入后 dyld 加载即崩（SIGTRAP/SIGSEGV，顶级弓箭手实测），
# 而 tweak.mk 产物（TrollMCPAgent 用户手动注入验证过可加载）配合 enable 的
# prepareSubstrate（注入 CydiaSubstrate.framework）可用。Tweak.x 保持无 scene hook。
TWEAK_NAME = ControlAgent
ControlAgent_FILES = Tweak.x
ControlAgent_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations -Wno-unused-variable
ControlAgent_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
