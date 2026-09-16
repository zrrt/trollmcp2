ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# v2.9.193: tweak.mk → library.mk（纯 C/ObjC 无 Logos/MSHook，去 CydiaSubstrate 依赖）
LIBRARY_NAME = TrollMCPAgent
TrollMCPAgent_FILES = Tweak.x
TrollMCPAgent_CFLAGS = -fobjc-arc
TrollMCPAgent_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
