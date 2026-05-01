export THEOS_PACKAGE_DIR_NAME = packages
export TARGET = iphone:clang:latest:18.0
export ARCHS = arm64

MODULES = jailed

INSTALL_TARGET_PROCESSES = MobileMLBB

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MLBBESP

MLBBESP_FILES = Tweak.xm
MLBBESP_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable
MLBBESP_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
MLBBESP_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 MobileMLBB" 2>/dev/null || true
