TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AuxCamFloat
AuxCamFloat_FILES = Tweak.xm
AuxCamFloat_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AuxCamFloat_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
