ARCHS = arm64e arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriC
SiriC_FILES = main_stage1.c
SiriC_CFLAGS = -Wno-deprecated-declarations
SiriC_FRAMEWORKS = CoreFoundation
SiriC_LIBRARIES = pthread

include $(THEOS_MAKE_PATH)/tweak.mk
