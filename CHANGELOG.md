# Changelog

All notable changes to TrollVNC are documented here.

## [3.83] – 2026-07-12

### Fixed
- **iOS 16 长时 noVNC 投屏服务假死**: 长时无人操作投屏时，设备按自动锁定熄屏，CADisplayLink 暂停 → 不再产帧 → 画面定格且监管层（launchd KeepAlive / trollvncmanager TRWatchDog）因进程仍存活而无法自愈。
  - **默认开启防休眠保活**: `gKeepAliveSec` 默认值由 `0.0`（关）改为 `15.0`，在有客户端连接时周期性发送 `ACUnlock` 消费者事件重置 iOS 闲置计时器，使显示保持常亮。仅在 `clients > 0` 时生效，无客户端时设备可正常休眠。
  - **新增帧存活探针（watchdog）**: 在后台 GCD 队列上运行独立定时器，与主线程解耦——即便主线程卡死也能触发。当存在客户端连接且超过 60s 未成功产帧时，主动 `exit(0)` 退出，交由监管层重启（配合默认防休眠，重启后显示唤醒、恢复产帧），将“永久假死”变为“可自愈”。

## [3.44] – 2026-07-09

### Fixed
- **iOS 15 以太网重启后无法启动服务**: 当设备使用以太网（非WiFi）时，NEHotspotHelper 不会触发导致开机后服务无法自动启动。修复：在有 jbroot (/var/jb) 的环境下，自动创建 LaunchDaemon plist 到 `/var/jb/Library/LaunchDaemons/com.82flex.trollvnc.plist`，系统启动时由 launchd 直接拉起 trollvncserver，不依赖 WiFi 事件
- **Bootstrap 编译修复**: `registerForTaskWithIdentifier:usingQueue:` 参数标签 `handler:` 修正为 `launchHandler:`

### Changed
- **LaunchDaemon 管理**: trollvncmanager 启动时自动检测 jbroot，创建/更新 LaunchDaemon plist，运行身份为 root

## [3.2-273-iOS13] – 2026-05-03

### Added
- **iOS 13 专用版本**: 为 iOS 13 设备提供专用支持

### Changed
- **编译目标**: 最低支持版本从 iOS 14.0 改为 iOS 13.0
- **版本号**: 更新为 3.2-273-iOS13，以区分 iOS 13 专用版本

### Fixed
- **LaunchDaemons plist**: 移除 iOS 13 不支持的 `POSIXSpawnType` 键
- **Orientation Observer**: 添加 iOS 13 检查，在 iOS 13 上禁用 orientation sync 功能
- **Screen Capturer**: 处理 `IOSurfaceAccelerator` API 在 iOS 13 上的兼容性问题，添加 fallback 方案
- **Bulletin Manager**: 处理 `UNUserNotificationCenter` 的私有 API 在 iOS 13 上的兼容性问题
- **Screen Capturer**: 处理 `_unjailedReferenceBoundsInPixels` 在 iOS 13 上的兼容性问题，使用 `nativeBounds` 替代

## [3.2] – 2026-04-19

### Added
- **Bind Address**: The VNC server can now be bound to a specific local IP address. Leave empty to listen on all interfaces. Validation is performed in the app UI before applying.
- **Orientation Correction** (formerly *Apply Orientation Fix*): Replaced the on/off toggle with a four-option selector — 0° (Default), 90° Clockwise, 180°, and Counterclockwise 90°. Useful for iPad models with non-standard default orientations.
- **Subscription Reconnection**: The client list now automatically reconnects to the VNC server daemon with exponential backoff (1s → 30s cap) and TCP keep-alive, recovering gracefully from server restarts.
- **Simulator Sandbox Support**: `sim-spawn.sh` now forwards the simulator sandbox path as an environment variable so the server reads preferences from the correct location during development. Logs are tee’d to both the terminal and the sandbox tmp directory.

### Changed
- Xcode app target now reads and writes preferences via the daemon’s sandbox path when running in the simulator.

### Fixed
- Version check now falls back gracefully on older iOS versions where the system API is unavailable.
- Fixed a short-read bug in `TVNCReadAll`: data is now read until EOF or timeout instead of stopping early on a partial buffer.
- Fixed subscription handshake validation: the server response is now checked to contain “OK” before the client list is considered live; an invalid response triggers an immediate reconnect.
- Fixed `TVNCSliderCell` reuse bugs: `prepareForReuse` resets the slider to `minimumValue`, and `refreshCellContentsWithSpecifier:` fully re-applies `min`/`max`/`format`/`isContinuous` from the incoming specifier.
