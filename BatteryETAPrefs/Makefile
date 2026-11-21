TARGET := iphone:clang:16.5:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = BatteryETAPrefs

BatteryETAPrefs_FILES = BTRootListController.m
BatteryETAPrefs_FRAMEWORKS = UIKit
BatteryETAPrefs_PRIVATE_FRAMEWORKS = Preferences
BatteryETAPrefs_INSTALL_PATH = /Library/PreferenceBundles
BatteryETAPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
