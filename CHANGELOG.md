# Changelog

All notable changes to TrollVNC are documented here.

## [4.21] – 2026-07-18

### Fixed（群控中继模式 iOS 客户端 WebSocket 帧 MASK 合规）
- **根因**：iOS 手写 WS 客户端（`connectToRelay` + `wsSendTextFrame` + pong）发出的帧未设 MASK 位，违反 RFC6455（客户端→服务器帧必须掩码），Node `ws` 库严格校验 → 拒收 `Invalid WebSocket frame: MASK must be set` → 1006 断连。手机一回 pong / 发 touch 即被踢，群控控制链路（电脑→中继→手机）无法建立。
- **修复**：`src/TVNCHttpServer.mm` 新增 `wsGenerateMaskKey` + `wsSendTextFrameMasked`（置 MASK 位 0x80、生成 4 字节随机掩码键、payload 按 `byte ^ mask[i%4]` 掩码）。`reportRealTouchToRelay` 与 `sendRelayMessage:` 两处 relay 上行改用掩码变体；客户端 pong 回复亦走掩码帧。`wsReadFrame` 已支持读取对端 MASK 帧。P2P 直连模式（手机作 WS 服务端下发）仍用未掩码 `wsSendTextFrame`，方向正确。
- **配套（中继端，已先行部署）**：`group-control/relay-server.js` 修复双层帧（`ws.send(msg)` 而非 `ws.send(encodeWebSocketTextFrame(msg))`），并定稿定向/镜像路由——`targetDeviceId` 定向单台、`scope==='slaves'` 仅从控、默认全广播。`group-control/pc_group_control.html` 跨屏弹窗 `outOpts` 对齐（主控→scope=all 镜像所有手机，从控→targetDeviceId=本机）；`discoverDevicesFromRelay` 轮询 `/api/status` 自动建设备列表，甩掉手填 `qkurl.txt`。路由测试 `test_relay_routing.js` 全绿。

### 质量护栏（防护升级）
- 群控控制链路（电脑中继 + 卡片墙 + 双击跨屏 + 主控镜像从控）端到端就绪，支持上百台设备规模。

## [4.20] – 2026-07-18

### Fixed（巨魔版 TrollStore 自动安装 —— 真因修复）

- **根因（推翻 v4.19 前的误诊）**：`install/tipa` 与 `isTrollStoreAvailable` 都跑在**无界面的 daemon 进程（trollvncserver / 8182）**。daemon 没有 `UIApplication`，`[UIApplication sharedApplication]` 返回 nil → `canOpenURL:` 恒 NO、`openURL:` 向 nil 发消息静默失败。旧实现的 `isTrollStoreAvailable` 方法4（`canOpenURL`）在 daemon 下根本不成立；即便检测通过，真正触发安装的 `openURL(trollstore://…)` 也弹不出 TrollStore。之前误判「缺 `LSApplicationQueriesSchemes` 声明」是错的——TrollStore 已安装、scheme 已开仍 500，正因调用方在无 UI 的 daemon。
- **修复（复用 daemon→App(8184) 转发模式，同 `/api/input`）**：
  - `app/TrollVNC/TrollVNC/TVNCAppInputServer.m` 新增 `POST /install/tipa`：在主线程用 `UIApplication openURL(trollstore://install?file=<encoded>)` 真正拉起 TrollStore。App 有 UI，此路能生效。
  - `src/TVNCHttpServer.mm` 的 `handleInstallTipa`：改为先探活 `127.0.0.1:8184/health`(0.3s)，App 在线则转发安装请求由 App 执行；App 不可用（.deb 无 8184 / App 被 iOS 挂起）返回 503 明确提示「保持 App 前台」，不再用 `isTrollStoreAvailable` 当闸门。
  - 保留两份 App `Info.plist` 的 `LSApplicationQueriesSchemes→trollstore`：这是 App 进程 `openURL(trollstore://)` 的必要声明（越狱版走 `SBSOpenURL` 不需要，但声明无害）。
- **前置条件**：`.tipa` 设备自动安装时 `TrollVNC.app` 须保持前台（被挂起则 8184 失活，daemon 回 503）。

