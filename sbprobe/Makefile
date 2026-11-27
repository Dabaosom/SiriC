ARCHS = arm64e arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BBProbe
BBProbe_FILES = BBProbe.m
BBProbe_CFLAGS = -Wno-unused-variable

include $(THEOS_MAKE_PATH)/tweak.mk