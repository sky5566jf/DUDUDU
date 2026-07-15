# Changelog

All notable changes to TrollVNC are documented here.

## [3.95] – 2026-07-15

### Changed（前台 App 检测新增 sysctl 进程枚举兜底）
- 用户修改了清理后台 API 的前台检测逻辑（`TrollVNC/src/` 开发分支）。该目录不参与生产编译（编译只用根目录 `src/`），已将其**唯一有意义的新增**——`sysctl`/`proc_pidpath` 枚举 `/Applications/` 用户进程兜底——移植进根目录 `src/TVNCApiManager.mm` 的 `frontmostAppInfo`，作为 **Tier 4**（FBS → SBS XPC → legacy → sysctl）。
- 保留 v3.94 已验证的 **FrontBoardServices 优先**策略（比用户分支里把 `SBSCopyFrontmostApplicationDisplayIdentifier()` 当首选更可靠，后者在 daemon 下必然返回 nil，正是原 bug）。
- `/api/clearapps/smart` 文档措辞对齐用户意图（"不在桌面则关闭前台应用"）。
- 注：用户 `TrollVNC/src/` 分支里 `p_stat == SZ.ACT` 写法无效（该宏不存在，会编译失败），移植时已改为标准 `SRUN`。

## [3.94] – 2026-07-15

### Fixed（前台 App 检测改用 FrontBoardServices，真正解决 daemon 下误判桌面）
- **根因定位**：3.91/3.92 把前台检测改成 SpringBoardServices 的 XPC（`SBFrontmostApplication*`）+ `com.apple.springboard.appcontrol` 授权，但真机实测该 XPC 从 `trollvncserver`（daemon）上下文**仍然返回 nil**（即 `stage:foreground_pid` 失败、clearapps 误判 `onSpringBoard:true`）。SpringBoard 的 XPC 对外部 daemon 不可靠。
- **改为 FrontBoardServices 优先**：`FBSApplicationWorkspace.defaultWorkspace.runningApplications` 走的是 **backboardd 的 `FBSSystemService` XPC**（我们有 `com.apple.frontboard.launchapplications` 授权），daemon 下可靠；用 `visibility`/`isActive`/`isForeground` 评分挑出真正的前台 App，直接拿到 `bundleIdentifier` 与 `processIdentifier`。
- `getFrontmostAppBundleID` 重构为诊断版 `frontmostAppInfo`（返回 `{method, bundleID, pid}`，记录命中通道），FBS → SBS XPC → legacy `SBSCopyFrontmostApplicationDisplayIdentifier` 三层兜底。
- **修复 `isOnSpringBoard` 的误判**：旧实现在 daemon 下 `[UIApplication sharedApplication]` 返回 nil 会直接 `return YES`（永远判定桌面）。改为以 `frontmostBundleID` 为主判断，UIApplication 状态仅作最后兜底。
- **`tvnc_foreground_pid` 新增 FBS 通道**（置于最优先）：直接救 `input_inject` 的 `foreground_pid` 阶段——此前该阶段因 SBS XPC 调不通而失败，进程内注入通道始终不可用。
- 新增 `POST /api/clearapps/force`（强制清理：即使在桌面也执行"多任务+上滑杀进程"）与 `GET /api/frontmost`（诊断：当前前台 App 的 bundleID 及命中通道）。

### Added
- `clearBackgroundAppsSmartForce:(BOOL)force` + `performClearBackgroundApps:`，`/api/clearapps/force` 路由与 `handleClearAppsForce`。
- `/api/frontmost` 诊断路由与 `handleFrontmost`。

## [3.93] – 2026-07-15

