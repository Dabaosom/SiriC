ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard com.apple.siri

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = main_stages2.c
SiriC_CFLAGS = -fblocks -Wno-deprecated-declarations
SiriC_FRAMEWORKS = CoreFoundation
SiriC_LIBRARIES = pthread objc

TWEAK_NAME += SiriUIProbe
SiriUIProbe_FILES = ui_probe.c
SiriUIProbe_CFLAGS = -Wno-deprecated-declarations
SiriUIProbe_FRAMEWORKS = UIKit CoreFoundation
SiriUIProbe_LIBRARIES = objc pthread

include $(THEOS_MAKE_PATH)/tweak.mk
