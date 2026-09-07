ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MemoryTweak
MemoryTweak_FILES = Tweak.x
MemoryTweak_CFLAGS = -fobjc-arc
MemoryTweak_LDFLAGS =

include $(THEOS_MAKE_PATH)/tweak.mk
