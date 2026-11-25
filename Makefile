ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = main_stages2.c
SiriC_CFLAGS = -fblocks -Wno-deprecated-declarations
SiriC_FRAMEWORKS = CoreFoundation
SiriC_LIBRARIES = pthread objc

include $(THEOS_MAKE_PATH)/tweak.mk
