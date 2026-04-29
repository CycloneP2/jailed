export THEOS_PACKAGE_DIR_NAME = packages
export TARGET = iphone:clang:latest:11.0
export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME = jailed

INSTALL_TARGET_PROCESSES = MobileMLBB

include $(THEOS)/makefiles/common.mk
include $(THEOS)/modules/theos-jailed/module/common.mk

TWEAK_NAME = MLBBESP

MLBBESP_FILES = Tweak.xm
MLBBESP_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MLBBESP_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
MLBBESP_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 MobileMLBB" 2>/dev/null || true
