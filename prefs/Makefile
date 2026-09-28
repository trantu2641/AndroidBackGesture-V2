ARCHS = arm64e
TARGET := iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AndroidBackGesturePrefs

AndroidBackGesturePrefs_FILES = \
	ABGRootListController.m

AndroidBackGesturePrefs_CFLAGS = \
	-fobjc-arc

AndroidBackGesturePrefs_FRAMEWORKS = \
	UIKit \
	Foundation

AndroidBackGesturePrefs_PRIVATE_FRAMEWORKS = \
	Preferences

AndroidBackGesturePrefs_INSTALL_PATH = \
	/Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
