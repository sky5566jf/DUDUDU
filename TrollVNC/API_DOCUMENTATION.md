# TrollVNC HTTP API 文档

TrollVNC 提供 HTTP REST API 接口，默认在 **8182 端口**启动。

## 服务器信息

- **默认端口**: 8182
- **VNC 端口**: 5901
- **协议**: HTTP/1.1
- **编码**: UTF-8
- **CORS**: 已启用（支持跨域访问）

---

## API 分类总览

| 分类 | 端点数量 | 说明 |
|------|----------|------|
| [设备信息](#1-设备信息) | 3 | 设备、状态、客户端、存储空间 |
| [截图](#2-截图) | 1 | 获取屏幕截图 |
| [文本输入](#3-文本输入) | 4 | 文本输入、按键、剪贴板 |
| [文件操作](#4-文件操作) | 3 | 写入文件、上传、检查 |
| [系统控制](#5-系统控制) | 9 | 重启、注销、屏幕、Home、音量、亮度 |
| [应用管理](#6-应用管理) | 3 | 安装、卸载、TrollStore |
| [后台管理](#7-后台管理) | 1 | 智能清理后台应用 |
| [辅助功能](#8-辅助功能) | 3 | AssistiveTouch 启用/禁用 |

---

## 1. 设备信息

### 1.1 获取设备信息

获取设备名称、ID、系统版本、电量和屏幕信息。支持保存设备信息到手机。

**设备ID固化机制:**
- 优先读取 `/var/mobile/Media/.matisu_device_id` 文件中的设备ID
- 如果文件不存在，则读取手机设备ID并保存到该文件
- 后续请求都会使用固化后的设备ID

**请求:**
```
GET /api/device
GET /api/device?ip=192.168.1.100&save=true
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| ip | string | 否 | 客户端 IP 地址（保存时使用） |
| save | string | 否 | `true` 或 `1`：保存设备信息到 `/var/mobile/Media/fuwuduan.txt` |

**响应 (不保存):**
```json
{
  "deviceName": "iPhone",
  "deviceId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "deviceModel": "iPhone14,2",
  "deviceModelName": "iPhone 13 Pro",
  "systemVersion": "17.4.1",
  "systemName": "iOS",
  "batteryLevel": 85,
  "batteryState": "charging",
  "storage": {
    "totalBytes": 128000000000,
    "freeBytes": 64000000000,
    "usedBytes": 64000000000,
    "totalGB": "119.2",
    "freeGB": "59.6",
    "usedGB": "59.6",
    "usagePercent": 50
  }
}
```

**响应 (save=true):**
```json
{
  "deviceName": "iPhone",
  "deviceId": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
  "deviceModel": "iPhone14,2",
  "deviceModelName": "iPhone 13 Pro",
  "systemVersion": "17.4.1",
  "systemName": "iOS",
  "batteryLevel": 85,
  "batteryState": "charging",
  "serverIP": "192.168.1.100",
  "recordTime": "2026-04-07 06:31:00 +0000",
  "_saved": true,
  "_savePath": "/var/mobile/Media/fuwuduan.txt"
}
```

**保存的文件内容格式:**
```json
{
  "deviceId" : "294A8A0B-BF77-48D7-B6E9-5EA29D21073B",
  "deviceModelName" : "iPhone 6s",
  "systemName" : "iOS",
  "deviceName" : "巨魔3",
  "serverIP" : "192.69.0.24",
  "deviceModel" : "iPhone8,1",
  "recordTime" : "2026-04-06 22:19:44 +0000",
  "systemVersion" : "15.8.5",
  "batteryLevel" : 98,
  "batteryState" : "charging"
}
```

---

### 1.2 获取服务器状态

**请求:**
```
GET /api/status
```

**响应:**
```json
{
  "status": "running",
  "httpPort": 8182,
  "version": "3.1"
}
```

---

### 1.3 获取 VNC 客户端列表

**请求:**
```
GET /api/clients
```

**响应:**
```json
{
  "clients": [],
  "count": 0
}
```

---

## 2. 截图

### 2.1 获取截图

获取当前屏幕截图，支持旋转、缩放和格式转换。

**请求:**
```
GET /api/screenshot?format=png&quality=0.9&rotation=0&scale=1.0
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| format | string | 否 | 图片格式：`png` 或 `jpeg`，默认 `png` |
| quality | float | 否 | JPEG 质量 0.0~1.0，默认 `0.9` |
| rotation | int | 否 | 旋转角度（Home 键位置）：`0`(下), `90`(右), `180`(上), `270`(左) |
| scale | float | 否 | 缩放比例 0.1~1.0，默认 `1.0` |

**体积参考（iPhone 13 Pro 1170x2532 @3x）:**
| 参数 | 像素尺寸 | 约体积 |
|------|----------|--------|
| PNG (默认) | 1170x2532 | 2~4 MB |
| JPEG quality=0.9 | 1170x2532 | 500 KB~1 MB |
| JPEG quality=0.7, scale=0.5 | 585x1266 | 30~80 KB |
| JPEG quality=0.5, scale=0.3 | 351x760 | 10~30 KB |

**示例:**
```bash
# 获取 PNG 截图
curl -o screenshot.png "http://192.168.1.100:8182/api/screenshot"

# 获取旋转 90 度的截图（Home 在右侧）
curl -o screenshot.png "http://192.168.1.100:8182/api/screenshot?rotation=90"

# 获取缩小到 50% 的 JPEG 截图
curl -o screenshot.jpg "http://192.168.1.100:8182/api/screenshot?format=jpeg&quality=0.7&scale=0.5"
```

---

## 3. 文本输入

### 3.1 输入文本

将文本输入到当前焦点输入框。

**请求:**
```
POST /api/input
Content-Type: text/plain; charset=utf-8

要输入的文本
```

**响应:**
```json
{
  "success": true,
  "text": "要输入的文本",
  "length": 6
}
```

> **提示:** 输入前请确保目标输入框已获得焦点（看到键盘弹出）

---

### 3.2 发送按键

使用 HID 事件发送按键，无需焦点。使用 `kHIDPage_KeyboardOrKeypad` 页面。

**请求:**
```
POST /api/key?code=13
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| code | int | 是 | macOS 键码 |

**按键代码 (macOS 键码):**

| 代码 | 按键 | 代码 | 按键 |
|------|------|------|------|
| 13 | 回车 (Enter) | 8 | 退格 (Backspace) |
| 9 | Tab | 27 | Escape |
| 32 | 空格 | 118 | Forward Delete |

**方向键:**
| 代码 | 按键 |
|------|------|
| 126 | ↑ 上 |
| 125 | ↓ 下 |
| 123 | ← 左 |
| 124 | → 右 |

**导航键:**
| 代码 | 按键 |
|------|------|
| 115 | Home |
| 119 | End |
| 116 | Page Up |
| 117 | Page Down |

**功能键:**
| 代码 | 按键 | 代码 | 按键 |
|------|------|------|------|
| 122 | F1 | 123 | F2 |
| 99 | F3 | 118 | F4 |
| 96 | F5 | 97 | F6 |
| 98 | F7 | 100 | F8 |
| 101 | F9 | 109 | F10 |
| 103 | F11 | 111 | F12 |

**小键盘:**
| 代码 | 按键 | 代码 | 按键 |
|------|------|------|------|
| 96 | Num 7 | 97 | Num 8 |
| 98 | Num 9 | 100 | Num 4 |
| 101 | Num 5 | 102 | Num 6 |
| 103 | Num 1 | 104 | Num 2 |
| 105 | Num 3 | 67 | Num * |
| 78 | Num - | 69 | Num + |
| 76 | Num . | 53 | Clear |

---

### 3.3 设置剪贴板

直接设置剪贴板内容（纯文本）。

**请求:**
```
POST /api/clipboard_text
Content-Type: text/plain; charset=utf-8

剪贴板内容
```

**响应:**
```json
{
  "success": true
}
```

---

### 3.4 获取剪贴板

**请求:**
```
GET /api/clipboard_text
```

**响应:**
```json
{
  "success": true,
  "text": "剪贴板内容"
}
```

---

## 4. 文件操作

### 4.1 写入文本文件

写入纯文本内容到指定文件路径。

**请求:**
```
POST /api/writefile_text?path=/var/mobile/Documents/test.txt&append=false
Content-Type: text/plain; charset=utf-8

文件内容
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件路径 |
| append | boolean | 否 | 是否追加模式，默认 `false` |

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/Documents/test.txt",
  "bytes": 12
}
```

---

### 4.2 上传文件

上传任意文件到指定路径，自动创建目录。

**请求:**
```
POST /api/upload?path=/var/mobile/Documents/file.bin
Content-Type: application/octet-stream

<binary-file-content>
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件完整路径 |

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/Documents/file.bin",
  "bytes": 102456,
  "directory": "/var/mobile/Documents",
  "created": true
}
```

---

### 4.3 检查文件

检查 `/var/mobile/Media/zhuangtai.txt` 是否存在。

**请求:**
```
GET /api/checkfile
```

**响应:**
```json
{
  "status": "ok",
  "message": "File exists",
  "path": "/var/mobile/Media/zhuangtai.txt"
}
```

---

### 4.4 Plist 文件操作

读取、修改 plist 文件中的键值对。

**请求:**
```
POST /api/plist
Content-Type: application/json

{
  "path": "/var/mobile/Library/Preferences/com.jao.yhdl.plist",
  "set": {
    "jieao_GameSid": "192.168.1.100",
    "customKey": "value"
  },
  "match": "userOftenServer",
  "matchValue": "192.168.1.100"
}
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | plist 文件路径 |
| set | object | 否 | 要设置的键值对 |
| match | string | 否 | 匹配键名（部分匹配），匹配到则设置 matchValue |
| matchValue | string | 否 | 匹配键名时设置的值 |

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/Library/Preferences/com.jao.yhdl.plist",
  "modified": ["jieao_GameSid", "customKey", "userOftenServer1", "userOftenServer2"],
  "data": {
    "jieao_GameSid": "192.168.1.100",
    "customKey": "value",
    "userOftenServer1": "192.168.1.100",
    "userOftenServer2": "192.168.1.100"
  }
}
```

**示例:**
```bash
# 修改指定键值
curl -X POST "http://192.168.1.100:8182/api/plist" \
  -H "Content-Type: application/json" \
  -d '{"path":"/var/mobile/Library/Preferences/com.jao.yhdl.plist","set":{"jieao_GameSid":"192.168.1.100"}}'

# 匹配键名修改（所有包含 "userOftenServer" 的键都设为同一个值）
curl -X POST "http://192.168.1.100:8182/api/plist" \
  -H "Content-Type: application/json" \
  -d '{"path":"/var/mobile/Library/Preferences/com.jao.yhdl.plist","match":"userOftenServer","matchValue":"192.168.1.100"}'
```

---

## 5. 系统控制

### 5.1 重启设备

立即重启 iOS 设备。

**请求:**
```
POST /api/reboot
```

**响应:**
```json
{
  "success": true,
  "message": "Reboot initiated",
  "warning": "Device will restart immediately"
}
```

---

### 5.2 注销设备 (Respring)

重启 SpringBoard（注销），完成后等待 15 秒再按两次 Home 键解锁屏幕。

**请求:**
```
POST /api/respring
```

**响应:**
```json
{
  "success": true,
  "message": "Respring initiated",
  "warning": "Screen will unlock after 15 seconds"
}
```

---

### 5.3 锁定屏幕

使用 HID AC Lock 锁屏。

**请求:**
```
POST /api/screen/lock
```

**响应:**
```json
{
  "success": true,
  "message": "Screen locked"
}
```

---

### 5.4 解锁屏幕

唤醒设备：按一下 Home 键 → 等待 1.5 秒 → 再按一次 Home 键解锁。

**请求:**
```
POST /api/screen/unlock
```

**响应:**
```json
{
  "success": true,
  "message": "Screen unlocked"
}
```

---

### 5.5 返回桌面

按一次 Home 键，返回到桌面。

**请求:**
```
POST /api/home
```

**响应:**
```json
{
  "success": true,
  "action": "home",
  "message": "Returned to home screen"
}
```

---

### 5.6 打开任务管理器

双击 Home 键，打开最近应用列表（任务管理器）。

**请求:**
```
POST /api/taskmanager
```

**响应:**
```json
{
  "success": true,
  "action": "taskmanager",
  "message": "Task manager opened"
}
```

---

### 5.7 获取/设置音量

**获取当前音量:**
```
GET /api/volume
```

**设置音量:**
```
POST /api/volume?value=0.5
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| value | float | 否 | 音量值 0.0 ~ 1.0 |

**响应:**
```json
{
  "success": true,
  "volume": 0.5
}
```

---

### 5.8 获取/设置亮度

**获取当前亮度:**
```
GET /api/brightness
```

**设置亮度:**
```
POST /api/brightness?value=0.5
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| value | float | 否 | 亮度值 0.0 ~ 1.0 |

**响应:**
```json
{
  "success": true,
  "brightness": 0.5
}
```

---

## 6. 应用管理

### 6.1 安装应用

通过 TrollStore 安装 IPA 文件。

**请求:**
```
POST /api/install?path=/var/mobile/Documents/app.ipa
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | IPA 文件的完整路径 |

**响应:**
```json
{
  "success": true,
  "message": "App installed successfully",
  "path": "/var/mobile/Documents/app.ipa"
}
```

---

### 6.2 卸载应用

通过 TrollStore 卸载已安装的应用。

**请求:**
```
POST /api/uninstall?bundleId=com.example.app
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| bundleId | string | 是 | 应用的 Bundle ID |

**响应:**
```json
{
  "success": true,
  "message": "App uninstalled successfully",
  "bundleId": "com.example.app"
}
```

---

### 6.3 TrollStore 诊断

获取 TrollStore 诊断信息。

**请求:**
```
GET /api/trollstore/diagnostics
```

**响应:**
```json
{
  "available": true,
  "version": "2.0",
  "helperInstalled": true
}
```

---

## 7. 后台管理

### 7.1 智能清理后台应用

识别当前前台应用，如果在桌面（SpringBoard）则跳过，否则按 Home 键将应用退到后台。

**请求:**
```
POST /api/clearapps/smart
```

**响应:**
```json
{
  "success": true,
  "action": "dismissed",
  "frontmostApp": "com.example.app"
}
```

当已在桌面时:
```json
{
  "success": true,
  "action": "skipped",
  "message": "Already on SpringBoard, no apps to clear"
}
```

---

## 8. 辅助功能

### 8.1 获取 AssistiveTouch 状态

使用 defaults 命令获取小白点当前状态。

**请求:**
```
GET /api/assistivetouch
```

**响应:**
```json
{
  "success": true,
  "action": "status",
  "enabled": true
}
```

---

### 8.2 启用 AssistiveTouch

使用 defaults 命令启用小白点，通过 killall 通知系统重载设置。

**请求:**
```
POST /api/assistivetouch?action=enable
```

**响应:**
```json
{
  "success": true,
  "action": "enable",
  "message": "AssistiveTouch enabled"
}
```

---

### 8.3 禁用 AssistiveTouch

使用 defaults 命令禁用小白点，通过 killall 通知系统重载设置。

**请求:**
```
POST /api/assistivetouch?action=disable
```

**响应:**
```json
{
  "success": true,
  "action": "disable",
  "message": "AssistiveTouch disabled"
}
```

---

## 错误响应

所有 API 在出错时返回以下格式的 JSON:

```json
{
  "success": false,
  "error": "错误描述"
}
```

**HTTP 状态码:**
- `200` - 成功
- `400` - 请求参数错误
- `404` - 接口不存在
- `500` - 服务器内部错误

---

## 安全注意事项

1. HTTP 服务器默认监听所有网络接口，局域网内任何设备都可以访问
2. 没有内置身份验证，请确保在受信任的网络中使用
3. 建议通过 VPN 或防火墙限制访问

---

## 故障排除

### 无法连接到 HTTP 服务器

1. 确认 TrollVNC 服务器已启动
2. 检查防火墙设置
3. 确认端口 8182 未被占用

### 截图失败

1. 确认 TrollVNC 有屏幕录制权限
2. 检查设备是否处于锁定状态

### 文件写入失败

1. 确认目标路径有写入权限
2. 检查磁盘空间
3. TrollStore 安装的应用拥有更高权限

**推荐的可写路径:**
- `/var/mobile/Documents/`
- `/var/mobile/Media/`
- `/var/tmp/`
