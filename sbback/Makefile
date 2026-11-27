ARCHS = arm64e arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BBTap
BBTap_FILES = BBTap.m
BBTap_CFLAGS = -fblocks -Wno-unused-variable


include $(THEOS_MAKE_PATH)/tweak.mk