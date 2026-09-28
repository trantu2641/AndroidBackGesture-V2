ARCHS = arm64e
TARGET := iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME = roothide
DEB_ARCH = iphoneos-arm64e

FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AndroidBackGesture

AndroidBackGesture_FILES = Tweak.xm
AndroidBackGesture_CFLAGS = -fobjc-arc

AndroidBackGesture_FRAMEWORKS = \
	UIKit \
	WebKit \
	QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload"
