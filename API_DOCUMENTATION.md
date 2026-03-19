# TrollVNC HTTP API 文档

TrollVNC 现在提供 HTTP REST API 接口，默认在 **8080 端口**启动。

## 服务器信息

- **默认端口**: 8080
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
curl -o screenshot.png "http://192.168.1.100:8080/api/screenshot?format=png"

# 获取 JPEG 截图
curl -o screenshot.jpg "http://192.168.1.100:8080/api/screenshot?format=jpeg"
```

```python
import requests

response = requests.get("http://192.168.1.100:8080/api/screenshot?format=png")
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
  "http://192.168.1.100:8080/api/writefile?path=/var/mobile/test.txt" \
  -H "Content-Type: text/plain" \
  --data-binary @-

# 追加内容
echo -n "追加的内容" | base64 | curl -X POST \
  "http://192.168.1.100:8080/api/writefile?path=/var/mobile/test.txt&append=true" \
  -H "Content-Type: text/plain" \
  --data-binary @-
```

```python
import requests
import base64

content = "你好，世界！Hello World!"
encoded = base64.b64encode(content.encode()).decode()

response = requests.post(
    "http://192.168.1.100:8080/api/writefile?path=/var/mobile/test.txt",
    data=encoded,
    headers={"Content-Type": "text/plain"}
)
print(response.json())
```

---

### 3. 写入文件 (纯文本) ⭐

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
  "http://192.168.1.100:8080/api/writefile_text?path=/var/mobile/test.txt" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！Hello World!"

# 追加内容
curl -X POST \
  "http://192.168.1.100:8080/api/writefile_text?path=/var/mobile/test.txt&append=true" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "这是追加的内容"
```

```python
import requests

content = "你好，世界！Hello World!"

response = requests.post(
    "http://192.168.1.100:8080/api/writefile_text?path=/var/mobile/test.txt",
    data=content,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

---

### 4. 设置剪贴板 (Base64)

设置系统剪贴板内容（支持中文）。

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
  "success": true,
  "text": "你好，世界！"
}
```

**示例:**
```bash
# 设置剪贴板（中文）
echo -n "复制的文本内容" | base64 | curl -X POST \
  "http://192.168.1.100:8080/api/clipboard" \
  -H "Content-Type: text/plain" \
  --data-binary @-
```

```python
import requests
import base64

text = "你好，世界！Hello World! 🎉"
encoded = base64.b64encode(text.encode()).decode()

response = requests.post(
    "http://192.168.1.100:8080/api/clipboard",
    data=encoded,
    headers={"Content-Type": "text/plain"}
)
print(response.json())
```

---

### 5. 设置剪贴板 (纯文本) ⭐

直接发送纯文本内容到系统剪贴板，**无需 base64 编码**。

**请求:**
```
POST /api/clipboard_text
Content-Type: text/plain; charset=utf-8

纯文本内容，支持中文！
```

**请求体:**
- 纯文本内容（UTF-8 编码）

**响应:**
```json
{
  "success": true,
  "text": "你好，世界！"
}
```

**示例:**
```bash
# 直接设置剪贴板（推荐，更简单）
curl -X POST \
  "http://192.168.1.100:8080/api/clipboard_text" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！Hello World! 🎉"
```

```python
import requests

text = "你好，世界！Hello World! 🎉"

response = requests.post(
    "http://192.168.1.100:8080/api/clipboard_text",
    data=text,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

---

### 7. 输入文本到当前输入框 ⭐

将文本直接输入到当前获得焦点的输入框（如 UITextField、UITextView 等）。

**⚠️ 重要提示：**
- **TrollStore 安装的应用**才能使用此功能
- 需要先在手机上点击输入框，确保键盘弹出
- 中文输入使用剪贴板方式，英文/数字使用 HID 键盘事件

**使用步骤：**
1. 在手机上打开任意 App 并点击输入框（确保键盘弹出）
2. 调用此 API 发送文本

**请求:**
```
POST /api/input
Content-Type: text/plain; charset=utf-8