### Added（新增 `/api/input_keyboard` 键盘系统输入通道）
- **`POST /api/input_keyboard`**：通过 iOS 键盘系统私有 API `UIKeyboardImpl`（单例 `sharedInstance` → `addText:` / 兜底 `insertText:`）直接输入文本。
  - 绕过第一响应者类型限制，**不依赖剪贴板，不会触发 iOS 16 "允许粘贴"弹窗**。
  - **不需要前台 PID / `task_for_pid`**，与 `/api/input_inject` 互补——在注入通道（含 `foreground_pid` 检测）不可用时，可作为独立的游戏/自绘框文本输入方案。
  - 适用：游戏/引擎自绘/标准输入框；对完全不接系统键盘的自绘框可能无效（仍需进程内注入 `input_inject`）。
  - 主线程安全：内部 `dispatch_async` 回主线程 + `dispatch_semaphore` 等待，避免 `dispatch_sync` 死锁（同 `input_ax` 修复思路）。
  - `TVNCApiManager` 新增 `inputTextViaKeyboard:`，HTTP 层新增 `handleInputKeyboard:`。
  - 测试页 `text_api_test.html` 新增 `input_keyboard` 测试项；`/api/endpoints` 文档补全 input_hid/input_ax/input_keyboard/input_inject/inject_probe 说明。

## [3.92] – 2026-07-15

### Fixed（修复 `clearapps/smart` 误判在桌面导致不清理）
- **`/api/clearapps/smart` 在 App 处于前台时却返回 `frontmostApp:"unknown"` + `onSpringBoard:true` + `action:"skipped"`**：根因是 `getFrontmostAppBundleID` 使用了老的 `SBSCopyFrontmostApplicationDisplayIdentifier()`，该私有 API 在 `trollvncserver`（无 UIKit/backboard 连接的 daemon）上下文必然返回 nil，于是上层把"前台有 App"误判成"在桌面"，直接跳过清理。
- `getFrontmostAppBundleID` 改用 **SpringBoardServices 的 XPC 直查接口**（`SBFrontmostApplicationBundleIdentifier()` 直接拿 bundle id；兜底 `SBFrontmostApplication()` → `bundleIdentifier`），与注入通道同款机制，**daemon 下可用、无需辅助功能授权**。老 API 保留为最后兜底。
- 修复后：前台有 App 时 `frontmostApp` 能正确返回真实 bundle id，`clearapps/smart` 会正常下发 `menuPress` 把当前 App 退到后台（而非误判桌面跳过）。

## [3.91] – 2026-07-15

### Fixed（进程内注入可真正启动）
- **修复 `/api/inject_probe` 与 `/api/input_inject` 在 `foreground_pid` 阶段直接失败**：原实现用 AX（`AXFocusedApplication`）取前台 PID，但 `trollvncserver` 是无界面 daemon，iOS 不会给它辅助功能授权，`AXFocusedApplication` 必然返回错误 → 注入根本起不来。
- 改为 **SpringBoardServices 优先**（`SBFrontmostApplication()` → `processIdentifier`；兜底 `SBFrontmostApplicationBundleIdentifier()` → 枚举进程匹配 `.app` 的 `Info.plist` 反查 pid），AX 仅作为最后兜底。该路径**不需要辅助功能授权**，daemon 也能用。
- `entitlements` 新增 `com.apple.springboard.appcontrol`（查询前台 App 状态所需），配合既有的 `launchapplications` 类授权，使 SpringBoard XPC 查询从外部进程可用。

## [3.90] – 2026-07-15

