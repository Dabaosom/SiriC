ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = Tweak.xm
SiriC_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SiriC_FRAMEWORKS = Foundation UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
