# Changelog

All notable changes to TrollVNC are documented here.

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