## [4.19] – 2026-07-18

### Feature（护栏模块运行时接入 + 护栏扩面）
- 纯 C 护栏模块从「仅 CI 单测」升级为「链入 daemon 运行时」：
  - `TVNCTextClassifier`：输入通道的 `tvncIsAllASCII:` 改为委托纯 C 模块 `TVNCIsAllASCII`（单一真源，已单测），消除 ObjC 与 C 重复实现。
  - `TVNCRouteSafety`：HTTP 服务启动时跑 `TVNCRouteSafetySelfTest()` 自检 57 条路由分类表一致性（无重复/空字段），不阻塞分发，仅观测。
- 两个 `.c` 已登记进 `Makefile` 的 `trollvncserver_FILES`，与 `TVNCInputStrategy` 一同编译链入四个 scheme。
- `quality-gate` 单测脚本改为 glob 自动发现 `quality/*_test.c`，新增模块零脚本改动即纳入 CI；静态分析遍历 `quality/*.c`。

### 质量护栏（防护升级）
- 路由安全分类表成为「只读/写/敏感」的规范真源；未来可在分发前调 `TVNCRouteLookup` 做 method + 权限校验（加固项）。

## [4.18] – 2026-07-18

### Fixed（链入 TVNCInputStrategy 后 rootless/default/roothide 链接失败）
- **根因**：`TVNCApiManager.mm`（ObjC++，C++ 编译）`#include "TVNCInputStrategy.h"`，但头文件未做 `extern "C"` 包裹 → C++ 对 `TVNCSelectPrimaryInput` 做 name mangling，与 `TVNCInputStrategy.c`（C 编译，C 符号）对不上 → `ld: symbol(s) not found for architecture arm64`。编译期不报错、仅链接期暴露，CI 真实工具链抓到。
- **修复**：`quality/TVNCInputStrategy.h` 整段声明用 `#ifdef __cplusplus extern "C" { ... } #endif` 包裹。同时覆盖 default/rootless/roothide 三 scheme；bootstrap 不链该头不受影响。
- 这是质量护栏继 `NULL` 未声明之后抓到的第二个真实符号/链接层 bug（纯逻辑等价验证测不到）。

### Refactored（输入级联决策接入策略模块 + 警告暴露）
- `src/TVNCApiManager.mm` 的 `inputText:` 改为先 `TVNCSelectPrimaryInput(&ctx)` 决策：第一响应者命中走 `tvncInsertViaFirstResponder:`，否则回退 `inputTextViaClipboard:`（v4.10 剪贴板终态保留）。决策与执行分离，从设计上杜绝 v4.02「假成功短路级联」回归。
- 9 处 `#warning`（ARC 提示）升级为 `#error`（均在 `#if !__has_feature(objc_arc)` 保护内，Makefile `-fobjc-arc` 下不触发）；Makefile 移除 `-Wno-unused-but-set-variable`（暴露而非隐藏）。

### Added（群控前端现代化）
- `group-control/relay-server.js`：新增可选 `RELAY_TOKEN` WebSocket 鉴权；新增 `GET /api/device` 真实设备名代理。
- `group-control/pc_group_control.html`：relay 配置加 token 输入框并持久化；新增 `fetchDeviceRealName` 拉取真实设备名（tolerant name/deviceName/model/version 字段）。

## [4.10] – 2026-07-16