### Added（进程内注入 · 游戏文本输入终极方案）
- 新增 `POST /api/input_inject`：把 `tvnc_inject.dylib` 注入「前台游戏/目标 App 进程」，在其进程空间内直接调用 UIKit `insertText:`，**彻底绕开输入法与 AX 节点限制**——可解决游戏自绘框/Unity 输入框"任何字符都进不去"的问题（即懒人精灵巨魔版「root模式直接输入文字」等价实现）。
- 实现：`src/TVNCProcessInject.m`（主程序侧，仅 mach API：AX 取前台 PID → `task_for_pid` → 解析目标进程 `dlopen`/`dlsym` → 三步线程注入）。`src/tvnc_inject.m`（注入到目标进程的 dylib，真正调 UIKit）。
- `src/trollvncserver.entitlements` 新增注入类权限：`task_for_pid-allow` / `get-task-allow` / `com.apple.private.cs.debugger`（TrollStore 可声明任意 entitlements）。
- 每步返回详细 JSON（`stage`/`status`/`error`），便于在设备上定位失败环节（如 task_for_pid 被拒、符号解析失败、注入函数执行未生效）。
- 第一响应者获取改用 `sendAction:` 技巧（`-[UIResponder tvnc_currentFirstResponder]`），规避 `UIWindow.firstResponder` 私有属性在部分 SDK 下编译/运行不可靠的问题；并兼容 iOS 13+ 多场景 `connectedScenes` 取 keyWindow。
- **新增 Web 视图通道**：目标若内嵌 `WKWebView` 且焦点在 HTML `<input>`/`<textarea>`/`contenteditable`，`tvnc_inject.m` 会用 `evaluateJavaScript:` 把文本写入 `document.activeElement` 并派发 `input`/`change` 事件——覆盖 React/Vue 等受控组件（参考 RootCore inputText 的 `window._nxkbSetValue` 方案；纯 `insertText:` 在受控组件上不派发事件、框架读不到值）。
- **新增 `UIKeyInput` 协议回退**：仅实现 `UIKeyInput` 的自定义输入视图也能收到文本（在 `UITextInput`/`replaceRange:` 之后兜底）。

### Fixed
- 修复 `POST /api/input_ax` 用 body 传参时请求被重置（http 000 / 死锁）的 bug：原 `inputTextViaAX:` 在主线程同步处理 body 请求时 `dispatch_sync(main_queue)` 死锁。改为在独立工作线程跑 AX（避免主线程死锁），`?text=` 与 body 两种方式均稳定。

## [3.89] – 2026-07-14

### Changed
- 根路径 `/` 不再暴露完整 API 文档，改为只显示一行运行状态（`TrollVNC is running` + 提示）。完整接口列表移到 `GET /api/endpoints?key=matisu`，缺密钥/密钥错误返回 `403 Forbidden`。
- 密钥定义在 `src/TVNCHttpServer.mm` 的 `kTVNCEndpointsKey`（默认 `matisu`，如需修改改此常量即可）。

## [3.88] – 2026-07-14

### Fixed
- **关键修复：v3.86 / v3.87 新增的接口此前根本没进编译产物**。之前改动误写到不参与编译的 `TrollVNC/src/` 开发分支，而 Makefile 实际只编译根目录 `src/`。导致设备上 `/api/input_hid`、`/api/input_ax`、`/api/clearapps/smart`、`/api/assistivetouch`、`/api/install`、`/api/uninstall`、`/api/trollstore/diagnostics` 全部返回 404（实测 .19 设备 3.86 全 404 确认）。
  - 本次把上述 7 个 HTTP 路由 + 对应 handler 正式登记进编译用的 `src/TVNCHttpServer.mm`；其中 `handleInputHid:` / `handleInputAx:` 原缺失，已从开发分支补齐；`src/TVNCApiManager.mm` 补上 `inputTextViaAX:`（含 AX 私有框架动态 `dlopen` 初始化块）及 `#import <dlfcn.h>`。
  - 原有生产功能（group control / network debug / `screenshot/fast` / `stream.mjpeg` 等）不受影响。
  - 等价说明：v3.86 的 HID 文本注入、v3.87 的无障碍(AX)文本注入，至此才真正随构建下发到设备。

## [3.87] – 2026-07-14

