ARCHS := arm64
TARGET := iphone:clang:16.5:13.0

INSTALL_TARGET_PROCESSES += MatisuXCS

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := MatisuXCS

MatisuXCS_FILES := MatisuXCS.m
MatisuXCS_INFO_PLIST := Info.plist
MatisuXCS_CFLAGS := -fobjc-arc
MatisuXCS_FRAMEWORKS := UIKit Foundation CoreServices
MatisuXCS_PRIVATE_FRAMEWORKS := SpringBoardServices FrontBoardServices MobileCoreServices
MatisuXCS_CODESIGN_FLAGS += -SMatisuXCS.entitlements
MatisuXCS_BUNDLE_RESOURCES := Icon-60@2x.png Icon-60@3x.png Icon-29@2x.png Icon-29@3x.png

include $(THEOS_MAKE_PATH)/application.mk
