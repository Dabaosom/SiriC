ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = main_async.xm
SiriC_CFLAGS = -Wno-deprecated-declarations -fobjc-arc
SiriC_FRAMEWORKS = Foundation CoreFoundation
SiriC_LIBRARIES = pthread

include $(THEOS_MAKE_PATH)/tweak.mk
