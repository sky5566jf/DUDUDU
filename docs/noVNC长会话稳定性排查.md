# noVNC 长时投屏稳定性排查（iOS 16）

> 排查目标：iOS 16 下长时间 noVNC 投屏，整个服务是否会“挂掉”。
> 结论：**存在真实风险**，且 iOS 16 下更明显。最主要的表现不是“进程崩溃退出”，而是“进程还活着但画面冻结/无响应”，外部 watchdog 无法触发重启，体验上就是“服务挂了”。

---

## 一、服务存活模型（关键前提）

- `trollvncserver`（真正干活的服务）由两层监管：
  1. `launchd` plist：`KeepAlive=true` + `RunAtLoad=true`（`layout/Library/LaunchDaemons/com.82flex.trollvnc.plist:24-25`）。
  2. `trollvncmanager` 内的 `TRWatchDog`：`setKeepAlive:@YES`（`src/trollvncmanager.mm:338`）。
- **两层都只在「子进程退出」时重启**（`TRWatchDog.mm` 的 `_handleTaskTermination:906-988` 仅在 `state==Running` 且非正常退出时触发；launchd 同理）。
- **没有任何“存活但卡死”的探针**：没有心跳 / liveness / 帧率自检定时器。一旦主线程卡住或画面停止产出，进程依然“活着”，无人重启。

> 这是“长时投屏挂掉却无法自愈”的根本制度性原因。

---

## 二、具体风险点（按可能性/危害排序）

### 风险 1（最高）：设备休眠 → `CADisplayLink` 停摆 → 画面冻结，永不自愈
- 抓取由 `CADisplayLink` 驱动：`ScreenCapturer.mm:333-377`（`startCaptureWithFrameHandler`）把 displayLink 加到主 runloop；`onDisplayLink:` 每次 vsync 触发抓取（`ScreenCapturer.mm:462-509`）。
- `CADisplayLink` 只在**屏幕亮着且系统在 vsync** 时触发。iOS 长时无人操作会按系统“自动锁定”超时进入休眠，**一旦屏幕熄灭，vsync 停止，displayLink 不再回调** → 不再产生帧 → noVNC 客户端停在最后一帧（黑屏/定格）。
- 此时 service 进程完全正常存活 → launchd / watchdog 都不重启 → **用户看到的就是“服务挂了”，且无法自动恢复**。
- 休眠还会联动：`isWiFiConnected()` / `triggerWiFiReconnect()`（`trollvncserver.mm:156-191`）仅用于断网重连，但没有周期性心跳去“保持设备唤醒”。
- `KeepAlive`（防休眠输入）默认 **关闭**：`gKeepAliveSec` 默认 `0.0`（`trollvncserver.mm:87`），只有用户在偏好里显式开启且 `>0` 时才会在有客户端时发唤醒事件（`trollvncserver.mm:4349-4352`）。

**iOS 16 相关性**：iOS 16 对后台/无前台 App 的 daemon 的显示与功耗管理更激进，屏幕更容易进入低功耗/锁定；且 iOS 16 的“屏幕变暗→锁定”默认间隔短，长时无人值守投屏几乎必然触发。

### 风险 2：`CARenderServerGetDirtyFrameCount` 的脏帧检测会“吃掉”真实更新
- `renderDisplayToScreenSurface` 用静态 `sDirtyFrameCount` 判脏（`ScreenCapturer.mm:167, 199-207`）：
  ```objc
  CFIndex dirtyFrameCount = CARenderServerGetDirtyFrameCount(NULL);
  if (dirtyFrameCount == sDirtyFrameCount) return NO; // 视为无变化
  sDirtyFrameCount = dirtyFrameCount;
  ```
- 若渲染服务在休眠/唤醒、旋转、或某些系统事件后**重置或暂停止该计数器**，会出现“内容变了但计数没变”→ 返回 NO → 不抓帧。与风险 1 叠加，进一步固化“冻结”现象。
- （计数器本身是 64 位，长期自增不会溢出，不是溢出问题。）

### 风险 3：主线程事件循环卡死 = 永久假死，无自愈
- VNC 服务运行在 `rfbRunEventLoop(gScreen, …)`（主线程，`trollvncserver.mm:5146`）。
- 若某客户端编码路径或客户端互斥锁（`lockAllClientsBlocking` / `tryLockAllClients`，如 `handleFramebuffer:2608-2611`、`2649-2652`）发生死锁，或 LibVNCServer 内部 websockify 代理阻塞，主线程会一直卡住：既不产帧、也不 accept、也不响应信号。
- 因进程未退出，监管层不重启 → 永久假死。风险 1 的“冻结”还可能靠用户唤醒设备恢复；这种“卡死”连唤醒都救不回来。

### 风险 4：iOS 16 的 Jetsam 压力 + 当前豁免策略
- `OhMyJetsam.mm` 在启动时把进程设为 `JETSAM_PRIORITY_CRITICAL`、关闭 freeze、设 task limit `0x400`（1024 MB）、并 `SET_PROCESS_IS_MANAGED=0`（`OhMyJetsam.mm:36-68`）。
- 这套“关键进程”豁免在 iOS 16 的 RunningBoard/Jetsam 体系下：
  - `MANAGED=0`（非托管）意味着**不享受 freeze 保护**，在整机内存压力下仍会被纳入标准 jetsam 评估；
  - 一旦真实常驻内存超过 1024MB 上限（长会话中若存在缓慢增长：例如客户端反复连/断后残留的 socket/状态、LibVNCServer websockify 未清理的空闲 web socket、或调试日志堆积），会被直接 kill。
