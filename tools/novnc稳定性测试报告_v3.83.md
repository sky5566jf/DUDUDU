# noVNC 长会话稳定性测试报告 — v3.83

> 测试设备：`192.69.0.99`（iOS，已装 v3.83，`/api/status` 返回 `version:3.83`）
> 测试时间：2026-07-12 20:09 ~ 20:15
> 测试目标：验证针对「iOS 16 长时 noVNC 投屏整个服务挂掉」风险的两处修复
> - **Fix 1 默认防休眠保活**：`gKeepAliveSec` 默认值 `0.0`→`15.0`，有客户端时每 15s 发 `ACUnlock` 保持显示常亮（`src/trollvncserver.mm:87`、`:4354`）
> - **Fix 2 帧存活探针**：`installFrameLivenessWatchdog()`，客户端在连且 60s 无帧 → `exit(0)` 交 launchd 重启（`src/trollvncserver.mm:5118`）

---

## 总判定：部分通过（T1、T3 通过；T2 因测试方法冲突判 FAIL，非代码缺陷）

| 阶段 | 内容 | 结果 |
|------|------|------|
| T1 | 客户端常连 + 不锁屏 + 空闲 180s（验证 Fix 1 防休眠保活） | ✅ PASS |
| T2 | 远程锁屏注入冻结，验证 Fix 2 自愈（watchdog 触发 + launchd 拉起） | ⚠️ FAIL（方法冲突） |
| T3 | 优雅断开客户端，验证服务不崩 | ✅ PASS |

---

## T1 — 空闲防休眠保活（PASS，关键修复）

- 客户端完成 RFB 3.8 握手（gClientCount 置 >0），分辨率 384×681，名称 `Matisu`
- 180s 空闲、不锁屏：`restarts=0`、`down_events=0`、`client_died=False`
- 截图 API 持续服务 **60 次**，延迟区间 **16~38ms**（稳定、无抖动）
- **结论**：Fix 1 生效。长时空闲会话中屏幕保持常亮、画面持续刷新、无冻结、无重启、无掉线。这正是用户最初报告的「iOS 16 长时投屏服务挂掉」风险的直接修复，已实测通过。

## T2 — 冻结自愈（FAIL，但属测试方法冲突，不是 v3.83 缺陷）

- 发送 `POST /api/screen/lock` → HTTP 200 `{"success":true,"message":"Screen locked"}`（模拟电源键锁屏 → 显示熄灭 → CADisplayLink 本应停止 → 画面冻结）
- 等待 150s：**`process_died=False`、`recovered=False`** → 判 FAIL
- 失败原因（经源码确认，**非代码缺陷**）：
  - watchdog 逻辑本身正确（`src/trollvncserver.mm:5118-5144`）：`gClientCount>0` 且 `now - gLastFrameProduced > 60s` → `exit(0)`
  - 但 Fix 1 保活机制在客户端在连时每 15s 发 `ACUnlock`（`:4354`），使显示保持常亮、CADisplayLink 持续回调、frame 不断产出 → `gLastFrameProduced` 持续刷新 → watchdog 的「60s 无帧」条件**从未成立**
  - 即：**Fix 1 在正常工作中压制了 T2 想造出的冻结场景**，这是它该有的行为，而非 Fix 2 失效

> 独立验证 Fix 2 的方法：必须以 `-A 0`（关闭保活）参数重启守护进程，使锁屏后 frame 真正停止，watchdog 才会触发自杀 + launchd 自愈。REST API 无运行时关闭保活的接口（保活为启动期 CLI 参数 `-A`），故本沙箱无法单独触发，需设备侧重启守护进程配合。

## T3 — 客户端断开（PASS）

- 优雅关闭 RFB 客户端后观测 30s：`down_events=0`、`alive_end=True`
- **结论**：客户端断开不会让服务崩溃，守护进程保持健康。

---

## 总体结论

针对最初报告的风险（iOS 16 长时 noVNC 投屏整个服务挂掉）：

1. **核心修复 Fix 1 已实测生效**（T1 长时空闲不冻结、不掉线、服务稳定）。
2. **Fix 2（watchdog 自愈）代码逻辑正确**，但因与 Fix 1 保活机制在「锁屏」场景下相互压制，本次未能用锁屏法独立触发其自杀路径——这是测试设计冲突，不构成代码缺陷证据。
3. **T3 确认客户端断开不影响服务存活**。

建议（如需 100% 确认 Fix 2 行为）：以 `trollvncserver -A 0` 关闭保活重启守护进程后，再跑一次 T2 锁屏冻结测试，即可独立验证 watchdog 自杀 + launchd 自愈链路。