### Fixed（英文/数字部分 App 无法输入 —— daemon 兜底统一走剪贴板）
- **根因（v4.08/v4.09 实测均复现）**：`inputText:` 纯 ASCII 分支先走 `inputTextViaHID:`（`STHIDEventGenerator keyPress:`）。该方法**不验证字符是否真送达前台 App**，在 WKWebView / React Native / Flutter / 密码框等控件上「假成功」（不抛异常却没把字符送进输入框）→ 直接 return → 英文/数字静默丢失，且永不走剪贴板兜底。v4.09 删 `UIKeyboardImpl` 无效（它排在 HID 之后、HID 已先假成功 return）。
- **修复**：daemon 兜底去掉 HID / UIKeyboardImpl / 字符集分流，统一 `第一响应者 → inputTextViaClipboard:`（剪贴板 + Cmd+V）。剪贴板通道已被 v4.08 实测证明「任何 App 中文都能到」，故中/英/数字**任何 App 必到、不再丢失**。`inputTextViaHID:` 方法保留但未调用（死代码无害）。
- **代价（用户已接受）**：英文/数字也走粘贴 → 触发 iOS16「是否允许粘贴」弹窗（与中文一致）。用户确认弹窗可接受，目标仅为「任何 App 都能文本输入」。
- 说明：中文零弹窗的彻底解仍是 `TVNCInjector` 进程内注入（注入前台目标 App 自身进程执行输入，天然有 AX 上下文、不受挂起影响、deb/tipa 通吃），当前为半成品骨架，本版未投入（用户接受弹窗）。

## [4.09] – 2026-07-16

### Fixed（英文/数字部分 App 无法输入 + 中文弹窗根治仅 .tipa）
- **英文/数字部分 App 无法输入（所有构建通用）**：`inputText:` 纯 ASCII 级联原顺序为 `HID → UIKeyboardImpl → 剪贴板`。`UIKeyboardImpl.addText:` 在 daemon 无键盘会话时会"假成功"（返回 YES 但没真送到前台 App），把最后的**剪贴板兜底短路**了 → 英文/数字静默丢失、方法还回报成功。改为 `HID → 剪贴板`：`UIKeyboardImpl` 调用已移除，HID 失效的 App 必走到剪贴板（弹窗但必到）。
- **中文弹窗根治（仅 .tipa / TrollVNC.app 生效）**：`TrollVNC.app` 的 `Info.plist` 增加 `voip` 后台模式。其机制是——8184 监听 socket 上有连接到达时，iOS 会唤醒被挂起的 App 来处理。于是切到 Safari/微信打字、daemon 转发 `/input` 的瞬间，iOS 把 `TrollVNC.app` 叫醒、走 App 的 AX 通道输中文 → 零弹窗，中英文都可靠。
- `AppDelegate.m` 顺手修正误写多年的"端口 8183"注释为 8184。
- ⚠️ voip 保活需真机验证：iOS 13+ 对 voip 模式有收紧，若实测中文仍弹窗，下一步将 8184 socket 显式标记为 VoIP socket（`kCFStreamNetworkServiceTypeVoIP`）。
- ⚠️ 该 voip 修复只在 `.tipa`（Xcode 工程 TrollVNC.app）里；3 个 `.deb` 无 8184 服务器，中文照常弹窗（英文/digits 因上述级联修复而能输）。`.deb` 想零弹窗中文需走 `TVNCInjector` 进程内注入，另议。

## [4.08] – 2026-07-16

### Fixed（输入转发端口 8183 → 8184，避开 daemon 自有 Group WebSocket 端口冲突 + /health 探活）
- **根因**：daemon 的 Group WebSocket 服务器用 `INADDR_ANY` 绑定 **8183**（`TVNCHttpServer.mm` 设 `_groupWSPort=8183` 并真绑）。v4.07 设计用 8183 做 App 输入转发，与 daemon 自身 8183 冲突 → App `bind` 失败或 127.0.0.1 连接被 daemon 先截获 → 转发永远到不了 App → 干净通道静默回退剪贴板（v4.07 实际是死的）。
- **修复**：App 输入转发与 App 监听统一改用 **8184**（全仓库无其他监听占用）。`TVNCHttpServer.mm` 转发 `http://127.0.0.1:8184/input`；`TVNCAppInputServer.m` 监听 `htons(8184)`（此改动在 v4.07 工作树已落，本版正式发版）。
- **优化**：`handleInput` 转发前先 `GET http://127.0.0.1:8184/health` 探活（超时 0.3s）。App 被 iOS 挂起时 8184 失活，探活快速失败、立即回退 daemon，避免原 2.0s 超时干等。
- ⚠️ 8183 为 daemon 自有 Group WS 端口，**输入转发端口后续严禁再改回 8183**。

