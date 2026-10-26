# auxcamd：推流接收守护进程（LaunchDaemon），与 ios-app 共用 OpenH264Bridge.c 做解码和共享帧发布。
# 需要先把 OpenH264 编成 iOS 静态库，并把目录传进来：OPENH264_DIR=/path/to/openh264（见 .github/workflows/build-daemon.yml）
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
auxcamd_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
