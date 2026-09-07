ARCHS = arm64
TARGET = iphone:clang:17.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakeDevice
FakeDevice_FILES = Tweak.x
FakeDevice_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations -Wno-unused-variable
FakeDevice_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

