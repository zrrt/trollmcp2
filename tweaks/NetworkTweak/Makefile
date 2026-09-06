ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetworkTweak
NetworkTweak_FILES = Tweak.x
NetworkTweak_CFLAGS = -fobjc-arc
NetworkTweak_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