你好，世界！Hello World!
```

**请求体:**
- 纯文本内容（UTF-8 编码）

**响应:**
```json
// 成功
{
  "success": true,
  "text": "你好，世界！Hello World!",
  "length": 19
}

// 失败（没有焦点输入框）
{
  "success": false,
  "error": "No active text input field found. Please focus an input field first."
}
```

**示例:**
```bash
# 输入英文/数字（使用 HID 键盘事件）
curl -X POST \
  "http://192.168.1.100:8080/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "Hello123"

# 输入中文（使用剪贴板+粘贴）
curl -X POST \
  "http://192.168.1.100:8080/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "你好，世界！"

# 输入多行文本
curl -X POST \
  "http://192.168.1.100:8080/api/input" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d "第一行
第二行
第三行"
```

```python
import requests

# 输入文本到当前焦点输入框
text = "你好，世界！Hello World! 🎉"

response = requests.post(
    "http://192.168.1.100:8080/api/input",
    data=text,
    headers={"Content-Type": "text/plain; charset=utf-8"}
)
print(response.json())
```

**工作原理:**
- **ASCII 字符**（英文、数字、符号）：使用 HID 键盘事件逐个发送
- **非 ASCII 字符**（中文、日文等）：使用剪贴板+粘贴方式

**支持的输入框类型:**
- UITextField（单行输入框）
- UITextView（多行文本框）
- 任何实现 UITextInput 协议的自定义输入框

---

### 8. 发送按键

发送单个按键事件到当前焦点输入框。

**请求:**
```
POST /api/key?code=13
```

**参数:**
| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| code | integer | 是 | 按键码 |

**常用按键码:**
| 按键码 | 说明 |
|--------|------|
| 13 | 回车键 (Enter/Return) |
| 8 | 退格键 (Backspace) |
| 9 | Tab 键 |
| 27 | ESC 键 |
| 32 | 空格键 |

**响应:**
```json
{
  "success": true,
  "keyCode": 13
}
```

**示例:**
```bash
# 发送回车键
curl -X POST "http://192.168.1.100:8080/api/key?code=13"

# 发送退格键
curl -X POST "http://192.168.1.100:8080/api/key?code=8"

# 发送 Tab 键
curl -X POST "http://192.168.1.100:8080/api/key?code=9"
```

```python
import requests

# 发送回车键
response = requests.post("http://192.168.1.100:8080/api/key?code=13")
print(response.json())

# 发送退格键
response = requests.post("http://192.168.1.100:8080/api/key?code=8")
print(response.json())
```

---

### 9. 获取客户端列表

获取当前连接的 VNC 客户端列表。

**请求:**
```
GET /api/clients
```

**响应:**
```json
{
  "clients": [
    {
      "id": "A1B2C3D4",
      "host": "192.168.1.50",
      "viewOnly": false,
      "connectedAt": 1699123456,
      "durationSec": 3600
    }
  ],
  "count": 1
}
```

---

### 10. 获取服务器状态

获取 TrollVNC 服务器状态信息。

**请求:**
```
GET /api/status
```

**响应:**
```json
{
  "status": "running",
  "httpPort": 8080,
  "version": "3.1"
}
```

---

### 11. API 文档页面

在浏览器中查看 API 文档。

**请求:**
```
GET /
```

**响应:**
- 返回 HTML 格式的 API 文档页面

---

## Lua 使用示例

```lua
local http = require("socket.http")
local ltn12 = require("ltn12")
local base64 = require("base64")

local API_BASE = "http://192.168.1.100:8080"

-- 获取截图
local function downloadScreenshot(savePath)
    local response = {}
    http.request{
        url = API_BASE .. "/api/screenshot?format=png",
        sink = ltn12.sink.table(response)
    }
    
    local file = io.open(savePath, "wb")
    file:write(table.concat(response))
    file:close()
    print("截图已保存到: " .. savePath)
end

