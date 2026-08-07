# TrollVNC / MatisuXCS — 8182 REST API 文档

> 本文件由源码路由表（`src/TVNCHttpServer.mm` 650–707 行）与自描述接口（`/api/endpoints`，1243–1291 行）整理而来，反映当前工作树实况。
> 设备在线时 `GET <IP>:8182/api/endpoints?key=xxx` 可获取实时、永远与代码同步的版本。
>
> **版本提示**
> - 4.62 已移除旧的 5 个 `/api/*` 安装/卸载端点（`/api/install`、`/api/install/tipa`、`/api/install/url`、`/api/install/deb`、`/api/uninstall`）。
> - 4.63 合入 **MatisuTrollStore（M巨魔助手，原 8588）** 的 6 个接口，**路径 / 参数 / 方法 / 响应结构与 8588 完全一致（无 `/api` 前缀）**，旧脚本只需把 `IP:8588` 改成 `IP:8182` 即可复用。详见「📦 应用管理」章节。

## 端口总览

| 端口 | 协议 | 用途 |
|---|---|---|
| 5901 | RFB | VNC 桌面投屏 |
| 5801 | HTTP | noVNC Web 投屏 |
| 8182 | HTTP/REST | 本文件描述的控制 API |
| /webdav | WebDAV | 文件管理（DAV 1,2，单独 handler 挂载，不在下方路由表内） |

所有认证：REST 接口默认无鉴权（含 `/webdav`）；WebDAV 默认账户 `mobile / 12345678`。

---

## 📸 投屏 / 截图 / 流

| 方法 | 端点 | 说明 |
|---|---|---|
| GET | `/api/screenshot` | 截屏 |
| GET | `/api/screenshot/fast` | 快速截屏 |
| GET | `/api/stream.mjpeg?q=0.3&scale=0.3&fps=10` | MJPEG 视频流（q=画质 0–1，scale=缩放比，fps=帧率） |

## 📋 剪贴板 / 输入

| 方法 | 端点 | 说明 |
|---|---|---|
| GET / POST | `/api/clipboard` | 获取 / 写入剪贴板（base64 编码） |
| GET / POST | `/api/clipboard_text` | 获取 / 写入剪贴板（纯文本） |
| POST | `/api/input` | 注入触摸 / 输入事件（body 描述坐标、类型等） |
| GET | `/api/key?code=13\|8` | 按键（见下方键码表） |
| POST | `/api/swipe/back` | 左滑返回（iOS 边缘手势返回上一页） |

### `/api/key` 键码表（macOS virtual keycode）

| 分类 | 键码 |
|---|---|
| 基础 | 回车 13、退格 8、Tab 9、空格 32、ESC 27 |
| 方向 | 上 126、下 125、左 123、右 124 |
| 导航 | Home 115、End 119、PgUp 116、PgDn 121、Forward Delete 117 |
| 小键盘数字 | 0=82、1=83、2=84、3=85、4=86、5=87、6=88、7=89、8=91、9=92 |
| 小键盘符号 | `.`=65、`*`=67、`+`=69、Clear/NumLock=71、`/`=75、Enter=76、`-`=78、`=`=81 |
| 功能键 | F1 122、F2 120、F3 99、F4 118、F5 96、F6 97、F7 98、F8 100、F9 101、F10 109、F11 103、F12 111 |

> 小键盘走 USB HID **Keypad 专有 usage**（`+` `*` 无需 Shift 组合），与主键盘数字区相互独立。

## 📊 状态 / 设备

| 方法 | 端点 | 说明 |
|---|---|---|
| GET | `/api/clients` | 当前客户端（VNC/native）连接列表 |
| GET | `/api/status` | 服务器状态（含 `version`、运行时间等） |
| GET | `/api/device` | 设备信息：名称 / ID / 型号 / 系统版本 / 电量 |
| GET | `/api/hardware` | 硬件详情：CPU（核心数 / 使用率）、内存（总量 / 已用）、电池、散热状态 + 温度传感器、运行时间 |
| GET | `/api/ping` | 心跳检测 |
| GET / POST | `/api/plist` | 读取 / 写入 plist 配置 |
| GET | `/api/frontmost` | 当前前台 App |
| GET | `/api/checkfile` | 检查文件是否存在 |

## 🎛 系统控制

