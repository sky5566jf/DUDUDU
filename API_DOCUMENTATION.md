# TrollVNC HTTP API 文档

TrollVNC 现在提供 HTTP REST API 接口，默认在 **8182 端口**启动。

## 服务器信息

- **默认端口**: 8182
- **协议**: HTTP/1.1
- **编码**: UTF-8
- **CORS**: 已启用（支持跨域访问）

## API 端点

### 1. 获取截图

获取当前屏幕截图。

**请求:**
```
GET /api/screenshot?format=png
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| format | string | 否 | 图片格式：`png` 或 `jpeg`，默认 `png` |

**响应:**
- 成功: 返回图片二进制数据 (`Content-Type: image/png` 或 `image/jpeg`)
- 失败: 返回 JSON 错误信息

**示例:**
```bash
# 获取 PNG 截图
curl -o screenshot.png "http://192.168.1.100:8182/api/screenshot?format=png"

# 获取 JPEG 截图
curl -o screenshot.jpg "http://192.168.1.100:8182/api/screenshot?format=jpeg"
```

```python
import requests

response = requests.get("http://192.168.1.100:8182/api/screenshot?format=png")
with open("screenshot.png", "wb") as f:
    f.write(response.content)
```

---

### 2. 写入文件 (Base64)

将 base64 编码的内容写入指定文件路径。

**请求:**
```
POST /api/writefile?path=/var/mobile/test.txt&append=false
Content-Type: text/plain

<base64-encoded-content>
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件路径 |
| append | boolean | 否 | 是否追加模式，默认 `false` |

**请求体:**
- base64 编码的文件内容

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/test.txt",
  "bytes": 1024
}
```

**示例:**
```bash
# 写入文本文件（中文支持）
echo -n "你好，世界！" | base64 | curl -X POST \
  "http://192.168.1.100:8182/api/writefile?path=/var/mobile/test.txt" \
  -H "Content-Type: text/plain" \
  --data-binary @-

# 追加内容
echo -n "追加的内容" | base64 | curl -X POST \
  "http://192.168.1.100:8182/api/writefile?path=/var/mobile/test.txt&append=true" \
  -H "Content-Type: text/plain" \
  --data-binary @-
```

```python
import requests
import base64

content = "你好，世界！Hello World!"
encoded = base64.b64encode(content.encode()).decode()

response = requests.post(
    "http://192.168.1.100:8182/api/writefile?path=/var/mobile/test.txt",
    data=encoded,
    headers={"Content-Type": "text/plain"}
)
print(response.json())
```

---

### 3. 写入文件 (纯文本 - 推荐)

直接发送纯文本内容到指定文件路径，**无需 base64 编码**。

**请求:**
```
POST /api/writefile_text?path=/var/mobile/test.txt&append=false
Content-Type: text/plain; charset=utf-8

纯文本内容，支持中文！
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件路径 |
| append | boolean | 否 | 是否追加模式，默认 `false` |

**请求体:**
- 纯文本内容（UTF-8 编码）

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/test.txt",
  "bytes": 27
}
```

**示例:**
```bash
# 直接写入文本（推荐，更简单）
curl -X POST \
  "http://192.168.1.100:8182/api/writefile_text?path=/var/mobile/test.txt" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！Hello World!"

# 追加内容
curl -X POST \
  "http://192.168.1.100:8182/api/writefile_text?path=/var/mobile/test.txt&append=true" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "这是追加的内容"
```

```python
import requests

content = "你好，世界！Hello World!"

