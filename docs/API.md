# MatisuXCS HTTP API 文档

> **版本**: v3.6  
> **默认端口**: 8182  
> **Base URL**: `http://{设备IP}:8182`

---

## 目录

- [1. 截图与屏幕](#1-截图与屏幕)
- [2. 剪贴板](#2-剪贴板)
- [3. 输入控制](#3-输入控制)
- [4. 设备信息](#4-设备信息)
- [5. 文件操作](#5-文件操作)
- [6. WebDAV 文件管理](#6-webdav-文件管理)
- [7. 系统控制](#7-系统控制)
- [8. 应用安装/卸载](#8-应用安装卸载)
- [9. Plist 操作](#9-plist-操作)
- [10. 群控 API](#10-群控-api)
- [11. 其他端点](#11-其他端点)
- [附录：HTTP 状态码说明](#附录http-状态码说明)
- [附录：通用响应格式](#附录通用响应格式)
- [附录：端点快速参考](#附录端点快速参考)

---

## 1. 截图与屏幕

### GET /api/screenshot

获取设备屏幕截图。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| format | string | 否 | `png` | 图片格式：`png` 或 `jpeg` |
| quality | float | 否 | `0.9` | JPEG 质量（0.0~1.0），仅 format=jpeg 时有效 |
| rotation | int | 否 | `0` | 旋转角度：0=Home在下, 90=Home在右, 180=Home在上, 270=Home在左 |
| scale | float | 否 | `1.0` | 缩放比例（0.1~1.0），小于 1.0 时返回缩小图 |

**响应**:

- 成功：返回图片二进制数据（`image/png` 或 `image/jpeg`）
- 失败：`{"error": "Screenshot failed"}`（HTTP 500）

**示例**:

```
GET /api/screenshot?format=jpeg&quality=0.7&scale=0.5
GET /api/screenshot?rotation=90&format=png
```

---

### POST /api/screen/lock

锁定屏幕（模拟按下电源键）。

**参数**: 无

**响应**:

```json
{
  "success": true,
  "message": "Screen locked"
}
```

---

### POST /api/screen/unlock

解锁屏幕（唤醒屏幕 + 模拟 Home 键）。
若开启了 AutoUnlock，双击 Home 即唤醒+解锁。

**参数**: 无

**响应**:

```json
{
  "success": true,
  "message": "Screen unlocked"
}
```

---

### POST /api/home

返回桌面（模拟按一次 Home 键）。

**参数**: 无

**响应**:

```json
{
  "success": true,
  "action": "home",
  "message": "Returned to home screen"
}
```

---

## 2. 剪贴板

### GET /api/clipboard

获取剪贴板内容（JSON 格式）。

**响应**:

```json
{
  "success": true,
  "text": "剪贴板内容"
}
```

---

### GET /api/clipboard_text

获取剪贴板内容（纯文本，`text/plain`）。

**响应**: 直接返回文本内容，Content-Type 为 `text/plain; charset=utf-8`

---

### POST /api/clipboard

设置剪贴板内容（Base64 编码）。

**Body**: Base64 编码的文本（UTF-8 字符串）

**响应**:

```json
{
  "success": true,
  "text": "设置的内容"
}
```

**示例**:

```bash
echo -n "Hello World" | base64  # SGVsbG8gV29ybGQ=
curl -X POST http://192.168.1.100:8182/api/clipboard -d "SGVsbG8gV29ybGQ="
```

---

### POST /api/clipboard_text

设置剪贴板内容（纯文本）。

**Body**: 纯文本（UTF-8）

**响应**:

```json
{
  "success": true,
  "text": "设置的内容"
}
```

---

## 3. 输入控制

### POST /api/input

向当前焦点输入框输入文本。

**Body**: 要输入的纯文本（UTF-8）

**响应**:

- 成功：

```json
{
  "success": true,
  "text": "输入的内容",
  "length": 5
}
```

- 无焦点输入框：

```json
{
  "success": false,
  "error": "No active text input field found. Please focus an input field first."
}
```

---

### POST /api/key

发送按键事件。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| code | int | 是 | 按键代码（13=回车, 8=退格, 等等） |

**响应**:

```json
{
  "success": true,
  "keyCode": 13
}
```

---

## 4. 设备信息

### GET /api/device

获取设备详细信息。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| ip | string | 否 | 服务器 IP（配合 save 使用） |
| save | string | 否 | `true` 或 `1` 时保存设备信息到 `/var/mobile/Media/fuwuduan.txt` |

**响应**:

```json
{
  "deviceName": "iPhone",
  "deviceId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "deviceModel": "iPhone15,2",
  "deviceModelName": "iPhone 14 Pro",
  "systemVersion": "17.0",
  "systemName": "iOS",
  "batteryLevel": 85,
  "batteryState": "charging",
  "storage": {
    "totalBytes": 256000000000,
    "freeBytes": 128000000000,
    "usedBytes": 128000000000,
    "totalGB": "238.4",
    "freeGB": "119.2",
    "usedGB": "119.2",
    "usagePercent": 50.0
  }
}
```

> `deviceId` 优先从 `/var/mobile/Media/.matisu_device_id` 读取，不存在则生成并保存。  
> `batteryState`: `unplugged`（未充电）、`charging`（充电中）、`full`（已充满）、`unknown`  
> `batteryLevel`: 百分比值（0~100），-1 表示无法获取

---

### GET /api/status

获取 HTTP 服务器运行状态。

**响应**:

```json
{
  "status": "running",
  "httpPort": 8182,
  "version": "3.5"
}
```

---

### GET /api/clients

获取当前 VNC 客户端连接列表。

**响应**:

```json
{
  "clients": [],
  "count": 0
}
```

---

### GET /api/checkfile

检查 `/var/mobile/Media/zhuangtai.txt` 文件是否存在。

**响应**:

```json
{"status": "ok", "message": "File exists", "path": "/var/mobile/Media/zhuangtai.txt"}
```

或

```json
{"status": "no", "message": "File not found", "path": "/var/mobile/Media/zhuangtai.txt"}
```

---

## 5. 文件操作

### GET /api/filelist

列出指定目录下的文件和子目录。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| path | string | 否 | `/var/mobile/Media/com.matisu.one.nxs.rootcore` | 目录路径 |

**响应**:

```json
{
  "success": true,
  "path": "/var/mobile/Media",
  "files": [
    {
      "name": "Documents",
      "path": "/var/mobile/Media/Documents",
      "isDirectory": true,
      "size": 0,
      "modTimestamp": 1717660800
    },
    {
      "name": "test.txt",
      "path": "/var/mobile/Media/test.txt",
      "isDirectory": false,
      "size": 1024,
      "modTimestamp": 1717660800
    }
  ]
}
```

---

### GET /api/readfile

读取文件内容（文本文件）。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 文件完整路径 |

**响应**:

```json
{
  "success": true,
  "path": "/var/mobile/Media/test.txt",
  "size": 1024,
  "content": "文件内容...",
  "modTimestamp": 1717660800
}
```

> 二进制文件返回 `"<binary data>"`

---

### POST /api/writefile_text

写入文本文件。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| path | string | 是 | - | 文件完整路径 |
| append | string | 否 | `false` | `true` 追加写入，`false` 覆盖写入 |

**Body**: 纯文本内容（UTF-8）

**响应**:

```json
{
  "success": true,
  "path": "/var/mobile/Media/test.txt",
  "bytes": 1024
}
```

---

### POST /api/upload

上传文件（任意类型）。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件完整路径（含文件名），目录不存在时自动创建 |

**Body**: 文件二进制数据

**响应**:

```json
{
  "success": true,
  "path": "/var/mobile/Media/Downloads/app.ipa",
  "bytes": 5242880,
  "directory": "/var/mobile/Media/Downloads",
  "created": true,
  "modified": "2026-06-06 12:00:00 +0000"
}
```

---

### POST /api/deletefile

删除文件或目录。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 要删除的文件/目录完整路径 |

**响应**:

```json
{"success": true, "message": "Deleted successfully", "path": "/var/mobile/Media/test.txt"}
```

> 有 root 权限时使用 `spawnRoot rm -rf`，否则以 mobile 权限删除。

---

### POST /api/createfolder

创建目录。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目录完整路径，支持递归创建 |

**响应**:

```json
{"success": true, "message": "Folder created successfully", "path": "/var/mobile/Media/newfolder"}
```

> 有 root 权限时使用 `spawnRoot mkdir -p`，否则以 mobile 权限创建。

---

## 6. WebDAV 文件管理

### POST /api/webdav/start

启动 WebDAV 服务。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| root | string | 否 | `/` | WebDAV 根目录，设置后持久化保存到 plist |

**响应**:

```json
{
  "success": true,
  "message": "WebDAV 已启用",
  "rootPath": "/"
}
```

> 默认根目录为 `/`（可访问所有目录），可通过 `root` 参数指定，如 `/var/mobile/Media`。

---

### POST /api/webdav/stop

停止 WebDAV 服务。

**响应**:

```json
{
  "success": true,
  "message": "WebDAV 已停用"
}
```

---

### GET /api/webdav/status

获取 WebDAV 服务状态。

**响应**:

```json
{
  "enabled": true,
  "rootPath": "/"
}
```

---

### GET /webdav

WebDAV 文件浏览器界面（HTML 页面）。

> 仅在 WebDAV 服务启用时可访问。优先读取 `/var/mobile/Library/MatisuXCS/webdav.html` 自定义页面，不存在则使用内嵌默认页面。

---

### WebDAV 协议端点

WebDAV 标准协议操作（`PROPFIND`、`GET`、`PUT`、`DELETE`、`MKCOL` 等）通过 `/webdav/` 路径前缀访问。

- 路径格式：`/webdav/{文件或目录路径}`
- 中文路径自动进行 URL 百分号编码/解码
- 根目录由 `WebDAVRootPath` 配置决定（默认 `/`）
- 支持通过 WebDAV 客户端（如 Finder、Windows 资源管理器、Cyberduck 等）直接挂载

---

## 7. 系统控制

### GET/POST /api/volume

获取或设置音量。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| value | float | 否 | 设置音量（0.0~1.0），不传则获取当前音量 |

**响应**:

```json
{"success": true, "volume": 0.5}
```

---

### GET/POST /api/brightness

获取或设置屏幕亮度。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| value | float | 否 | 设置亮度（0.0~1.0），不传则获取当前亮度 |

**响应**:

```json
{"success": true, "brightness": 0.8}
```

---

### POST /api/reboot

重启设备。

**响应**:

```json
{
  "success": true,
  "message": "Reboot initiated",
  "warning": "Device will restart immediately"
}
```

---

### POST /api/respring

注销设备（Respring），15 秒后自动解锁屏幕。

**响应**:

```json
{
  "success": true,
  "message": "Respring initiated",
  "warning": "Screen will unlock after 15 seconds"
}
```

---

### POST /api/taskmanager

打开任务管理器（模拟双击 Home 键）。

**响应**:

```json
{"success": true, "action": "taskmanager", "message": "Task manager opened"}
```

---

### POST /api/clearapps/smart

智能清理后台应用。若当前在桌面则跳过，若在应用内则上滑关闭。

**响应**:

```json
{
  "success": true,
  "cleared": 3,
  "wasOnHomescreen": false
}
```

---

### GET /api/assistivetouch

获取 AssistiveTouch（小白点）状态。

**响应**:

```json
{"success": true, "action": "status", "enabled": true}
```

---

### POST /api/assistivetouch

启用或禁用 AssistiveTouch（小白点）。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| action | string | 是 | `enable` 或 `disable` |

**响应**:

```json
{"success": true, "action": "enable", "message": "AssistiveTouch enabled, respringing..."}
```

> 操作后会自动 Respring，15 秒后自动解锁屏幕。

---

## 8. 应用安装/卸载

### POST /api/install

通过 TrollStore 安装 IPA 文件。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | IPA 文件本地路径 |

**响应**:

```json
{"success": true, "message": "App installed successfully", "path": "/var/mobile/Media/app.ipa"}
```

---

### POST /api/install/tipa

通过 TrollStore 安装 .tipa 文件（巨魔包）。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | .tipa 文件本地路径 |

**响应**:

```json
{"success": true, "message": "TrollStore install requested", "path": "/var/mobile/Media/app.tipa"}
```

> 通过 `trollstore://install?file=` URL Scheme 触发 TrollStore 安装界面。

---

### POST /api/install/url

通过 URL 触发 TrollStore 安装远程 .tipa 文件。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| url | string | 是 | 远程 .tipa 文件的下载 URL |

**响应**:

```json
{"success": true, "message": "TrollStore install requested", "url": "https://example.com/app.tipa"}
```

> 通过 `trollstore://install?url=` URL Scheme 触发 TrollStore 下载并安装。

---

### POST /api/install/deb

安装 .deb 包。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 否 | .deb 文件本地路径；若不传则使用 Body 上传 |

**Body**（可选）: .deb 文件二进制数据（不传 path 参数时生效）

**响应**:

```json
{"success": true, "message": "DEB package installed successfully, uicache triggered", "path": "/var/mobile/Media/app.deb"}
```

> 安装成功后自动执行 `uicache -a` 刷新图标缓存，2 秒后自动 Respring。

---

### POST /api/uninstall

通过 TrollStore 卸载应用。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| bundleId | string | 是 | 应用 Bundle ID，如 `com.example.app` |

**响应**:

```json
{"success": true, "message": "App uninstalled successfully", "bundleId": "com.example.app"}
```

---

### GET /api/trollstore/diagnostics

获取 TrollStore 诊断信息。

**响应**:

```json
{
  "available": true,
  "version": "2.0.9",
  "...": "..."
}
```

---

## 9. Plist 操作

### GET /api/plist

读取 plist 文件。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | plist 文件完整路径 |
| keys | string | 否 | 逗号分隔的键名，只返回指定键 |
| match | string | 否 | 部分匹配键名，返回包含该字符串的键 |

**响应**:

- 完整读取（无 keys/match）：返回 XML plist 格式（`application/x-plist+xml`）
- 过滤读取（有 keys/match）：

```json
{
  "success": true,
  "path": "/var/mobile/Library/Preferences/com.example.plist",
  "data": {
    "key1": "value1",
    "key2": 42
  }
}
```

---

### POST /api/plist

写入/修改 plist 文件。不支持 PUT/DELETE 等其他 HTTP 方法（返回 405）。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是（query） | plist 文件完整路径 |

**Body**: JSON 格式数据

**简单格式**（覆盖整个 plist）:

```json
{
  "key1": "value1",
  "key2": 42
}
```

**新格式**（修改现有 plist 的指定键）:

```json
{
  "path": "/var/mobile/Library/Preferences/com.example.plist",
  "set": {
    "key1": "new_value",
    "key2": 100
  }
}
```

**匹配修改格式**:

```json
{
  "path": "/var/mobile/Library/Preferences/com.example.plist",
  "match": "KeyPrefix",
  "matchValue": "new_value"
}
```

**响应**:

```json
{
  "success": true,
  "path": "/var/mobile/Library/Preferences/com.example.plist",
  "modified": ["key1", "key2"],
  "data": {
    "key1": "new_value",
    "key2": 100
  }
}
```

---

## 10. 群控 API

群控功能用于多设备统一操控，分**主控**和**从控**两种角色。

### POST /api/group/start

启动群控 WebSocket 服务。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| master | string | 否 | `0` | `1` = 主控模式，`0` = 从控模式 |
| port | int | 否 | `8183` | WebSocket 端口 |

**响应**:

```json
{
  "success": true,
  "master": true,
  "port": 8183,
  "slaves": 0
}
```

---

### POST /api/group/stop

停止群控服务。

**响应**:

```json
{"success": true}
```

---

### GET /api/group/status

获取群控服务状态。

**响应**:

```json
{
  "running": true,
  "master": true,
  "port": 8183,
  "slaves": 3,
  "slaveConnected": false,
  "masterIP": ""
}
```

---

### POST /api/group/touch

接收群控触摸/按键事件（从控端使用）。

**Body**: JSON 格式

触摸事件:

```json
{
  "type": "touch",
  "x": 200,
  "y": 300,
  "action": "touchDown"
}
```

按键事件:

```json
{
  "type": "key",
  "keyCode": 13
}
```

**响应**:

```json
{"success": true}
```

---

### POST /api/group/connect

从控设备连接到主控。

**参数**:

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| ip | string | 是 | 主控设备 IP 地址 |
| port | int | 否 | 主控 WebSocket 端口，默认 8183 |

**响应**:

```json
{
  "success": true,
  "masterIP": "192.168.1.100",
  "port": 8183
}
```

> 设备不能同时作为主控和从控。

---

### POST /api/group/disconnect

从控设备断开与主控的连接。

**响应**:

```json
{"success": true}
```

---

### GET /api/group/slaves

获取从控设备 IP 列表。

**响应**:

```json
{
  "slaves": [
    {"ip": "192.168.1.101"},
    {"ip": "192.168.1.102"}
  ],
  "count": 2
}
```

---

### GET /api/group/proxy-screenshot

代理获取从控设备截图（解决跨域问题）。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| ip | string | 是 | - | 从控设备 IP |
| port | string | 否 | `8182` | 从控 HTTP 端口 |
| format | string | 否 | `jpeg` | 图片格式 |
| quality | string | 否 | `0.5` | JPEG 质量 |
| scale | string | 否 | `0.3` | 缩放比例 |

**响应**: 图片二进制数据（`image/jpeg` 或 `image/png`）

---

## 11. 其他端点

### POST /api/alert

在设备屏幕弹出系统弹窗提示传入的内容。

**参数**:

| 参数 | 类型 | 必填 | 默认值 | 说明 |
|------|------|------|--------|------|
| message | string | ✅ | - | 弹窗显示的内容文本 |
| title | string | ❌ | `MatisuXCS` | 弹窗标题 |
| duration | float | ❌ | `0` | 自动关闭时长（秒），`0` 或负数表示一直显示不自动关闭 |

**响应**:

```json
{"success": true, "message": "Alert shown", "title": "...", "duration": 5}
```

**示例**:

```bash
# 弹出提示，一直显示（默认）
curl -X POST "http://192.168.1.100:8182/api/alert?message=测试弹窗"

# 弹出提示，3秒后自动关闭
curl -X POST "http://192.168.1.100:8182/api/alert?message=测试弹窗&duration=3"

# 自定义标题
curl -X POST "http://192.168.1.100:8182/api/alert?message=测试&title=警告"
```

---

### GET /

返回 HTML 格式的 API 文档页面。

---

### GET /test

返回 JSON 格式的服务测试信息。

**响应**:

```json
{
  "status": "ok",
  "message": "TrollVNC HTTP API is working",
  "version": "3.5"
}
```

---

### GET /group-test

群控功能测试页面（HTML）。

---

### GET /group-control

投屏群控管理台页面（HTML），即 Matisu 群控管理台。

---

## 附录：HTTP 状态码说明

| 状态码 | 说明 |
|--------|------|
| 200 | 请求成功 |
| 400 | 请求参数错误（缺少必填参数、格式错误等） |
| 404 | 文件或资源不存在 |
| 405 | HTTP 方法不允许（如 POST 端点使用 GET） |
| 500 | 服务器内部错误（操作失败、权限不足等） |

## 附录：通用响应格式

所有 JSON 响应均包含 `success` 字段：

```json
// 成功
{"success": true, ...}

// 失败
{"success": false, "error": "错误描述"}
```

## 附录：端点快速参考

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/screenshot` | 获取屏幕截图 |
| POST | `/api/writefile_text` | 写入文本文件 |
| GET | `/api/clipboard` | 获取剪贴板（JSON） |
| POST | `/api/clipboard` | 设置剪贴板（Base64） |
| GET | `/api/clipboard_text` | 获取剪贴板（纯文本） |
| POST | `/api/clipboard_text` | 设置剪贴板（纯文本） |
| POST | `/api/input` | 输入文本到焦点输入框 |
| POST | `/api/key` | 发送按键事件 |
| GET | `/api/clients` | 获取 VNC 客户端列表 |
| GET | `/api/status` | 获取服务器状态 |
| GET | `/api/device` | 获取设备信息 |
| GET | `/api/checkfile` | 检查状态文件是否存在 |
| POST | `/api/upload` | 上传文件 |
| GET/POST | `/api/volume` | 获取/设置音量 |
| GET/POST | `/api/brightness` | 获取/设置亮度 |
| POST | `/api/install` | 安装 IPA（TrollStore） |
| POST | `/api/install/tipa` | 安装 .tipa（TrollStore URL Scheme） |
| POST | `/api/install/url` | 从 URL 安装（TrollStore URL Scheme） |
| POST | `/api/install/deb` | 安装 .deb 包（dpkg） |
| POST | `/api/uninstall` | 卸载应用（TrollStore） |
| GET | `/api/trollstore/diagnostics` | 获取 TrollStore 诊断信息 |
| GET/POST | `/api/plist` | 读取/写入 plist 文件 |
| POST | `/api/reboot` | 重启设备 |
| POST | `/api/respring` | 注销设备（15s 后自动解锁） |
| POST | `/api/screen/lock` | 锁定屏幕 |
| POST | `/api/screen/unlock` | 解锁屏幕 |
| POST | `/api/home` | 返回桌面 |
| POST | `/api/taskmanager` | 打开任务管理器 |
| POST | `/api/clearapps/smart` | 智能清理后台应用 |
| GET | `/api/assistivetouch` | 获取 AssistiveTouch 状态 |
| POST | `/api/assistivetouch` | 启用/禁用 AssistiveTouch |
| GET | `/api/filelist` | 列出目录内容 |
| GET | `/api/readfile` | 读取文件内容 |
| POST | `/api/deletefile` | 删除文件或目录 |
| POST | `/api/createfolder` | 创建目录 |
| POST | `/api/webdav/start` | 启动 WebDAV 服务 |
| POST | `/api/webdav/stop` | 停止 WebDAV 服务 |
| GET | `/api/webdav/status` | 获取 WebDAV 状态 |
| POST | `/api/group/start` | 启动群控 WebSocket 服务 |
| POST | `/api/group/stop` | 停止群控服务 |
| GET | `/api/group/status` | 获取群控状态 |
| POST | `/api/group/touch` | 接收群控触摸/按键事件 |
| POST | `/api/group/connect` | 从控连接到主控 |
| POST | `/api/group/disconnect` | 从控断开连接 |
| GET | `/api/group/slaves` | 获取从控设备 IP 列表 |
| GET | `/api/group/proxy-screenshot` | 代理获取从控截图 |
| GET | `/` | API 文档页面（HTML） |
| GET | `/test` | 服务测试接口 |
| GET | `/group-test` | 群控测试页面 |
| GET | `/group-control` | 群控管理台页面 |
| GET | `/webdav` | WebDAV 浏览器界面 |
| — | `/webdav/*` | WebDAV 协议端点 |