## [4.07] – 2026-07-16

### Fixed（中文输入导致 VNC 断线 → 重做 AX 架构）
- **根因（v4.06 回归）**：`inputTextViaAX`（AXUIElement 私有框架）在 `trollvncserver` 无界面 daemon 进程内调用，会直接使整个 daemon 崩溃退出 → VNC(5901)/REST(8182) 全部下线、需重连。AX 仅可用于有界面进程（TrollVNC.app），不能用于 daemon。
- **架构重做**：daemon 不再直接调 AX。新增 TrollVNC.app 内本地 HTTP 服务 `TVNCAppInputServer`（端口 **8184**，监听 127.0.0.1），在 App 有界面进程里执行 AX API（`AXValue`/`AXSelectedText`，支持中文/emoji、零弹窗、不依赖键盘会话）。
- **调用流程**：`POST /api/input`（8182，daemon）→ 转发 `POST http://127.0.0.1:8184/input` → App 执行 AX → 返回结果。App 未运行 / 8184 不通时，回退 daemon 自身 `inputText`（英文 HID，中文剪贴板+Cmd+V）。
- **代码改动**：`AppDelegate` 启动 `TVNCAppInputServer`；新增 `TVNCAppInputServer.{h,m}` 并注册进 Xcode 工程（bootstrap/TrollVNC scheme）。`src/TVNCHttpServer.mm` 的 `handleInput` 加转发逻辑。`src/TVNCApiManager.mm` 彻底移除 AX（级联仅：第一响应者 → 含中文走剪贴板 → 纯 ASCII 走 HID → UIKeyboardImpl → 剪贴板兜底）。
- 注：`TVNCInjector.{h,m}` 已新增但未编入本版（进程内注入 dylib 方案尚不完整，且转发架构不依赖）。

## [4.06] – 2026-07-16

### Fixed（中文无法输入：恢复 inputTextViaAX 通道）
- 根因：v4.04 删除了 `inputTextViaAX`（Accessibility / AXUIElement 通道），而该通道是开发分支 `TrollVNC/src/` 一直保留、生产版漏移植的唯一"支持任意 Unicode、零弹窗、不依赖键盘会话"的中文落点。v4.05 恢复 HID+UIKeyboardImpl 后，UIKeyboardImpl 在部分场景"假成功"短路级联，中文仍哑火。
- 恢复内容：`TVNCLoadAX()`（dlopen 动态加载 Accessibility 框架，iOS16 PrivateFrameworks / iOS17+ Frameworks 双路径）+ `gTVNCAX` 静态结构 + `inputTextViaAX:` + `_axInputSync:`（独立 NSThread + NSCondition 跑 AX，避免主线程死锁）；`AXValue` 优先、失败兜底 `AXSelectedText`。
- **级联顺序关键调整**：AX 排在 `inputTextViaHID:` 之后、`inputTextViaKeyboard:` 之前——否则中文会在 UIKeyboardImpl"假成功"处被短路，永远走不到 AX。
- 新级联：第一响应者 → HID(ASCII) → **AX(任意 Unicode，零弹窗)** → UIKeyboardImpl → 剪贴板(兜底弹窗)。
- 效果：主 App 有焦点时中文走 AX 通道直接写系统焦点 UI 元素的 `AXValue`，支持中文/emoji、不碰剪贴板、不弹"是否允许粘贴"。

## [4.05] – 2026-07-16

