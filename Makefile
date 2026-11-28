ARCHS = arm64e arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = com.apple.springboard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriBridge
SiriBridge_FILES = SBCore.m SBRecog.m SBNet.m SBAce.m SBSubmit.m SBRouter.m SBObserve.m SBShortcut.m SBTouch.m SBScreen.m
SiriBridge_CFLAGS = -fblocks -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
SiriBridge_CFLAGS += -DSB_STAGE=5 -DSB_NET_SUBMIT=1 -DSB_SELFTEST=0 -DSB_ENABLE_TOUCHCTL=1 -DSB_ENABLE_SCREENCTL=1
SiriBridge_FRAMEWORKS = Foundation CoreFoundation CoreGraphics ImageIO
SiriBridge_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