-- 写入文件 (Base64)
local function writeFile(path, content, append)
    local encoded = base64.encode(content)
    local url = API_BASE .. "/api/writefile?path=" .. path
    if append then
        url = url .. "&append=true"
    end
    
    local response = {}
    http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain",
            ["Content-Length"] = tostring(#encoded)
        },
        source = ltn12.source.string(encoded),
        sink = ltn12.sink.table(response)
    }
    
    return table.concat(response)
end

-- 写入文件 (纯文本) - 更简单，推荐！
local function writeFileText(path, content, append)
    local url = API_BASE .. "/api/writefile_text?path=" .. path
    if append then
        url = url .. "&append=true"
    end
    
    local response = {}
    http.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain; charset=utf-8",
            ["Content-Length"] = tostring(#content)
        },
        source = ltn12.source.string(content),
        sink = ltn12.sink.table(response)
    }
    
    return table.concat(response)
end

-- 设置剪贴板 (Base64)
local function setClipboard(text)
    local encoded = base64.encode(text)
    local response = {}
    http.request{
        url = API_BASE .. "/api/clipboard",
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain",
            ["Content-Length"] = tostring(#encoded)
        },
        source = ltn12.source.string(encoded),
        sink = ltn12.sink.table(response)
    }
    return table.concat(response)
end

-- 设置剪贴板 (纯文本) - 更简单，推荐！
local function setClipboardText(text)
    local response = {}
    http.request{
        url = API_BASE .. "/api/clipboard_text",
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain; charset=utf-8",
            ["Content-Length"] = tostring(#text)
        },
        source = ltn12.source.string(text),
        sink = ltn12.sink.table(response)
    }
    return table.concat(response)
end

-- 输入文本到当前焦点输入框
local function inputText(text)
    local response = {}
    http.request{
        url = API_BASE .. "/api/input",
        method = "POST",
        headers = {
            ["Content-Type"] = "text/plain; charset=utf-8",
            ["Content-Length"] = tostring(#text)
        },
        source = ltn12.source.string(text),
        sink = ltn12.sink.table(response)
    }
    return table.concat(response)
end

-- 发送按键
local function sendKey(keyCode)
    local response = {}
    http.request{
        url = API_BASE .. "/api/key?code=" .. tostring(keyCode),
        method = "POST",
        sink = ltn12.sink.table(response)
    }
    return table.concat(response)
end

-- 使用示例
downloadScreenshot("/tmp/ios_screen.png")
writeFileText("/var/mobile/notes.txt", "你好，世界！")  -- 推荐！
setClipboardText("复制的文本")  -- 推荐！

-- 输入文本到当前输入框（确保手机上有输入框获得焦点）
inputText("你好，世界！")
inputText("这是自动输入的内容")

-- 发送按键
sendKey(13)   -- 回车键
sendKey(8)    -- 退格键
```

---

## JavaScript/浏览器使用示例

```javascript
const API_BASE = 'http://192.168.1.100:8080';

// 获取截图
async function captureScreenshot() {
    const response = await fetch(`${API_BASE}/api/screenshot?format=png`);
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    
    // 显示图片
    const img = document.createElement('img');
    img.src = url;
    document.body.appendChild(img);
}

// 写入文件 (Base64)
async function writeFile(path, content) {
    const encoded = btoa(unescape(encodeURIComponent(content)));
    const response = await fetch(`${API_BASE}/api/writefile?path=${encodeURIComponent(path)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: encoded
    });
    return response.json();
}

// 写入文件 (纯文本) - 更简单，推荐！
async function writeFileText(path, content) {
    const response = await fetch(`${API_BASE}/api/writefile_text?path=${encodeURIComponent(path)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
        body: content
    });
    return response.json();
}

// 设置剪贴板 (Base64)
async function setClipboard(text) {
    const encoded = btoa(unescape(encodeURIComponent(text)));
    const response = await fetch(`${API_BASE}/api/clipboard`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: encoded
    });
    return response.json();
}

// 设置剪贴板 (纯文本) - 更简单，推荐！
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
3. 确认端口 8080 未被占用
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

- ✅ 可以访问沙盒外的文件系统
- ✅ 不需要越狱
- ✅ 拥有更多系统权限

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