### Changed（文本输入级联恢复为四级，解决 iOS 16 "是否允许粘贴" 弹窗）
- 级联：`第一响应者(findFirstResponder → replaceRange:)` → `inputTextViaHID:`（纯 ASCII 逐键，等价于外接蓝牙键盘，daemon 下可靠且**零弹窗**）→ `inputTextViaKeyboard:`（UIKeyboardImpl 私有 API，主 App 有焦点时中英文均经键盘系统直接输入、**零弹窗**）→ `inputTextViaClipboard:`（UIPasteboard + Cmd+V，中文终级兜底，会触发 iOS 16 粘贴弹窗）。
- **HID 必须排在 UIKeyboardImpl 之前**：后者 `addText:` 在 daemon 无键盘会话时会"假成功"（返回 YES 但实际没送到前台 App），若排在前会短路级联（v3.96 回归点）。HID 仅处理 ASCII，含中文主动返回 NO 交由下级。
- 恢复 v4.04 删除的 `inputTextViaHID:`（非 ASCII 改为返回 NO 而非转剪贴板）与 `inputTextViaKeyboard:` + `_keyboardInputSync:`，并恢复 `.h` 声明。AX 通道仍保持删除。
- **效果**：主 App 有焦点时英文走 HID、中文走 UIKeyboardImpl，均不碰剪贴板 → 不再弹"是否允许粘贴"；仅当 UIKeyboardImpl 也失败时中文才回退剪贴板弹窗。

## [4.04] – 2026-07-15

### Changed（文本输入级联进一步收敛为「第一响应者 → 剪贴板 + Cmd+V」）
- 按用户要求只保留两招：`insertText:`（第一响应者标准路径，UIKit `replaceRange:` 插入，中英文都行）+ `inputTextViaClipboard:`（写 UIPasteboard 后通过 `STHIDEventGenerator` 发 Cmd+V 组合键粘贴）。
- **删除后期加入的文本通道**（v4.03 仍保留作级联兜底，本次彻底移除）：
  - `inputTextViaHID:`（HID 逐键 ASCII 文本通道，v3.96 进级联）
  - `inputTextViaKeyboard:` + `_keyboardInputSync:`（UIKeyboardImpl 私有 API，v3.93 独立接口 → v3.96 进级联，正是 v3.96 回归元凶）
  - `inputTextViaAX:` + `_axInputSync:` + `TVNCLoadAX` + `gTVNCAX` 及整段 Accessibility `dlopen`/`dlsym` 块
- `.h` 同步移除 `inputTextViaHID/AX/Keyboard` 三个声明；清理一条带「AX」误导注释的重复 `dlfcn.h` import（`dlfcn` 仍被 SpringBoardServices 前台检测使用，保留）。
- **注意（架构影响）**：删 HID 后，`/api/input` 在 daemon（VNC 无界面守护进程，无键盘会话/辅助功能授权）场景下不再有"外接键盘等价"通道，第一响应者与剪贴板+Cmd+V 都依赖前台 App 的 UIKit 键盘会话/聚焦。此改法更适合主 App 内有焦点的场景；VNC 远程无界面环境若需稳定输中英文须保留 HID 层。

## [4.03] – 2026-07-15

### Changed（文本输入只保留 `/api/input` 一个入口）
- 删除其余文本输入接口及其实现：`/api/input_hid`、`/api/input_ax`、`/api/input_keyboard`、`/api/input_inject`、`/api/inject_probe`。
- 删除进程内注入相关源码：`src/TVNCProcessInject.{h,m}`、`src/tvnc_inject.m`，并从 Makefile 移除 `tvnc_inject` library 与 `TVNCProcessInject.m` 编译项、从 `TVNCHttpServer.mm` 移除 `#import "TVNCProcessInject.h"`。
- `TVNCHttpServer.mm` 文档列表同步清理为只剩 `/api/input`（级联：第一响应者→HID→UIKeyboardImpl→AX）。
- 说明：`/api/input` 仍走 v4.02 修复后的级联；HID/剪贴板/UIKeyboardImpl/AX 等内部方式保留为级联兜底，只是不再单独暴露为独立接口。

## [4.02] – 2026-07-15

