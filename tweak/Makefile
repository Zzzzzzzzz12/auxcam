TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AuxCamTweak
AuxCamTweak_FILES = Tweak.xm
AuxCamTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AuxCamTweak_FRAMEWORKS = UIKit Foundation AVFoundation AVKit CoreMedia CoreVideo CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
