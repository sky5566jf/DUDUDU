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

### 2. 写入文件

将内容写入指定文件路径。

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

### 3. 设置剪贴板

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

### 4. 获取客户端列表

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

### 5. 获取服务器状态

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

### 6. API 文档页面

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

-- 写入文件
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

-- 设置剪贴板
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

-- 使用示例
downloadScreenshot("/tmp/ios_screen.png")
writeFile("/var/mobile/notes.txt", "你好，世界！")
setClipboard("复制的文本")
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

// 写入文件
async function writeFile(path, content) {
    const encoded = btoa(unescape(encodeURIComponent(content)));
    const response = await fetch(`${API_BASE}/api/writefile?path=${encodeURIComponent(path)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: encoded
    });
    return response.json();
}

// 设置剪贴板
async function setClipboard(text) {
    const encoded = btoa(unescape(encodeURIComponent(text)));
    const response = await fetch(`${API_BASE}/api/clipboard`, {
        method: 'POST',
        headers: { 'Content-Type': 'text/plain' },
        body: encoded
    });
    return response.json();
}
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

---

## 旧版 TCP 控制套接字

HTTP API 是新增的接口，原有的 TCP 控制套接字（默认 5555 端口）仍然可用。两者可以共存，互不影响。
