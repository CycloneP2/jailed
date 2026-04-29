export THEOS_PACKAGE_DIR_NAME = packages
export TARGET = iphone:clang:latest:11.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = MobileMLBB

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mlbb-esp

mlbb-esp_FILES = Tweak.xm
mlbb-esp_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
mlbb-esp_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
mlbb-esp_PRIVATE_FRAMEWORKS = IOKit

include $(THEOS_MAKE_PATH)/tweak.mk

# Theos jailed module
include $(THEOS)/modules/theos-jailed/module.mk

after-install::
	install.exec "killall -9 MobileMLBB" 2>/dev/null || true
