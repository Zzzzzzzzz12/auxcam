# auxcamd：推流接收守护进程（LaunchDaemon），与 ios-app 共用 OpenH264Bridge.c 做解码和共享帧发布。
# iOS 18.x 的越狱（Dopamine 2.x / Bootstrap / roothide 等）都是 rootless，根在 /var/jb。
# 所以这里所有安装路径都显式写 /var/jb 前缀，不依赖 Theos 的 package scheme。
ifndef OPENH264_DIR
$(error OPENH264_DIR must point at an OpenH264 checkout built for iOS (libopenh264.a))
endif

TARGET := iphone:clang:latest:15.0
# libopenh264.a 只编了 arm64，所以这里不带 arm64e。
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = auxcamd
auxcamd_FILES = main.c vcu1.c ../ios-app/AuxCam/OpenH264Bridge.c
auxcamd_CFLAGS = -O2 -Wall -Wno-unused-function -I../ios-app/AuxCam -I$(OPENH264_DIR)/codec/api/wels
auxcamd_LDFLAGS = $(OPENH264_DIR)/libopenh264.a -lc++
auxcamd_FRAMEWORKS = CoreVideo IOSurface VideoToolbox
# rootless：装到 /var/jb/usr/libexec（roothide 下 /var/jb 是软链，同样成立）
auxcamd_INSTALL_PATH = /var/jb/usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
