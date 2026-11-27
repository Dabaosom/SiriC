ARCHS = arm64e arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBApp
SBApp_FILES = SBApp.m
SBApp_CFLAGS = -fblocks -Wno-deprecated-declarations -Wno-unused-variable -Iheaders
SBApp_FRAMEWORKS = Foundation UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
