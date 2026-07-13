export PACKAGE_VERSION := 3.85
export THEOS_PACKAGE_SCHEME

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
ARCHS := arm64 x86_64
TARGET := simulator:clang:latest:15.0
IPHONE_SIMULATOR_ROOT := $(shell devkit/sim-root.sh)
else
ARCHS := arm64
ifeq ($(THEOS_PACKAGE_SCHEME),)
TARGET := iphone:clang:16.5:13.0
else
TARGET := iphone:clang:16.5:13.0
endif
endif

GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

TOOL_NAME += trollvncserver

trollvncserver_USE_MODULES := 0

trollvncserver_FILES += src/trollvncserver.mm
trollvncserver_FILES += src/BulletinManager.mm
trollvncserver_FILES += src/ClipboardManager.mm
trollvncserver_FILES += src/ScreenCapturer.mm
trollvncserver_FILES += src/STHIDEventGenerator.mm
trollvncserver_FILES += src/OhMyJetsam.mm
trollvncserver_FILES += src/TVNCHttpServer.mm
trollvncserver_FILES += src/TVNCApiManager.mm

# v3.40: Dropped iOS < 13.4 support. Removed fishhook and weak symbol shim.
# ___darwin_check_fd_set_overflow is natively available on iOS 13.4+.

trollvncserver_CFLAGS += -fobjc-arc
trollvncserver_CFLAGS += -Wno-unknown-warning-option
trollvncserver_CFLAGS += -Wno-unused-but-set-variable
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_CFLAGS += -march=armv8-a+crc
endif
trollvncserver_CCFLAGS += -std=c++20

trollvncserver_CFLAGS += -DPACKAGE_VERSION=\"$(PACKAGE_VERSION)\"
ifeq ($(THEOS_PACKAGE_SCHEME),)
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"legacy\"
else
trollvncserver_CFLAGS += -DTHEOS_PACKAGE_SCHEME=\"$(THEOS_PACKAGE_SCHEME)\"
endif

ifeq ($(THEBOOTSTRAP),1)
trollvncserver_CFLAGS += -DTHEBOOTSTRAP=1
endif

trollvncserver_CFLAGS += -Iinclude-spi
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CFLAGS += -Iinclude-simulator
trollvncserver_LDFLAGS += -Llib-simulator
trollvncserver_LDFLAGS += -FPrivateFrameworks
else
trollvncserver_CFLAGS += -Iinclude
trollvncserver_LDFLAGS += -Llib
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
else
trollvncserver_LIBRARIES += crypto
trollvncserver_LIBRARIES += lzo2
trollvncserver_LIBRARIES += turbojpeg
trollvncserver_LIBRARIES += png18
trollvncserver_LIBRARIES += sasl2
trollvncserver_LIBRARIES += ssl
trollvncserver_LIBRARIES += vncserver
trollvncserver_LIBRARIES += z
endif

# roothide scheme needs -lroothide for the roothide API.
# BUT bootstrap.sh also sets THEOS_PACKAGE_SCHEME=roothide (uses roothide toolchain for
# entitlement stripping). Bootstrap builds must NOT link -lroothide (no jbroot on device).
# Only the actual roothide (non-bootstrap) scheme needs this.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ifneq ($(THEBOOTSTRAP),1)
trollvncserver_LDFLAGS += -lroothide
endif
endif

trollvncserver_FRAMEWORKS += Accelerate
trollvncserver_FRAMEWORKS += AVFoundation
trollvncserver_FRAMEWORKS += CoreGraphics
trollvncserver_FRAMEWORKS += CoreMedia
trollvncserver_FRAMEWORKS += CoreVideo
trollvncserver_FRAMEWORKS += Foundation
trollvncserver_FRAMEWORKS += IOKit
trollvncserver_FRAMEWORKS += IOSurface
trollvncserver_FRAMEWORKS += ImageIO
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += UIKit
trollvncserver_FRAMEWORKS += UserNotifications

trollvncserver_PRIVATE_FRAMEWORKS += FrontBoardServices
trollvncserver_PRIVATE_FRAMEWORKS += SpringBoardServices

ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_PRIVATE_FRAMEWORKS += Preferences
endif

ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncserver_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncserver-simulator.entitlements
else
trollvncserver_CODESIGN_FLAGS += -Ssrc/trollvncserver.entitlements
endif

ifeq ($(THEBOOTSTRAP),1)
TOOL_NAME += trollvncmanager

trollvncmanager_FILES += src/trollvncmanager.mm
trollvncmanager_FILES += src/TRWatchDog.mm
trollvncmanager_FILES += src/TaskProcess+ObjC.swift
trollvncmanager_FILES += src/OhMyJetsam.mm

trollvncmanager_CFLAGS += -fobjc-arc
trollvncmanager_CFLAGS += -Iinclude-spi

trollvncmanager_FRAMEWORKS += Foundation
ifeq ($(THEOS_DEVICE_SIMULATOR),1)
trollvncmanager_CODESIGN_FLAGS += -f -s - --entitlements src/trollvncmanager.entitlements
else
trollvncmanager_CODESIGN_FLAGS += -Ssrc/trollvncmanager.entitlements
endif
endif

include $(THEOS_MAKE_PATH)/tool.mk

SUBPROJECTS += prefs/TrollVNCPrefs
SUBPROJECTS += prefs/CCTrollVNC

ifeq ($(THEBOOTSTRAP),1)
SUBPROJECTS += app/TrollVNC
else
SUBPROJECTS += app/MatisuXCS
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

export THEOS_PACKAGE_SCHEME
export THEOS_STAGING_DIR
before-package::
	@devkit/before-package.sh

export THEOS_STAGING_DIR
after-package::
	@devkit/after-package.sh
