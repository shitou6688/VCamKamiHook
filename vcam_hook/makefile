# VCAM Kami Hook - Makefile
# 
# 编译方式 (需要有 iOS SDK / Theos / Xcode):
#
# 方式 1: 直接用 Xcode 命令行工具
#   xcrun -sdk iphoneos clang \
#     -arch arm64 -arch arm64e \
#     -shared -fobjc-arc \
#     -o vcam_kami_hook.dylib vcam_kami_hook.m \
#     -framework Foundation -framework UIKit -lobjc \
#     -miphoneos-version-min=14.0
#
# 方式 2: 用 Theos (如果已安装)
#   make package
#
# 方式 3: 签名
#   ldid -S vcam_kami_hook.plist vcam_kami_hook.dylib

ARCHS = arm64 arm64e
TARGET = iphone:clang:14.0:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcam_kami_hook
vcam_kami_hook_FILES = vcam_kami_hook.m
vcam_kami_hook_FRAMEWORKS = Foundation UIKit
vcam_kami_hook_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
