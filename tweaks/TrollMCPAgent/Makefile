ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TrollMCPAgent
TrollMCPAgent_FILES = Tweak.x
TrollMCPAgent_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