- 优点：被 kill 后会**自动重启**（风险 1/2/3 不会重启，这点反而“安全”）。
- 隐患：若崩溃是「长会话到达某一时间点必然触发」的确定性 bug（如某计数器/状态机在 N 小时后进入非法分支），会变成 **5 秒一次的重启抖动**（`ThrottleInterval=5`，`trollvncmanager.mm:337`），用户看到“一直连不上/反复闪退”。

### 风险 5：noVNC websockify 长空闲链路无保活
- 浏览器 → `:5801/websockify`（LibVNCServer 内置代理）→ `:5901` VNC。
- 该代理链路未看到显式的 TCP `SO_KEEPALIVE` / WebSocket ping-pong 健康检测（`TVNCHttpServer.mm` 的群控 WS 有 ping 处理，但 VNC 这条是 LibVNCServer 内置的，无应用层心跳）。
- 长会话中若发生静默网络中断（WiFi 瞬断、路由器 NAT 表老化），会出现“浏览器侧 socket 还开着、VNC 侧已断”或反之的半开状态，客户端表现为画面卡死/掉线，需手动刷新。

---

## 三、为什么“会挂”且“挂了不恢复”（本质）

| 现象 | 根因 | 能否自愈 |
|------|------|----------|
| 画面定格、不能控制 | 风险 1/2：屏幕休眠使 displayLink 停摆，脏帧检测误判 | **不能**（进程存活，监管不重启） |
| 完全无响应（连不上） | 风险 3：主线程事件循环卡死 | **不能** |
| 进程消失后过几秒又来 | 风险 4：Jetsam 杀掉 + 自动重启（或确定性崩溃抖动） | 能，但反复 |
| 连着连着掉线 | 风险 5：空闲链路无保活，半开连接 | 需手动刷新 |

---

## 四、建议的修复方向（按优先级）

1. **设备唤醒保活默认开启 & 长会话兜底**：默认启用 `KeepAlive`（如 `gKeepAliveSec` 默认给一个合理值，如 30s），并在没有用户偏好时也让投屏期间保持设备不休眠；或捕获到 displayLink 长时间未回调时主动 `notify_post`/发唤醒事件。
2. **加一个“存活探针”自愈**：在 `trollvncserver` 内起一个周期性定时器（如每 5–10s），检测“距上次成功产帧是否超过阈值”；若超时则主动 `CFRunLoopStop` / `exit` 让监管层重启，或重新 `invalidate`+重建 displayLink。这是让风险 1/3 也能自愈的关键。
3. **脏帧检测加兜底**：`sDirtyFrameCount` 在 `==` 之外，增加“超过 N 秒无产出则强制产一帧”的超时强制刷新，避免风险 2 的误判冻结。
4. **VNC/websockify 链路加 TCP keepalive**（`SO_KEEPALIVE` + `TCP_KEEPIDLE/INTVL`）以及时清理半开连接（风险 5）。
5. **Jetsam 策略复核**：确认 1024MB task limit 在目标机型足够；对“长会话内存增长”做一次 Instrument/日志级排查（重点：客户端反复连断、日志文件无限增长）。

---

## 五、代码位置索引

- 抓取/displayLink：`src/ScreenCapturer.mm:333-377, 462-509`
- 脏帧判脏：`src/ScreenCapturer.mm:167, 199-207`
- 每帧处理热路径：`src/trollvncserver.mm:2338`（`handleFramebuffer`），客户端互斥：`2608-2611, 2649-2652`
- VNC 主循环：`src/trollvncserver.mm:5146`
- KeepAlive 默认开启（v3.83 起）：`src/trollvncserver.mm:87, 4349-4352`
- 帧存活探针（v3.83 新增）：`src/trollvncserver.mm:5116-5144`（函数）+ `5157`（安装点）+ `2343`（时间戳写入）
- 监管（仅退出才重启）：`src/trollvncmanager.mm:338, 906-988`；`src/TRWatchDog.mm:_handleTaskTermination`
- launchd：`layout/Library/LaunchDaemons/com.82flex.trollvnc.plist:24-25`
- Jetsam 豁免：`src/OhMyJetsam.mm:36-68`

---

## 六、修复状态（已实现于 v3.83）

针对“一、制度性原因”与“二、风险点 1/3”采用最小改动、低风险方案，已落地：

1. **默认开启防休眠保活**（Fix 1）
   - `src/trollvncserver.mm:87`：`gKeepAliveSec` 默认 `0.0` → `15.0`。
   - 机制：有客户端连接时，周期性发送 `kHIDUsage_Csmr_ACUnlock` 消费者事件（`STHIDEventGenerator.mm:1646 hardwareUnlock`），重置 iOS 闲置计时器、保持显示常亮。
   - 仅在 `gClientCount > 0` 时激活（`4349-4352`）；无客户端时设备可正常休眠，不污染待机行为。
   - 直接消除“设备熄屏 → CADisplayLink 暂停 → 画面定格”这条最高概率路径。

2. **帧存活探针 / watchdog**（Fix 2）
   - `src/trollvncserver.mm:5116-5144` 新增 `installFrameLivenessWatchdog()`，在**后台 GCD 队列**跑定时器（每 10s 检查），与主线程解耦——即便 `rfbRunEventLoop` 主线程卡死也能触发。
   - `handleFramebuffer` 入口（`:2343`）每帧写入 `gLastFrameProduced = time(NULL)`。
   - 当 `gClientCount > 0` 且 `now - gLastFrameProduced > 60s` 时，`exit(0)` 主动退出，交由 launchd / `trollvncmanager` 监管重启。
   - 配套默认防休眠：重启后客户端自动重连 → KeepAlive 重新激活 → 显示唤醒 → 恢复产帧，将“永久假死”变为“可自愈”。

> 备份点：`git tag v3.82`（修改前快照）；本轮修改将在发布时以 `v3.83` 形式进入 CI 构建与 GitHub Release。