| 方法 | 端点 | 说明 |
|---|---|---|
| GET / POST | `/api/volume?value=0.5` | 获取 / 设置音量（0–1） |
| GET / POST | `/api/brightness?value=0.5` | 获取 / 设置亮度（0–1） |
| POST | `/api/reboot` | 重启设备（**越狱版已禁用**） |
| POST | `/api/shutdown` | 关机（**越狱版已禁用**） |
| POST | `/api/respring` | 注销设备（Respring），约 15 秒后自动解锁屏幕 |
| POST | `/api/screen/lock` | 锁定屏幕（电源键） |
| POST | `/api/screen/unlock` | 解锁屏幕（唤醒 + Home 键） |
| POST | `/api/home` | 返回桌面（按一次 Home 键） |
| POST | `/api/taskmanager` | 打开任务管理器（双击 Home 键） |
| POST | `/api/clearapps/smart` | 智能清理后台（不在桌面则关闭前台应用） |
| POST | `/api/clearapps/force` | 强制清理后台（即使在桌面也执行：多任务 + 上滑杀进程） |
| GET / POST | `/api/assistivetouch?action=enable\|disable` | 辅助触控（小白点）状态获取 / 启用 / 禁用 |
| POST | `/api/alert` | 弹窗提示（query 传标题 / 内容） |

## 📁 文件 / WebDAV

| 方法 | 端点 | 说明 |
|---|---|---|
| POST | `/api/upload` | 上传文件（multipart 或 body 字节） |
| GET | `/api/filelist?path=...` | 列目录 |
| GET | `/api/readfile?path=...` | 读文件 |
| POST | `/api/deletefile?path=...` | 删除文件 |
| POST | `/api/createfolder?path=...` | 创建文件夹 |
| POST | `/api/writefile_text?path=...&content=...` | 写入文本文件 |
| POST | `/api/webdav/start` | 启动 WebDAV 服务 |
| POST | `/api/webdav/stop` | 停止 WebDAV 服务 |
| GET | `/api/webdav/status` | WebDAV 运行状态 |
| — | `/webdav/*` | WebDAV 根（GET/PUT/PROPFIND/DELETE 等标准方法，账户 `mobile / 12345678`） |

## 🔧 网络调试

| 方法 | 端点 | 说明 |
|---|---|---|
| GET | `/api/network/debug` | 网络配置调试（读取配置文件结构与目录列表） |
| GET | `/api/network/test_helper` | 测试 root helper（spawn 自身以 root 身份执行 test 操作） |
| GET | `/api/network/ip_methods` | 诊断多种 IP 修改方案可行性 |
| GET | `/api/trollstore/diagnostics` | 获取 TrollStore 诊断信息（保留的只读诊断接口，**非安装接口**） |

## 👥 群控

| 方法 | 端点 | 说明 |
|---|---|---|
| POST | `/api/group/start?master=1&port=8183` | 启动群控 WebSocket 服务 |
| POST | `/api/group/stop` | 停止群控 |
| GET | `/api/group/status` | 获取群控状态 |
| POST | `/api/group/touch` | 接收群控触摸事件（JSON body） |
| POST | `/api/group/connect?ip=192.168.x.x&port=8183` | 从控连接到主控 |
| POST | `/api/group/disconnect` | 从控断开与主控的连接 |
| GET | `/api/group/slaves` | 获取从控设备 IP 列表 |
| GET | `/api/group/proxy-screenshot?ip=x.x.x.x&format=jpeg&quality=0.5&scale=0.3` | 代理获取从控截图 |
| POST | `/api/group/relay/start?relayIp=192.168.x.x&relayPort=8183&role=master\|slave` | 连接到电脑中继服务器（电脑中继模式） |
| POST | `/api/group/relay/stop` | 断开电脑中继服务器连接 |

## 📦 应用管理（MatisuTrollStore 合入，无 `/api` 前缀）

> 4.63 从 `F:\workbuddy\MatisuTrollStore`（原 8588 服务）整体照搬。**方法一律 GET，参数名与响应字段逐字保持一致**，方便旧脚本换端口即用。
> 底层通过 `trollstorehelper` + `posix_spawnattr_set_persona_np(persona=99)` 提权执行，拉起 App 走 `SBSLaunchApplicationWithIdentifier`。

| 方法 | 端点 | 说明 |
|---|---|---|
| GET | `/` | 健康检查（JSON：`status`/`version`/`port`/`endpoints`） |
| GET | `/status` | 服务状态 + `trollstorehelper` 路径探测结果 |
| GET | `/install?url=<下载地址>&launch=true` | 下载并**静默安装** tipa/ipa。`launch` 可选：`true` = 自动从 helper 输出识别 bundleId 后拉起；也可直接传 bundleId，或逗号分隔多个（间隔 10s） |
| GET | `/uninstall?bundle_id=com.xxx.yyy` | **静默卸载**指定 App |
| GET | `/launch?apps=com.a.b,com.c.d&interval=5` | 批量拉起 App。`interval` 间隔秒数，范围 1–60，默认 5 |
| GET | `/ports` | 端口健康监控状态（监控列表 + 是否监听 + 上次拉起距今秒数） |

