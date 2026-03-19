# TrollVNC 扩展 API 文档

本文档描述了 TrollVNC 新增的 API 接口功能。

## 概述

新增的三个 API 功能：
1. **截图 API** - 获取设备屏幕截图原图
2. **文件写入 API** - 向指定路径写入文件内容
3. **剪贴板 API** - 支持中文的粘贴功能

## 控制套接字命令

通过控制套接字（使用 `-c` 参数启用）可以访问这些 API。

### 1. 截图命令

获取设备屏幕截图，支持 PNG 和 JPEG 格式。

**命令格式：**
```
screenshot [format] [path]
```

**参数：**
- `format` - 可选，图片格式：`png` 或 `jpeg`（默认：`png`）
- `path` - 可选，保存路径。如果不指定，返回 base64 编码的图片数据

**示例：**

1. 获取 PNG 格式的 base64 编码图片：
```
echo "screenshot png" | nc 127.0.0.1 5555
```

2. 保存截图到文件：
```
echo "screenshot png /var/mobile/screenshot.png" | nc 127.0.0.1 5555
```

3. 获取 JPEG 格式（质量 90%）：
```
echo "screenshot jpeg /var/mobile/screenshot.jpg" | nc 127.0.0.1 5555
```

**响应：**
- 成功（无路径）：`OK png\n<base64-encoded-image>`
- 成功（有路径）：`OK 12345 bytes written to /path/to/file.png`
- 失败：`ERR ScreenshotFailed` 或 `ERR WriteFailed: <reason>`

### 2. 文件写入命令

将内容写入指定文件路径。

**命令格式：**
```
writefile <path> [append]
<base64-encoded-content>
```

**参数：**
- `path` - 必需，目标文件路径
- `append` - 可选，追加模式。如果指定，内容将追加到文件末尾

**示例：**

1. 写入新文件：
```bash
CONTENT=$(echo -n "Hello World" | base64)
echo -e "writefile /var/mobile/test.txt\n${CONTENT}" | nc 127.0.0.1 5555
```

2. 追加到现有文件：
```bash
CONTENT=$(echo -n "追加的内容" | base64)
echo -e "writefile /var/mobile/test.txt append\n${CONTENT}" | nc 127.0.0.1 5555
```

**响应：**
- 成功：`OK`
- 失败：`ERR MissingPath`、`ERR InvalidBase64` 或 `ERR <error-message>`

### 3. 剪贴板命令

设置设备剪贴板内容，支持中文。

**命令格式：**
```
clipboard <base64-encoded-text>
```

**参数：**
- `base64-encoded-text` - 必需，base64 编码的文本内容

**示例：**

1. 设置英文文本：
```bash
TEXT=$(echo -n "Hello World" | base64)
echo "clipboard ${TEXT}" | nc 127.0.0.1 5555
```

2. 设置中文文本：
```bash
TEXT=$(echo -n "你好，世界！" | base64)
echo "clipboard ${TEXT}" | nc 127.0.0.1 5555
```

**响应：**
- 成功：`OK`
- 失败：`ERR MissingContent`、`ERR InvalidBase64`、`ERR InvalidUTF8` 或 `ERR ClipboardSetFailed`

## 编程语言示例

### Python 示例

```python
import socket
import base64

def send_command(cmd, host="127.0.0.1", port=5555):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((host, port))
        s.sendall(cmd.encode() + b"\n")
        response = s.recv(65536).decode()
        return response

# 截图并保存
def capture_screenshot(output_path):
    # 保存到文件
    response = send_command(f"screenshot png {output_path}")
    print(response)
    
    # 或者获取 base64 数据
    response = send_command("screenshot png")
    lines = response.strip().split("\n")
    if lines[0].startswith("OK"):
        img_data = base64.b64decode(lines[1])
        with open(output_path, "wb") as f:
            f.write(img_data)
        print(f"Screenshot saved to {output_path}")

# 写入文件
def write_file(path, content, append=False):
    encoded = base64.b64encode(content.encode()).decode()
    cmd = f"writefile {path}"
    if append:
        cmd += " append"
    response = send_command(f"{cmd}\n{encoded}")
    print(response)

# 设置剪贴板
def set_clipboard(text):
    encoded = base64.b64encode(text.encode()).decode()
    response = send_command(f"clipboard {encoded}")
    print(response)

# 使用示例
if __name__ == "__main__":
    # 截图
    capture_screenshot("/var/mobile/screenshot.png")
    
    # 写入文件
    write_file("/var/mobile/test.txt", "Hello, 中文测试！")
    
    # 设置剪贴板（支持中文）
    set_clipboard("这是中文粘贴测试")
```

### Shell/Bash 示例

```bash
#!/bin/bash

TVNC_HOST="127.0.0.1"
TVNC_PORT="5555"

# 截图函数
screenshot() {
    local format=${1:-png}
    local path=$2
    
    if [ -n "$path" ]; then
        echo "screenshot $format $path" | nc $TVNC_HOST $TVNC_PORT
    else
        echo "screenshot $format" | nc $TVNC_HOST $TVNC_PORT
    fi
}

# 写入文件函数
writefile() {
    local path=$1
    local content=$2
    local append=$3
    
    local encoded=$(echo -n "$content" | base64)
    local cmd="writefile $path"
    [ "$append" = "append" ] && cmd="$cmd append"
    
    printf "%s\n%s\n" "$cmd" "$encoded" | nc $TVNC_HOST $TVNC_PORT
}

# 设置剪贴板函数
set_clipboard() {
    local text=$1
    local encoded=$(echo -n "$text" | base64)
    echo "clipboard $encoded" | nc $TVNC_HOST $TVNC_PORT
}

# 使用示例
screenshot png /var/mobile/screenshot.png
writefile /var/mobile/notes.txt "这是一条笔记"
set_clipboard "中文粘贴测试"
```

## 中文支持说明

### 剪贴板中文支持

TrollVNC 现在完全支持中文剪贴板操作：

1. **接收中文** - 当 VNC 客户端发送中文到设备时，系统会自动检测以下编码：
   - UTF-8（标准编码）
   - UTF-16
   - GB18030（中文国标）
   - EUC-CN（中文扩展 Unix 编码）
   - Latin-1（回退编码）

2. **发送中文** - 当设备剪贴板内容同步到 VNC 客户端时，使用 UTF-8 编码

### 文件写入中文支持

文件写入 API 使用 UTF-8 编码处理所有文本内容，确保中文文件名和内容都能正确处理。

## 错误处理

所有 API 命令在失败时都会返回以 `ERR` 开头的错误消息。常见错误：

| 错误代码 | 说明 |
|---------|------|
| `ERR Empty` | 命令为空 |
| `ERR Unknown` | 未知命令 |
| `ERR ScreenshotFailed` | 截图失败 |
| `ERR WriteFailed` | 文件写入失败 |
| `ERR MissingPath` | 缺少文件路径参数 |
| `ERR MissingContent` | 缺少内容参数 |
| `ERR InvalidBase64` | Base64 编码无效 |
| `ERR InvalidUTF8` | UTF-8 编码无效 |
| `ERR ClipboardSetFailed` | 剪贴板设置失败 |

## 安全注意事项

1. **文件路径** - 确保应用程序有权限写入指定的文件路径
2. **控制套接字** - 控制套接字默认只监听 `127.0.0.1`，外部无法直接访问
3. **路径遍历** - API 不会阻止路径遍历攻击，请确保传入的路径是可信的

## 限制

1. 截图功能需要屏幕捕获权限
2. 文件写入受 iOS 沙盒限制
3. 控制套接字命令最大长度为 1024 字节（base64 内容除外）