### Added
- **新增 `POST /api/input_ax` —— 系统无障碍(AX)通道文本注入**: 解决游戏 / 引擎自绘 / WebView 等"任何字符都进不去"的输入框（懒人精灵巨魔版同款通道）。
  - 直接对"当前聚焦的 UI 元素"写入文本值：`AXUIElementCreateSystemWide → kAXFocusedUIElement → AXUIElementSetAttributeValue(kAXValue)`，若目标不支持 `kAXValue` 则降级写 `kAXSelectedText`（在光标处插入）。
  - 全程**不碰剪贴板** → 不触发 iOS 16 "允许粘贴" 弹窗；不依赖 firstResponder 遍历 / HID 物理键，覆盖更广。
  - 实现用**动态 dlopen** `Accessibility` 私有框架（兼容 iOS16 `PrivateFrameworks` / iOS17+ `Frameworks`），CI 不依赖 SDK 框架路径。
  - `src/trollvncserver.entitlements` 补 `com.apple.private.accessibility.inspection` / `com.apple.private.accessibility.AXPreferenceOverride`。
  - 前置：设备需开启辅助功能访问（设置→辅助功能），且光标停在目标文本区；完全自绘且无 AX 节点的输入框仍可能收不到。

## [3.86] – 2026-07-14

### Added
- **新增 `POST /api/input_hid` —— 面向游戏 / 自定义渲染输入框的文本注入出口**: 之前的文本接口在游戏 App 中全部失效——`/api/input` 依赖 UIKit 焦点（游戏不暴露原生 `UITextField`）、`/api/clipboard_text` 仅写剪贴板不触发粘贴（游戏不自动读）、`/api/key` 只发单键且字符映射会丢中文。
  - 本接口直接调用已有的 `TVNCApiManager.inputTextViaHID:`，底层走 `STHIDEventGenerator` 的 IOHID 键盘事件（`_sendIOHIDKeyboardEvent`），**模拟外接物理键盘、绕过 firstResponder 焦点**：
    - ASCII（英数符号）→ 逐字符 `keyPress:` 注入，任何响应物理键盘的 App（含游戏）均可收到；
    - 非 ASCII（中文等）→ 自动降级为「写剪贴板 + Cmd+V 的 HID 粘贴事件」，同样无需原生输入框焦点。
  - 这是游戏聊天 / 搜索场景目前唯一可用的远程文本输入途径。

## [3.85] – 2026-07-13

### Fixed
- **回退 3.84 引入的死锁回归（"点 app 画面卡死"）**: 3.84 为修双重释放，在 `maybeResizeFramebufferForRotation()` 重建帧缓冲前用 `lockAllClientsBlocking()` 锁住所有客户端的 `sendMutex`。但 `rfbNewFramebuffer()` 在通知客户端尺寸变化时内部会再次 `LOCK(cl->sendMutex)`（`rfbSendNewFBSize → rfbSendUpdateBuf`），同一个**非递归**互斥锁被重复加锁 → **自死锁**，整个守护进程挂起（不崩、画面永久定格）。该死锁只在「有客户端连接且发生 resize」时触发（如跨屏下点开一个会改变方向的 app），与用户报告的 3.84 才出现、之前无问题完全吻合。
  - **修复**: 移除重建路径上的 `lockAllClientsBlocking()`/`unlockAllClientsBlocking()`，回归 3.83 的无锁 resize 行为（libvncserver 发送线程本就不持我们的锁读缓冲，3.83 用户确认无问题）；**双重释放的修法保留**（旧 front 由 `rfbNewFramebuffer()` 内部释放，我们不再二次 `free`，只释放旧 back）。
- **noVNC 网页客户端在 resize 后 `Connection reset` 断连**: 3.84 把 resize 真正"修通"了（3.83 因双重释放会在完成前先崩，尺寸通知从没真正发出去），现在 resize 完成会向客户端下发 `ExtDesktopSize` 伪编码；打包的 noVNC 客户端处理该消息有 bug，收到后即断开 → 网页定格。
  - **修复**: 在 `newClientHook` 对每位客户端设置 `cl->useExtDesktopSize = FALSE`，改为下发标准 `NewFBSize`（`rfbEncodingNewFBSize`，noVNC 可正确处理），尺寸/旋转通知依旧生效。此即还原 3.83 的有效行为。

## [3.84] – 2026-07-13

> ⚠️ **已知问题（本版本引入，已在 3.85 修复）**: 为消除双重释放而加的 `lockAllClientsBlocking()` 会在「有客户端连接时触发 resize」造成服务端**自死锁挂起**（非崩溃、画面卡死）。双重释放的根因分析正确，但「加锁」这一手段是错误的——`rfbNewFramebuffer()` 内部会再锁同一把 `sendMutex`。3.85 已回退该锁并保留双重释放修法。