### 端口健康监控（随 8182 自动启动）

| 监控端口 | 对应 App | 行为 |
|---|---|---|
| 8588 | `com.matisu.trollassistant` | 每 60s 探测一次；不通则 3s 后二次确认，仍不通则拉起对应 App |
| 3333 | `com.matisu.one.nxs` | 同上 |
| 8182 | `com.matisu.xcs` | 同上（XCS 自身 REST 端口；看门狗与 8182 同生灭，仅作冗余探针） |

同一端口拉起后有 **300s 冷却**，避免反复拉起。

**示例**

```bash
# 健康检查
curl http://192.69.0.42:8182/

# 安装并自动拉起
curl "http://192.69.0.42:8182/install?url=http://192.69.0.2/MatisuXCS_4.63.tipa&launch=true"

# 安装后拉起指定的多个 App
curl "http://192.69.0.42:8182/install?url=http://x/app.ipa&launch=com.a.b,com.c.d"

# 卸载
curl "http://192.69.0.42:8182/uninstall?bundle_id=com.matisu.xcs"

# 批量拉起（间隔 8 秒）
curl "http://192.69.0.42:8182/launch?apps=com.matisu.xcs,com.matisu.one.nxs&interval=8"

# 端口监控状态
curl http://192.69.0.42:8182/ports
```

**响应示例（`/install`）**

```json
{
  "status": "ok",
  "url": "http://x/app.tipa",
  "method": "trollstorehelper",
  "exitCode": 0,
  "output": "...",
  "launch": [{"bundleId": "com.matisu.xcs", "result": "exitCode:0|ret=0"}]
}
```

## 🖥 页面

| 方法 | 端点 | 说明 |
|---|---|---|
| GET | `/` | 健康检查 JSON（见「📦 应用管理」，已由旧 HTML 欢迎页替换） |
| GET | `/test` | 测试接口页 |
| GET | `/group-test` | 群控测试页面 |
| GET | `/group-control` | 投屏群控页面（可视化多设备控制） |
| GET | `/api/endpoints?key=xxx` | 本 API 自描述文档页 |

---

## 备注

- **已移除接口（4.62）**：`/api/install`、`/api/install/tipa`、`/api/install/url`、`/api/install/deb`、`/api/uninstall` 及其底层方法（`installAppWithIPAPath` / `uninstallAppWithBundleId` / `isTrollStoreAvailable`）已全部删除。群控 PC 页 `pc_group_control.html` 的「安装 IPA」按钮与 `batchInstall()` 同步移除。
- **新增接口（4.63）**：`/`、`/status`、`/install`、`/uninstall`、`/launch`、`/ports` 六个无前缀端点，源自 MatisuTrollStore（8588），实现于 `src/TVNCHttpServer+TrollStore.mm`。
- **敏感路由**：质量门禁 `quality/TVNCRouteSafety.c` 维护敏感路由表，新增 / 删除 API 时需同步更新该表，否则质量门禁会失败。`/install`、`/uninstall`、`/launch` 虽为 GET，但已标记 `WRITE | SENSITIVE`。
- **CORS**：REST API 默认 `*`（允许跨域）。
- **共 61 条路由**（含 4 个页面 + `/` + `/api/endpoints` + 5 个应用管理端点），另加独立挂载的 `/webdav/*`。

---

## ⚠️ API 改动铁律

每次新增 / 修改 / 删除 API，**必须同步下列 6 处**，缺一不可：

1. `src/TVNCHttpServer.mm` 路由表（`handleRequest:` 内的 `routes` 数组）
2. `src/TVNCHttpServer.mm` 的 `tvncRouteRegistry`（决定 `/api/endpoints` 自描述文档）
3. `quality/TVNCRouteSafety.c` 敏感路由表（否则质量门禁失败）
4. 详细 md 文档：本文件 `api.md` + `docs/API.md` + `TrollVNC/API_DOCUMENTATION.md`
5. 测试网页：`TrollVNC/test_api.html`（补上可点击按钮）
6. 群控 PC 页 `群控启动包/*.html`（若该 API 有对应 UI 入口）
