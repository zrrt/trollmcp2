# 纯 dylib（library.mk）—— 不链接 substrate，避开加密的 CydiaSubstrate.framework
THEOS_PACKAGE_SCHEME=rootless
TARGET = iphone:clang:latest:14.0
ARCHS = arm64

LIBRARY_NAME = JinxVIPBypass
JinxVIPBypass_FILES = Tweak.m
JinxVIPBypass_CFLAGS = -fobjc-arc
JinxVIPBypass_FRAMEWORKS = UIKit
JinxVIPBypass_INSTALL_PATH = /usr/lib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/library.mk