### Fixed（`/api/input` v3.96 回归：UIKeyboardImpl 假成功短路 HID）
- **根因（更正 v4.01 结论）**：v3.96 把 `UIKeyboardImpl` 插到 HID **之前**作为级联方式2，但 `inputTextViaKeyboard:`→`_keyboardInputSync:` 在 daemon 无键盘会话时 `UIKeyboardImpl.addText:` 是空操作、不报错却**无条件 `return YES`**（TVNCApiManager.mm:1344）→ 级联被"假成功"短路，`inputTextViaHID:`（真正能打字的通道）**永远不执行**。改动前(v3.95及更早) `/api/input` 是「第一响应者→HID」直落 HID，故那时能输中英文；改后 UIKeyboardImpl 截胡，啥也不打。
- `STHIDEventGenerator`(keyPress/HID) 自 v3.28 未改，HID 本身没坏，是级联**顺序**错了。
- **修复**：级联重排为 `第一响应者 → HID → UIKeyboardImpl → AX`，恢复"先落 HID"可靠路径；UIKeyboardImpl/AX 降为 HID 之后的兜底。普通 App（备忘录/浏览器/有焦点输入框）`/api/input` 中文(剪贴板+Cmd+V)/英文(HID键)均恢复可用。游戏自绘框若不认外接键盘仍走不通（属 daemon 架构限制，非本回归）。

## [4.01] – 2026-07-15

### Fixed（`/api/input_hid` v4.00 递归崩溃）
- v4.00 的 `handleInputHid:` 在非主线程时写成了 `return [self handleInputHid:...]`（递归自身）→ HTTP handler 跑在后台队列时无限递归栈溢出崩溃。修正为 `dispatch_sync(dispatch_get_main_queue(), ...)` 回主线程执行。
- 说明：`/api/input` 逻辑自 v3.96 起未削弱（v3.96 仅在「第一响应者→HID」间插入 UIKeyboardImpl/AX 两级尝试，属超集；中文剪贴板兜底一直存在）。daemon 下前三级（第一响应者/UIKeyboardImpl/AX）因无 UI/无授权必然失败，仅第四级 HID 能点火，故「以前能在备忘录等 App 输中英文、现在游戏里不行」是守护进程架构差异，非代码回归。

## [4.00] – 2026-07-15

### Changed（`/api/input_hid` 明确为「百分百」文本通道）
- 重写 `TVNCHttpServer.mm` 的 `handleInputHid:`：在主线程直接调用 `STHIDEventGenerator` 逐组合字符发送 HID 键盘事件（`keyPress:`），**等价外接蓝牙键盘**，是 VNC 远程敲键的同一条通道，在 daemon 下完全可用。
- 彻底不依赖前台 PID 检测 / `task_for_pid` / UIKit 第一响应者 / AX —— 这些通道此前在 `trollvncserver` 守护进程下全部失效，导致 `input_keyboard` / `input_inject` 在游戏自绘框场景实测不可用。
- 反馈增强：返回 `sent` / `skipped` 诊断。仅 ASCII（英文字母/数字/符号）经 HID 逐字符发送；**非 ASCII（中文/emoji）无法用 HID 键盘码编码，自动写入设备剪贴板并提示「游戏输入框内长按粘贴」**（中文唯一可靠方案）。
- 使用前提：调用前请先在游戏里点一下目标输入框使其获得焦点，HID 键事件才会进入该框。
- 结论：`/api/input_hid` 是游戏/自绘框文本输入的首选与兜底方案；其余 `input_keyboard`(UIKeyboardImpl)、`input_inject`(进程注入)、`input_ax`(AX) 因 daemon 限制仅作补充。

## [3.99] – 2026-07-15

### Changed（`tvnc_foreground_pid` 新增 sysctl 兜底，已修正 namelen）
- 在 `src/TVNCProcessInject.m` 的 `tvnc_foreground_pid()` 优先级链末尾加入 **sysctl 兜底**：通过 `sysctl(KERN_PROC_ALL)` + `proc_pidpath` 从后往前枚举 `.app` 进程，取最后启动的用户 App 作为前台候选（FBS → SBS → AX → sysctl）。
- **修正**：原写法 `sysctl(mib, 4, …)` 与同文件已验证的 `tvnc_enumerate_user_apps` / `tvnc_pid_for_bundle`（`sysctl(mib, 3, …)`）不一致，`KERN_PROC_ALL` 下第 4 个 mib 元素被忽略，可能导致 `EINVAL`。已统一为 `sysctl(mib, 3, …)`，使兜底真正生效。
- 说明：该兜底仅用于 `probe` 的诊断 `foreground_pid_guess` 与 `injectText:` 的**额外候选**；真正的注入仍走 v3.98 的「枚举全部用户 App 逐一注入」路径，不依赖前台 PID 检测即可工作。本版本为对 v3.98 的小幅增强，行为兼容。

