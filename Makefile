ARCHS = arm64e arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = com.apple.springboard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SiriBridge
SiriBridge_FILES = SBCore.m SBRecog.m SBNet.m SBAce.m SBSubmit.m SBRouter.m SBObserve.m
SiriBridge_CFLAGS = -fblocks -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
SiriBridge_CFLAGS += -DSB_STAGE=5 -DSB_NET_SUBMIT=1 -DSB_SYNC_AI=1
SiriBridge_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
