# 自动递增版本号
VERSION_FILE := .version
LAST_COMMIT := .last_commit

# 读取当前版本号
CURRENT_VERSION := 3.1.5
AUTO_BUILD := 0

# 检查是否有版本号文件
ifeq ($(wildcard $(VERSION_FILE)),$(VERSION_FILE))
	CURRENT_VERSION := $(shell cat $(VERSION_FILE))
endif

# 检查是否需要自增
ifneq ($(wildcard $(VERSION_FILE)),)
ifneq ($(wildcard $(LAST_COMMIT)),)
	# 如果有新的commit，自增版本号
	ifneq ($(shell cat $(LAST_COMMIT)),$(shell git rev-parse HEAD 2>/dev/null))
		AUTO_BUILD := 1
	endif
endif
endif

# 如果需要自增版本号
ifeq ($(AUTO_BUILD),1)
	# 解析版本号并自增第三位
	VERSION_PARTS := $(subst ., ,$(CURRENT_VERSION))
	MAJOR := $(word 1,$(VERSION_PARTS))
	MINOR := $(word 2,$(VERSION_PARTS))
	BUILD := $(word 3,$(VERSION_PARTS))
	ifeq ($(BUILD),)
		BUILD := 1
	else
		BUILD := $$(($(BUILD) + 1))
	endif
	PACKAGE_VERSION := $(MAJOR).$(MINOR).$(BUILD)
	@echo "Auto-incrementing version to $(PACKAGE_VERSION)"
else
	# 首次或无变化，使用当前版本号
	PACKAGE_VERSION := $(CURRENT_VERSION)
endif

export PACKAGE_VERSION := $(PACKAGE_VERSION)
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
trollvncserver_FILES += src/TVNCApiManager.mm
trollvncserver_FILES += src/TVNCHttpServer.mm

# 只在 roothide/rootless 方案下添加 root 权限支持（使用 roothide SDK）
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
ifneq ($(THEOS_PACKAGE_SCHEME),default)
trollvncserver_FILES += shared/TSUtil.m
trollvncserver_CFLAGS += -DHAS_ROOT_SUPPORT=1
# 添加 shared 目录到 include 路径
trollvncserver_CFLAGS += -Ishared
endif
endif

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

# 设置 USE_ROOTHIDE_NOTIFY 宏 - rootless 和 roothide 都使用 roothide SDK 的 token-based API
# 只有 legacy (default) scheme 如果有独立 theos 才使用字符串 API
# 由于 GitHub Actions 只有 theos-roothide，所以统一使用 token-based API
ifeq ($(THEOS_PACKAGE_SCHEME),)
# legacy scheme - 检查是否使用 roothide SDK
ifneq ($(THEOS),)
# 使用 roothide SDK
trollvncserver_CFLAGS += -DUSE_ROOTHIDE_NOTIFY=1
else
trollvncserver_CFLAGS += -DUSE_ROOTHIDE_NOTIFY=1
endif
else
# rootless 或 roothide - 都使用 roothide SDK
trollvncserver_CFLAGS += -DUSE_ROOTHIDE_NOTIFY=1
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

trollvncserver_FRAMEWORKS += Accelerate
trollvncserver_FRAMEWORKS += AVFoundation
trollvncserver_FRAMEWORKS += CoreFoundation
trollvncserver_FRAMEWORKS += CoreGraphics
trollvncserver_FRAMEWORKS += CoreMedia
trollvncserver_FRAMEWORKS += CoreVideo
trollvncserver_FRAMEWORKS += Foundation
trollvncserver_FRAMEWORKS += IOKit
trollvncserver_FRAMEWORKS += IOSurface
trollvncserver_FRAMEWORKS += ImageIO
trollvncserver_FRAMEWORKS += MediaPlayer
trollvncserver_FRAMEWORKS += QuartzCore
trollvncserver_FRAMEWORKS += UIKit
trollvncserver_FRAMEWORKS += UserNotifications

trollvncserver_PRIVATE_FRAMEWORKS += FrontBoardServices
ifeq ($(THEOS_DEVICE_SIMULATOR),)
trollvncserver_PRIVATE_FRAMEWORKS += SpringBoardServices
endif

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
endif

include $(THEOS_MAKE_PATH)/aggregate.mk

export THEOS_PACKAGE_SCHEME
export THEOS_STAGING_DIR
before-package::
	@devkit/before-package.sh

export THEOS_STAGING_DIR
after-package::
	@devkit/after-package.sh