response = requests.post(
    "http://192.168.1.100:8182/api/writefile_text?path=/var/mobile/test.txt",
    data=content,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

---

### 4. 设置剪贴板 (Base64)

设置 iOS 系统剪贴板内容。

**请求:**
```
POST /api/clipboard
Content-Type: text/plain

<base64-encoded-text>
```

**请求体:**
- base64 编码的文本内容

**响应:**
```json
{
  "success": true
}
```

**示例:**
```bash
# 设置剪贴板（中文）
echo -n "复制的文本内容" | base64 | curl -X POST \
  "http://192.168.1.100:8182/api/clipboard" \
  -H "Content-Type: text/plain" \
  --data-binary @-
```

```python
import requests
import base64

text = "要复制到剪贴板的文本"
encoded = base64.b64encode(text.encode()).decode()

response = requests.post(
    "http://192.168.1.100:8182/api/clipboard",
    data=encoded,
    headers={"Content-Type": "text/plain"}
)
print(response.json())
```

---

### 5. 设置剪贴板 (纯文本 - 推荐)

直接设置剪贴板，**无需 base64 编码**。

**请求:**
```
POST /api/clipboard_text
Content-Type: text/plain; charset=utf-8

纯文本内容
```

**请求体:**
- 纯文本内容（UTF-8 编码）

**响应:**
```json
{
  "success": true
}
```

**示例:**
```bash
# 直接设置剪贴板（推荐，更简单）
curl -X POST \
  "http://192.168.1.100:8182/api/clipboard_text" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！Hello World!"
```

```python
import requests

text = "你好，世界！Hello World!"

response = requests.post(
    "http://192.168.1.100:8182/api/clipboard_text",
    data=text,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

---

### 6. 文本输入

将文本输入到当前焦点输入框。支持中英文输入：
- **英文/数字**: 直接模拟键盘输入
- **中文**: 自动使用剪贴板+粘贴方式

**请求:**
```
POST /api/input
Content-Type: text/plain; charset=utf-8

要输入的文本
```

**请求体:**
- 要输入的文本（UTF-8 编码）

**响应:**
```json
{
  "success": true,
  "method": "keyboard",  // 或 "clipboard" 用于中文
  "text": "输入的文本"
}
```

**示例:**
```bash
# 输入英文/数字（使用 HID 键盘事件）
curl -X POST \
  "http://192.168.1.100:8182/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "Hello123"

# 输入中文（使用剪贴板+粘贴）
curl -X POST \
  "http://192.168.1.100:8182/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！"

# 输入多行文本
curl -X POST \
  "http://192.168.1.100:8182/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "第一行
第二行
第三行"
```

```python
import requests

text = "你好，世界！Hello World!"

response = requests.post(
    "http://192.168.1.100:8182/api/input",
    data=text,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

**重要提示:**
- 输入前请确保目标输入框已获得焦点（看到键盘弹出）
- 某些 App 可能有限制，不支持外部输入
- 如果输入失败，尝试重新点击输入框获取焦点

---

### 7. 发送按键

发送单个按键事件到设备。

**请求:**
```
POST /api/key?code=<key-code>
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| code | integer | 是 | 按键代码（见下表） |

**常用按键代码:**
| 代码 | 按键 |
|------|------|
| 13 | 回车键 (Enter) |
| 8 | 退格键 (Backspace) |
| 9 | Tab 键 |
| 27 | Escape 键 |
| 32 | 空格键 |

**响应:**
```json
{
  "success": true,
  "code": 13
}
```

**示例:**
```bash
# 发送回车键
curl -X POST "http://192.168.1.100:8182/api/key?code=13"

# 发送退格键
curl -X POST "http://192.168.1.100:8182/api/key?code=8"

# 发送 Tab 键
curl -X POST "http://192.168.1.100:8182/api/key?code=9"
```

```python
import requests

# 发送回车键
response = requests.post("http://192.168.1.100:8182/api/key?code=13")
print(response.json())

# 发送退格键
response = requests.post("http://192.168.1.100:8182/api/key?code=8")
print(response.json())
```

---

### 8. 获取服务器状态

获取 HTTP 服务器运行状态。

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

### 9. 获取设备信息

获取设备名称、ID 和系统版本。

**请求:**
```
GET /api/device
```

**响应:**
```json
{
  "status": "ok",
  "deviceName": "iPhone",
  "deviceModelName": "iPhone14,2",
  "systemVersion": "15.1.1",
  "deviceIdentifier": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
}
```

**字段说明:**
| 字段 | 说明 |
|------|------|
| deviceName | 设备名称（用户在设置中定义的名称） |
| deviceModelName | 设备型号（如 iPhone14,2） |
| systemVersion | iOS 系统版本 |
| deviceIdentifier | 设备唯一标识符（UUID） |

**示例:**
```bash
curl "http://192.168.1.100:8182/api/device"
```

```python
import requests

response = requests.get("http://192.168.1.100:8182/api/device")
data = response.json()
print(f"设备: {data['deviceModelName']}")
print(f"系统: iOS {data['systemVersion']}")
print(f"名称: {data['deviceName']}")
```

---

### 10. 检查文件

检查 `/var/mobile/Media/zhuangtai.txt` 文件是否存在。

**请求:**
```
GET /api/checkfile
```

**响应:**
```json
{
  "status": "ok"  // 文件存在
}
```

或

```json
{
  "status": "no"  // 文件不存在
}
```

**示例:**
```bash
curl "http://192.168.1.100:8182/api/checkfile"
```

```python
import requests

response = requests.get("http://192.168.1.100:8182/api/checkfile")
data = response.json()
if data['status'] == 'ok':
    print("文件存在")
else:
    print("文件不存在")
```

---

### 11. 上传文件

上传任意文件到指定路径。如果目标文件夹不存在，会自动创建。

**请求:**
```
POST /api/upload?path=/var/mobile/Documents/myfolder/file.bin
Content-Type: application/octet-stream

<binary-file-content>
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| path | string | 是 | 目标文件完整路径（包含文件名） |

**请求体:**
- 文件的二进制内容

**响应:**
```json
{
  "success": true,
  "path": "/var/mobile/Documents/myfolder/file.bin",
  "bytes": 102456,
  "directory": "/var/mobile/Documents/myfolder",
  "created": true,  // 目录是否是本次创建的
  "modified": "2025-03-20 10:30:45"
}
```

**错误响应:**
```json
{
  "success": false,
  "error": "Failed to create directory",
  "details": "Permission denied",
  "path": "/var/mobile/Documents/myfolder"
}
```

**示例:**
```bash
# 上传单个文件
curl -X POST \
  "http://192.168.1.100:8182/api/upload?path=/var/mobile/Documents/photo.jpg" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @photo.jpg

# 上传文件到不存在的目录（自动创建）
curl -X POST \
  "http://192.168.1.100:8182/api/upload?path=/var/mobile/Documents/newfolder/data.txt" \
  -H "Content-Type: text/plain" \
  -d "Hello World!"

# 上传二进制文件
curl -X POST \
  "http://192.168.1.100:8182/api/upload?path=/var/mobile/Media/video.mp4" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @video.mp4
```

```python
import requests

# 上传文件
with open("photo.jpg", "rb") as f:
    file_data = f.read()

response = requests.post(
    "http://192.168.1.100:8182/api/upload?path=/var/mobile/Documents/photos/photo.jpg",
    data=file_data,
    headers={"Content-Type": "application/octet-stream"}
)
result = response.json()
if result['success']:
    print(f"上传成功: {result['path']}")
    print(f"文件大小: {result['bytes']} 字节")
    if result['created']:
        print(f"自动创建目录: {result['directory']}")
else:
    print(f"上传失败: {result['error']}")

# 直接上传文本内容
text_content = "这是要保存的文本内容"
response = requests.post(
    "http://192.168.1.100:8182/api/upload?path=/var/mobile/Documents/notes.txt",
    data=text_content.encode('utf-8'),
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

**Lua 示例:**
```lua
local http = require("socket.http")
local ltn12 = require("ltn12")

local function uploadFile(localPath, remotePath)
    local file = io.open(localPath, "rb")
    if not file then
        print("无法打开文件: " .. localPath)
        return
    end
    
    local content = file:read("*all")
    file:close()
    
    local response = {}
    local _, status = http.request{
        url = "http://192.168.1.100:8182/api/upload?path=" .. remotePath,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/octet-stream",
            ["Content-Length"] = tostring(#content)
        },
        source = ltn12.source.string(content),
        sink = ltn12.sink.table(response)
    }
    
    if status == 200 then
        local json = require("json")
        local result = json.decode(table.concat(response))
        if result.success then
            print("上传成功: " .. result.path)
            print("文件大小: " .. result.bytes .. " 字节")
        else
            print("上传失败: " .. (result.error or "未知错误"))
        end
    else
        print("HTTP 错误: " .. tostring(status))
    end
end

-- 使用示例
uploadFile("/var/mobile/photo.jpg", "/var/mobile/Documents/backup/photo.jpg")
```

**注意事项:**
- 支持任意文件类型（图片、视频、文本、二进制等）
- 如果目标目录不存在，会自动创建所有中间目录
- 如果文件已存在，会被覆盖
- 建议设置正确的 `Content-Type` 头，但不是必须的
- **大文件上传**: 超过 10MB 的文件会使用流式处理，最大支持约 500MB（受内存限制）
- **超时时间**: 5 分钟，大文件上传请确保网络稳定
- **推荐**: 对于超大文件（>100MB），建议分片上传或使用其他传输方式

---

## 错误响应

所有 API 在出错时返回以下格式的 JSON:

```json
{
  "error": "错误描述",
  "details": "详细错误信息（可选）"
}
```

HTTP 状态码:
- `200` - 成功
- `400` - 请求参数错误
- `500` - 服务器内部错误

---

## 使用示例

### Lua 示例 (在 iOS 设备上运行)

```lua
local http = require("socket.http")
local ltn12 = require("ltn12")
local base64 = require("base64")

local API_BASE = "http://192.168.1.100:8182"

-- 获取截图
local function getScreenshot()
    local response = {}
    local _, status = http.request{
        url = API_BASE .. "/api/screenshot?format=png",
        sink = ltn12.sink.table(response)
    }
    if status == 200 then
        local file = io.open("/var/mobile/screenshot.png", "wb")
        file:write(table.concat(response))
        file:close()
        print("截图已保存")
    end
end

-- 写入文件
local function writeFile(path, content)
    local encoded = base64.encode(content)
    local response = {}
    local _, status = http.request{
        url = API_BASE .. "/api/writefile?path=" .. path,
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain",
            ["Content-Length"] = tostring(#encoded)
        },
        source = ltn12.source.string(encoded),
        sink = ltn12.sink.table(response)
    }
    print("写入状态:", status)
end

-- 设置剪贴板
local function setClipboard(text)
    local encoded = base64.encode(text)
    http.request{
        url = API_BASE .. "/api/clipboard",
        method = "POST",
        headers = { ["Content-Type"] = "text/plain" },
        source = ltn12.source.string(encoded)
    }
end

-- 输入文本
local function inputText(text)
    http.request{
        url = API_BASE .. "/api/input",
        method = "POST",
        headers = { ["Content-Type"] = "text/plain; charset=utf-8" },
        source = ltn12.source.string(text)
    }
end

-- 使用示例
getScreenshot()
writeFile("/var/mobile/test.txt", "Hello World!")
setClipboard("复制这段文本")
inputText("你好，世界！")
```

---

### JavaScript 示例 (浏览器/Node.js)

```javascript
const API_BASE = 'http://192.168.1.100:8182';

// 获取截图
async function getScreenshot() {
    const response = await fetch(`${API_BASE}/api/screenshot?format=png`);
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    
    // 显示或下载图片
    const img = document.createElement('img');
    img.src = url;
    document.body.appendChild(img);
}

// 写入文件（纯文本 - 推荐）
async function writeFileText(path, content) {
    const response = await fetch(`${API_BASE}/api/writefile_text?path=${encodeURIComponent(path)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        body: content
    });
    return response.json();
}

// 设置剪贴板（纯文本 - 推荐）
async function setClipboardText(text) {
    const response = await fetch(`${API_BASE}/api/clipboard_text`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        body: text
    });
    return response.json();
}

// 输入文本到当前焦点输入框
async function inputText(text) {
    const response = await fetch(`${API_BASE}/api/input`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        body: text
    });
    return response.json();
}

// 发送按键
async function sendKey(keyCode) {
    const response = await fetch(`${API_BASE}/api/key?code=${keyCode}`, {
        method: 'POST'
    });
    return response.json();
}

// 使用示例
// inputText("你好，世界！");
// sendKey(13);  // 回车键
```

---

## 安全注意事项

1. **HTTP 服务器默认监听所有网络接口** (`0.0.0.0`)，局域网内任何设备都可以访问
2. **没有内置身份验证**，请确保在受信任的网络中使用
3. **建议措施**:
   - 仅在受信任的局域网中使用
   - 使用防火墙限制访问
   - 通过 VPN 或 SSH 隧道访问

---

## 故障排除

### 无法连接到 HTTP 服务器

1. 确认 TrollVNC 服务器已启动
2. 检查防火墙设置
3. 确认端口 8182 未被占用
4. 查看日志确认 HTTP 服务器是否成功启动

### 截图失败

1. 确认 TrollVNC 有屏幕录制权限
2. 检查设备是否处于锁定状态

### 文件写入失败

1. 确认目标路径有写入权限
2. 检查磁盘空间
3. 确认路径存在或父目录可写
4. **TrollStore 安装的应用**: 通过 TrollStore 安装的应用拥有更高的文件系统权限，可以访问更多路径

### 文本输入失败

1. **确保手机上有输入框获得焦点** - 必须先点击输入框，看到键盘弹出
2. 检查输入框类型是否支持（UITextField、UITextView 等）
3. 某些 App 可能有自定义输入框，可能不支持
4. 尝试重新点击输入框获取焦点

### 关于 TrollStore 安装

**TrollStore 安装的应用具有以下优势：**

- 可以访问沙盒外的文件系统
- 不需要越狱
- 拥有更多系统权限

**推荐的可写路径：**

```
/var/mobile/Documents/       # 用户文档目录
/var/mobile/Media/           # 媒体目录
/var/mobile/Library/         # 库目录（谨慎操作）
/var/tmp/                    # 临时目录
```

**注意：** 即使通过 TrollStore 安装，某些系统关键路径仍然受保护，不建议写入系统目录。

---

## 旧版 TCP 控制套接字

HTTP API 是新增的接口，原有的 TCP 控制套接字（默认 5555 端口）仍然可用。两者可以共存，互不影响。

