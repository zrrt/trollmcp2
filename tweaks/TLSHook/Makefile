ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TLSHook
TLSHook_FILES = Tweak.x fishhook.c
TLSHook_CFLAGS = -fobjc-arc -I.
TLSHook_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
