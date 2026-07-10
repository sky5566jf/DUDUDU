# 静态 IP 锁定功能（Step 2）实现说明

> 配合 Step 1（主界面只读展示当前 IP / 子网 / 路由器）一起使用。

## 功能
主界面「网络」分组新增开关 **「锁定 DHCP 为静态 IP」**：
- **开启**：把当前选中的目标接口（**确定性优先级：以太网 > Wi‑Fi**）通过 DHCP 获取到的 **IP / 子网掩码 / 路由器**，写入系统网络配置，`ConfigMethod` 翻转为 `Manual`（即“冻结”当前租约）。
- **关闭**：`ConfigMethod` 翻回 `DHCP`，恢复自动获取。

## 改动清单
| 文件 | 改动 |
|---|---|
| `app/TrollVNC/TrollVNC/TVNCRootListController.m` | ① 新增 `TVNCApplyStaticIPConfiguration()`（SCPreferences API 写入，dlopen 取符号）；② 重写 `setPreferenceValue:specifier:` 捕获开关；③ 新增 `tvnc_handleStaticIPToggle:` / `tvnc_revertStaticIPSwitch:` / `tvnc_showAlertWithTitle:` |
| `prefs/TrollVNCPrefs/Resources/Root.plist` | 「网络」分组 + `PSSwitchCell(key=StaticIPEnabled)` |
| `TrollVNC/prefs/TrollVNCPrefs/Resources/ManagedRoot.plist` | 同上（parity，防复制漂移）|

（Step 1 已在同文件加入只读展示用的 `TVNCGetCurrentNetworkInfo()`，返回 `ip/mask/router`）

## 安全网（绝不锁死用户）
1. **写前备份**：原 IPv4 配置备份到 App 沙盒 `Documents/static_ip_backup.plist`。
2. **无网拒绝**：未获取到有效 IP 时拒绝开启，并自动把开关拨回 OFF。
3. **失败回滚**：写入 / 提交 / 应用任一环节失败 → 返回 NO，开关自动回滚 OFF + 弹窗报错。
4. **可恢复**：关闭即翻转回 DHCP，一键恢复自动获取。

## 写入机制（关键设计）
- 走 **SCPreferences API**（由系统守护进程 `configd` 落地），**不**直接 `fopen` 写 plist。
  - 原因：巨魔版是 `mobile` 用户，直接写 root 属主的 `preferences.plist` 会被权限拒绝；API 方式 entitlement 已授权（`SCPreferences-write-access`），且自动抽象 `/var/jb` 前缀 → 对 `tipa` / `default` / `rootless` / `roothide` deb **一套代码通用**。
- 定位服务：用 `TVNCSelectPreferredNetwork()` 确定性选择目标接口（以太网 > Wi‑Fi），返回其 `Setup:/Network/Service/<id>`，按 `serviceID` 直接定位（不再依赖默认路由，解决双网卡场景锁错接口）。

## 跨平台
- **巨魔版（tipa，mobile）**：TrollStore 信任内嵌 entitlement，API 可写 ✅
- **越狱版（deb，mobile/root）**：同上 ✅
- 均复用已声明的 `SCPreferences-write-access`（三份 entitlements 一致）

## 测试步骤（真机）
1. 设备连 Wi-Fi/以太网，确认主界面 footer 显示正确的 IP / 子网 / 路由器（Step 1）。
2. 打开「锁定 DHCP 为静态 IP」→ 应弹窗显示锁定的 IP / 子网 / 路由器。
3. 到 iOS **设置 → Wi-Fi → 该网络**，确认“配置”已变为“手动”，IP/子网/路由器 = 锁定值。
4. 关闭开关 → “配置”回到“自动 / DHCP”。
5. 边界：飞行模式 / 断网时打开开关 → 应被拒绝并提示。

## 已知限制 / 风险
- 仅 IPv4（v1）。
- 锁定遵循**确定性优先级：以太网 > Wi‑Fi**。同时连 Wi‑Fi + 以太网时锁以太网；仅 Wi‑Fi 锁 Wi‑Fi；仅以太网锁以太网（不再依赖系统路由表谁恰好成默认路由，行为确定）。
- 写入会触发网络接口短暂重载（预期行为），可能瞬间断连再恢复。
- 巨魔版首次在真机验证 SCPreferences 写入是否如期（理论可行，有 Networkizer / DNSecure 等先例，但需实测）。
- 当前 Windows 环境无法编译 iOS 工程，需在 macOS + theos/Xcode 构建验证。

## 还原点
- Step 1 + Step 2 改动均基于备份提交 `09cf9baff9ca4fb08269ca509dcf266cd20de06b` 之上，**未提交**。
- 需还原：`git checkout 09cf9baff9ca4fb08269ca509dcf266cd20de06b`