### Fixed
- **iOS 16 长时投屏服务硬崩溃（EXC_CRASH / SIGABRT，守护进程整体退出）**: 经符号化 25 份崩溃报告定位，根因在 `maybeResizeFramebufferForRotation()`——旋转/缩放触发帧缓冲重建时旧 `gFrontBuffer` 被 `rfbNewFramebuffer()` 和代码各 `free()` 一次，造成**双重释放**，旧 front 被释放两次 → 堆损坏 → 在后续任意 `free()` 被 iOS malloc 守卫 `abort()`。
  - **修复**: 由 `rfbNewFramebuffer()` 独占旧 front 所有权（不再自行 `free`，消除双重释放）；重建期间原拟加锁防止发送线程读已释放缓冲，但加锁方式有误（见上方已知问题），3.85 已改为无锁且安全的重建。

## [3.83] – 2026-07-12

### Fixed
- **iOS 16 长时 noVNC 投屏服务假死**: 长时无人操作投屏时，设备按自动锁定熄屏，CADisplayLink 暂停 → 不再产帧 → 画面定格且监管层（launchd KeepAlive / trollvncmanager TRWatchDog）因进程仍存活而无法自愈。
  - **默认开启防休眠保活**: `gKeepAliveSec` 默认值由 `0.0`（关）改为 `15.0`，在有客户端连接时周期性发送 `ACUnlock` 消费者事件重置 iOS 闲置计时器，使显示保持常亮。仅在 `clients > 0` 时生效，无客户端时设备可正常休眠。
  - **新增帧存活探针（watchdog）**: 在后台 GCD 队列上运行独立定时器，与主线程解耦——即便主线程卡死也能触发。当存在客户端连接且超过 60s 未成功产帧时，主动 `exit(0)` 退出，交由监管层重启（配合默认防休眠，重启后显示唤醒、恢复产帧），将“永久假死”变为“可自愈”。

## [3.84] – 2026-07-13

### Fixed
- **iOS 16 长时投屏服务硬崩溃（EXC_CRASH / SIGABRT，守护进程整体退出）**: 经符号化 25 份崩溃报告定位，根因在 `maybeResizeFramebufferForRotation()`——旋转/缩放触发帧缓冲重建时：
  - **双重释放（double-free）**: `rfbNewFramebuffer()` 内部会 `free()` 旧 `gScreen->frameBuffer`（即旧 `gFrontBuffer`），随后代码又 `free(gFrontBuffer)` 一次，旧 front 被释放两次。
  - **无锁竞态（use-after-free）**: 重建全程未持任何客户端锁，而 libvncserver 的 VNC 发送线程正并发读取 `gScreen->frameBuffer` / `gWidth` / `gHeight`，旧缓冲被释放瞬间发送线程仍在读 → 堆损坏，随后在任意一次 `free()`（如 `rfbCloseClient` 的 Tight 编码 `free()` 路径）被 iOS malloc 守卫捕获并 `abort()`，整个守护进程被带走。
  - **修复**: 重建前 `lockAllClientsBlocking()` 锁住所有客户端发送锁，使重建期间无任何发送进行；由 `rfbNewFramebuffer()` 独占旧 front 的所有权（不再自行 `free`，消除双重释放）；在持锁期间原子更新尺寸与指针；释放旧 back 缓冲延后到解锁之后。此修复从根上消除堆损坏，25 份 `EXC_CRASH` 崩溃类（21 份 Tight 路径 + 4 份其他）不再触发。
- **韧性兜底**: 仓库 `layout/Library/LaunchDaemons/com.82flex.trollvnc.plist` 已含 `KeepAlive=true` + `RunAtLoad=true`，在越狱/root 环境由 launchd 加载后，守护进程崩溃会自动重启（无需 `trollvncmanager` 介入）。

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
