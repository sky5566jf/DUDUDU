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
| [设备信息](#1-设备信息) | 6 | 设备、电池、内存、存储、状态 |
| [截图](#2-截图) | 1 | 获取屏幕截图 |
| [触摸手势](#3-触摸手势) | 7 | 通过 VNC 协议控制 |
| [文本输入](#4-文本输入) | 4 | 文本输入、按键、剪贴板 |
| [文件操作](#5-文件操作) | 5 | 读写文件、上传、检查 |
| [系统控制](#6-系统控制) | 7 | 重启、注销、屏幕、音量、亮度 |
| [应用管理](#7-应用管理) | 4 | 安装、卸载、启动、TrollStore |
| [后台管理](#8-后台管理) | 2 | 清理后台应用 |
| [辅助功能](#9-辅助功能) | 4 | AssistiveTouch 控制 |
| [其他](#10-其他) | 1 | 触发懒人精灵 |

---

## 1. 设备信息

### 1.1 获取设备信息

获取设备名称、ID、系统版本、电量和屏幕信息。

**请求:**
```
GET /api/device
```

**响应:**
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
  "screenWidth": 1170,
  "screenHeight": 2532
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

### 1.4 获取电池状态

**请求:**
```
GET /api/battery
```

**响应:**
```json
{
  "success": true,
  "level": 85,
  "state": "charging"
}
```

---

### 1.5 获取内存状态

**请求:**
```
GET /api/memory
```

**响应:**
```json
{
  "success": true,
  "total": 6144,
  "used": 4096,
  "free": 2048,
  "percentage": 66.7
}
```

---

### 1.6 获取存储状态

**请求:**
```
GET /api/storage
```

**响应:**
```json
{
  "success": true,
  "total": 256000,
  "used": 180000,
  "free": 76000,
  "percentage": 70.3
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

## 3. 触摸手势

> **注意:** 触摸/滑动控制需要通过 **VNC 协议（端口 5901）** 实现。使用标准 VNC 客户端连接后即可进行触摸控制。

### 3.1 触摸操作

在指定坐标发送触摸事件。

**请求:**
```
POST /api/touch?x=200&y=400
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| x | int | 是 | X 坐标 |
| y | int | 是 | Y 坐标 |

---

### 3.2 滑动手势

从起点滑动到终点。

**请求:**
```
POST /api/swipe?x1=200&y1=400&x2=200&y2=200&duration=300
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| x1 | int | 是 | 起点 X 坐标 |
| y1 | int | 是 | 起点 Y 坐标 |
| x2 | int | 是 | 终点 X 坐标 |
| y2 | int | 是 | 终点 Y 坐标 |
| duration | int | 否 | 滑动时长（毫秒），默认 `300` |

---

### 3.3 按 Home 键

**请求:**
```
POST /api/presshome
```

---

### 3.4 按锁屏键

**请求:**
```
POST /api/presslock
```

---

### 3.5 同时按 Home + 锁屏

**请求:**
```
POST /api/pressboth
```

---

### 3.6 双击 Home

**请求:**
```
POST /api/doubleclick
```

---

### 3.7 三击 Home

**请求:**
```
POST /api/tripleclick
```

---

## 4. 文本输入

### 4.1 输入文本

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

### 4.2 发送按键

发送单个按键事件。

**请求:**
```
POST /api/key?code=13
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| code | int | 是 | 按键代码 |

**常用按键代码:**
| 代码 | 按键 |
|------|------|
| 13 | 回车键 (Enter) |
| 8 | 退格键 (Backspace) |
| 9 | Tab 键 |
| 27 | Escape 键 |
| 32 | 空格键 |

---

### 4.3 设置剪贴板

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

### 4.4 获取剪贴板

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

## 5. 文件操作

### 5.1 写入文本文件

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

### 5.2 读取文本文件

**请求:**
```
GET /api/readfile_text?path=/var/mobile/Documents/test.txt
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 文件路径 |

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/Documents/test.txt",
  "content": "文件内容",
  "bytes": 12
}
```

---

### 5.3 上传文件

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

### 5.4 检查文件

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

### 5.5 写入 Base64 文件（不推荐）

写入 Base64 编码的内容。

**请求:**
```
POST /api/writefile?path=/var/mobile/test.txt&append=false
Content-Type: text/plain

<base64-encoded-content>
```

---

## 6. 系统控制

### 6.1 重启设备

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

### 6.2 注销设备 (Respring)

重启 SpringBoard（注销），完成后等待 30 秒再解锁屏幕。

**请求:**
```
POST /api/respring
```

**响应:**
```json
{
  "success": true,
  "message": "Respring initiated",
  "warning": "Screen will unlock after 30 seconds"
}
```

---

### 6.3 锁定屏幕

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

### 6.4 解锁屏幕

唤醒设备并通过 Home 键解锁。

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

### 6.5 获取/设置音量

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

### 6.6 获取/设置亮度

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

## 7. 应用管理

### 7.1 安装应用

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

### 7.2 卸载应用

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

### 7.3 启动应用

通过 Bundle ID 启动应用。

**请求:**
```
POST /api/launchapp?bundleId=com.apple.mobilesafari
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| bundleId | string | 是 | 应用的 Bundle ID |

**响应:**
```json
{
  "success": true,
  "bundleId": "com.apple.mobilesafari"
}
```

---

### 7.4 TrollStore 诊断

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

## 8. 后台管理

### 8.1 清理后台应用

模拟双击 Home 键打开应用切换器，上滑关闭后台应用。

**请求:**
```
POST /api/clearapps
```

**响应:**
```json
{
  "success": true,
  "message": "Background apps cleared"
}
```

---

### 8.2 智能清理后台应用

识别当前应用，如果在桌面则跳过清理。

**请求:**
```
POST /api/clearapps/smart
```

**响应:**
```json
{
  "success": true,
  "action": "cleared",
  "frontmostApp": "com.apple.springboard"
}
```

---

## 9. 辅助功能

### 9.1 获取 AssistiveTouch 状态

**请求:**
```
GET /api/assistivetouch
```

**响应:**
```json
{
  "success": true,
  "enabled": true,
  "action": "status"
}
```

---

### 9.2 启用/禁用 AssistiveTouch

**请求:**
```
POST /api/assistivetouch?action=enable
POST /api/assistivetouch?action=disable
```

**⚠️ 警告:** `disable` 会修改系统 plist 文件！

---

### 9.3 锁定 AssistiveTouch

禁用 AssistiveTouch 并将 plist 文件权限设为只读（444），防止系统重新启用。

**请求:**
```
POST /api/assistivetouch/lock
```

**响应:**
```json
{
  "success": true,
  "message": "AssistiveTouch locked",
  "warning": "plist file set to read-only (444)"
}
```

---

### 9.4 解锁 AssistiveTouch

恢复 plist 可写权限并启用 AssistiveTouch。

**请求:**
```
POST /api/assistivetouch/unlock
```

**响应:**
```json
{
  "success": true,
  "message": "AssistiveTouch unlocked"
}
```

---

## 10. 其他

### 10.1 触发懒人精灵

等待指定秒数后向懒人精灵发送 POST 请求触发脚本运行。

**请求:**
```
GET /api/trigger?port=3333&delay=5
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| port | int | 否 | 懒人精灵端口，默认 `3333` |
| delay | int | 否 | 延迟秒数，默认 `5` |

**说明:** IP 地址会自动检测为调用者的 IP。

**响应:**
```json
{
  "success": true,
  "message": "Trigger scheduled",
  "target": {
    "ip": "192.168.1.100",
    "port": 3333
  },
  "delay": 5
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
