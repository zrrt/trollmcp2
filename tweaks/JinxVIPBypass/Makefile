THEOS_PACKAGE_SCHEME=rootless
TARGET = iphone:clang:latest:14.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = JinxVIPBypass
JinxVIPBypass_FILES = Tweak.x
JinxVIPBypass_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
