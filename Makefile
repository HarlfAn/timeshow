export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BatteryETA

BatteryETA_FILES = Tweak.x
BatteryETA_CFLAGS = -fobjc-arc
BatteryETA_FRAMEWORKS = UIKit Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
