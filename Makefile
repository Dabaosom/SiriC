ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = main_net.m
SiriC_CFLAGS = -Wno-deprecated-declarations -Wno-objc-root-class
SiriC_FRAMEWORKS = Foundation CoreFoundation
SiriC_LIBRARIES = pthread

include $(THEOS_MAKE_PATH)/tweak.mk
