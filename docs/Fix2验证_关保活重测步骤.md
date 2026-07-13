# 验证 Fix 2（帧存活 watchdog 自愈）— 关闭保活后重测 T2 的步骤

> 目的：把 v3.83 守护进程以「关保活」模式启动，使 `/api/screen/lock` 能真正造成「屏幕熄灭 → CADisplayLink 停 → 60s 无帧」，从而触发 `installFrameLivenessWatchdog()` 自杀 + launchd 自愈，验证 Fix 2 闭环。
>
> 为什么必须关保活：Fix 1 的保活（`gKeepAliveSec=15`）在客户端在连时每 15s 发 `ACUnlock`，会让显示保持常亮、frame 持续产出，watchdog 的「60s 无帧」条件永不成立，锁屏法无法独立触发自愈。所以测 Fix 2 前必须先关掉保活。
>
> 全程需在**设备侧**操作（iPhone 本机终端 / Filza），沙箱侧（代理）只负责跑测试脚本与判读。

---

## 步骤一：设备侧改 plist，加 `-A 0`

守护进程启动参数在 launchd plist 的 `ProgramArguments`：
```
/usr/bin/trollvncserver
-daemon
```
需改成：
```
/usr/bin/trollvncserver
-daemon
-A
0
```

### 方式 A：设备终端（SSH / NewTerm，root）
```bash
# 1) 备份原 plist
cp /Library/LaunchDaemons/com.82flex.trollvnc.plist /Library/LaunchDaemons/com.82flex.trollvnc.plist.bak

# 2) 用 plutil 直接替换 ProgramArguments 数组（最干净）
plutil -replace ProgramArguments -json '["/usr/bin/trollvncserver","-daemon","-A","0"]' \
  /Library/LaunchDaemons/com.82flex.trollvnc.plist

# 3) 校验
plutil -p /Library/LaunchDaemons/com.82flex.trollvnc.plist | grep -A4 ProgramArguments
# 应看到 -daemon / -A / 0
```
> 若设备没有 `plutil -json`，改用 Filza（方式 B）或下方 sed 兜底。

### 方式 B：Filza（GUI，无需命令行）
1. 打开 `/Library/LaunchDaemons/com.82flex.trollvnc.plist`
2. 展开 `ProgramArguments` 数组
3. 在 `-daemon` 那一项**后面**新增两项：`-A`（类型 String）和 `0`（类型 String）
4. 保存

### 兜底（sed，谨慎）
```bash
PLIST=/Library/LaunchDaemons/com.82flex.trollvnc.plist
cp "$PLIST" "$PLIST.bak"
# 在 <string>-daemon</string> 之后插入 <string>-A</string><string>0</string>
sed -i '' 's#<string>-daemon</string>#<string>-daemon</string>\n\t\t<string>-A</string>\n\t\t<string>0</string>#' "$PLIST"
```

---

## 步骤二：重载 launchd，让新参数生效

```bash
launchctl unload /Library/LaunchDaemons/com.82flex.trollvnc.plist
sleep 1
killall -9 trollvncserver 2>/dev/null   # 确保旧进程退出，避免用旧参数残留
sleep 1
launchctl load /Library/LaunchDaemons/com.82flex.trollvnc.plist
```

> 若 `load` 报 `service already loaded`，先确认 `unload` 成功；或直接**重启设备**最简单可靠（重启必读新 plist）。

---

## 步骤三：确认已关保活

```bash
ps aux | grep trollvncserver | grep -v grep
# 应看到类似：/usr/bin/trollvncserver -daemon -A 0
```

另外请确认设备仍在线、8182 可达（沙箱侧会先自测）：
- 浏览器 / 代理访问 `http://192.69.0.99:8182/api/status` 应返回 `version:3.83`。

---

## 步骤四：通知代理跑重测

告诉我「已关保活重启完成」后，代理侧会：
1. 先自测 8182 可达、`/api/status` 版本=3.83；
2. 重跑 `tools/vnc_test_harness.py`（约 6 分钟：T1 180s 防休眠 + T2 150s 锁屏自愈 + T3 30s 断开）；
3. 这次 T2 预期 **PASS**：锁屏后 ~60s 进程退出（RFB 客户端 socket 断开）、8182 短暂不可达、随后 launchd 重新拉起、8182 恢复 → 证明 Fix 2 自愈闭环成立。

---

## 回滚（验证完务必做）

测完请把保活恢复默认（否则日常长会话又回到 v3.82 无保活、可能冻结的旧风险）：

```bash
PLIST=/Library/LaunchDaemons/com.82flex.trollvnc.plist
cp "$PLIST.bak" "$PLIST"          # 或重新删掉 -A 0 两项
launchctl unload /Library/LaunchDaemons/com.82flex.trollvnc.plist
sleep 1
killall -9 trollvncserver 2>/dev/null
sleep 1
launchctl load /Library/LaunchDaemons/com.82flex.trollvnc.plist
ps aux | grep trollvncserver | grep -v grep   # 应只剩 -daemon（默认 15s 保活）
```

---

## 风险与说明
- 改 plist 是低风险操作（仅改启动参数，已备份 `.bak`）。
- 关保活期间若锁屏，画面会真的冻结直到 watchdog 60s 自杀并自愈——这是测试预期行为，不是故障。
- 若设备无 root 终端、也不方便改 plist，则 Fix 2 只能靠**代码审查确认**（逻辑已在 `trollvncserver.mm:5118-5144` 核实正确），无法在真机独立触发。