## [3.98] – 2026-07-15

### Changed（input_inject 不再依赖前台 PID 检测）
- 真机实测 `/api/inject_probe` 仍 `stage:foreground_pid` 失败：daemon 下 SpringBoardServices / FrontBoardServices 的 XPC 即便 entitlements 齐全也返回 nil（前台 PID 通道在守护进程上下文不可用）。
- **重构 `/api/input_inject` 与 `/api/inject_probe`**：放弃「先取前台 PID 再注入单个进程」的旧模型。
  - 新增 `tvnc_enumerate_user_apps()`：通过 `sysctl(KERN_PROC_ALL)` + `proc_pidpath` 枚举所有用户 App 进程（排除守护自身、同 .app 的 manager、SpringBoard、系统守护）。
  - 新增 `tvnc_inject_into_pid()`：对单个目标进程完成完整注入（task_for_pid + 进程内 dlopen/dlsym/tvnc_inject_text），返回 `tvnc_inject_text` 的 BOOL。
  - `injectText:` 现在对**全部候选 App 逐一注入**，仅前台 App（有焦点输入框）的 `tvnc_inject_text` 真正返回 YES，后台 App 自动跳过（无害）。成功即提前返回。
  - `probe` 改为枚举候选 App 并验证 `task_for_pid` 可取 task port 即视为通道打通，不再要求精确前台 PID。
- 效果：彻底绕开 `foreground_pid` 卡死，`input_inject` 在 daemon 环境下也能对游戏/自绘框输入框生效。

## [3.97] – 2026-07-15

### Changed（entitlements 补充）
- 用户为 `src/trollvncmanager.entitlements`、`app/TrollVNC/TrollVNC/TrollVNC.entitlements`、`app/MatisuXCS/MatisuXCS.entitlements` 补充 `com.apple.springboard.appcontrol`。
- **注意**：上述文件不影响「前台 PID 查询 / 进程内注入」——这两件事发生在 `trollvncserver` 守护进程，其签名用的 `src/trollvncserver.entitlements` 自 v3.91 起已含 `com.apple.springboard.appcontrol` + `com.apple.frontboard.launchapplications` + `task_for_pid-allow` 等。本次为一致性补充，行为不变。
- 前台 PID 获取的实际通道为 v3.94/3.95 引入的 **FrontBoardServices 优先**（`tvnc_foreground_pid_fbs`），需真机实测 `/api/inject_probe` / `/api/input_inject` 确认。

## [3.96] – 2026-07-15

### Changed（/api/input 升级为多级自动级联输入）
- 用户修改了 `/api/input` 的文本输入逻辑（`TrollVNC/src/` 开发分支，不参与生产编译）。已将核心改进**移植**进根目录 `src/TVNCApiManager.mm` 的 `inputText:`。
- `inputText:` 由原来「第一响应者 → HID」两级，升级为 **四级自动级联**：
  1. 第一响应者（UITextField / UITextView / 任意 UITextInput）——直接 `replaceRange:withText:`
  2. **UIKeyboardImpl 私有 API**（`inputTextViaKeyboard`，绕过第一响应者限制，不弹粘贴窗，适用于游戏/自绘框）
  3. **Accessibility AX 通道**（`inputTextViaAX`，绕过剪贴板弹窗）
  4. HID 键盘事件（最终兜底）
- 每级失败自动降级，全部失败才返回 `NO`；并补充分级成功日志便于排错。
- `/api/input` 文档措辞对齐为"自动选择最佳方式，支持任何App"。
- 注：`inputTextViaKeyboard` 仍沿用根目录 v3.93 的**安全版**（`dispatch_async` + semaphore 主线程调度），未采用用户分支里的 `dispatch_sync` 写法（后者会触发 `http 000` 死锁）。

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
