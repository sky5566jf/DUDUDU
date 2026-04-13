# TrollVNC 开发文档

## 目录

- [项目概述](#项目概述)
- [项目结构](#项目结构)
- [HTTP API 接口](#http-api-接口)
- [核心模块说明](#核心模块说明)
- [开发构建](#开发构建)
- [扩展开发](#扩展开发)

---

## 项目概述

**TrollVNC** 是一个运行在 iOS 设备上的 VNC 服务器，允许远程访问和控制设备的屏幕。

### 主要特性

- 低延迟屏幕捕获，支持缩放、帧率控制和背压
- 可选的脏区更新，节省带宽
- 可调滚轮手势和自然方向切换
- UTF-8 剪贴板同步（UltraVNC）
- 方向同步和旋转感知输入映射
- 可选的服务器端光标叠加
- 经典 VNC 认证（完全访问和只读密码）
- 内置 HTTP/WebSockets 浏览器访问（HTTPS/WSS 支持）
- Bonjour/mDNS 局域网自动发现
- 反向 VNC 连接

---

## 项目结构

```
TrollVNC/
├── src/                    # 核心源代码
│   ├── trollvncserver.mm   # 主程序入口
│   ├── TVNCHttpServer.mm   # HTTP 服务器实现
│   ├── TVNCApiManager.h/mm # API 管理器
│   ├── ScreenCapturer.h/mm # 屏幕截图
│   └── STHIDEventGenerator.h/mm # HID 事件生成
├── prefs/                  # 设置相关
│   ├── TVNCPrefs.bundle/   # 设置界面包
│   └── TrollVNCPrefs/      # 设置实现
├── layout/                 # 布局文件（Web 前端）
│   └── usr/share/trollvnc/
│       └── webclients/novnc/  # noVNC Web 客户端
├── app/                    # iOS 应用相关
├── include/                # 公共头文件
├── lib/                    # 预编译库
├── devkit/                 # 开发工具脚本
└── scripts/                # 构建脚本
```

---

## HTTP API 接口

基础地址：`http://<设备IP>:8182`

### 设备信息类

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/device` | 获取设备信息 |
| GET | `/api/status` | 服务器状态 |
| GET | `/api/clients` | VNC 客户端列表 |

### 截图类

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/screenshot` | 获取屏幕截图 |

**参数：**
- `format`: `png` 或 `jpeg`（默认 `png`）
- `quality`: JPEG 质量 0.0~1.0（默认 0.9）
- `rotation`: 旋转角度 0/90/180/270
- `scale`: 缩放比例 0.1~1.0（默认 1.0）

### 输入控制类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/input` | 输入文本 |
| POST | `/api/key?code=13` | 发送按键 |
| POST | `/api/clipboard` | 设置剪贴板(base64) |
| POST | `/api/clipboard_text` | 设置剪贴板(纯文本) |
| GET | `/api/clipboard_text` | 获取剪贴板 |

**常用按键代码：**
- `13`: 回车键 (Enter)
- `8`: 退格键 (Backspace)
- `9`: Tab 键
- `27`: Escape 键
- `32`: 空格键

### 文件操作类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/writefile` | 写入文件(base64) |
| POST | `/api/writefile_text` | 写入文本文件 |
| POST | `/api/upload` | 上传文件 |
| GET | `/api/checkfile` | 检查状态文件 |

### 系统控制类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/reboot` | 重启设备 |
| POST | `/api/respring` | 注销 SpringBoard |
| POST | `/api/screen/lock` | 锁定屏幕 |
| POST | `/api/screen/unlock` | 解锁屏幕 |
| POST | `/api/home` | 按 Home 键 |
| POST | `/api/taskmanager` | 打开任务管理器 |
| GET/POST | `/api/volume` | 获取/设置音量 (0.0~1.0) |
| GET/POST | `/api/brightness` | 获取/设置亮度 (0.0~1.0) |

### 应用管理类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/install?path=/xxx/app.ipa` | 安装应用 |
| POST | `/api/uninstall?bundleId=xxx` | 卸载应用 |
| GET | `/api/trollstore/diagnostics` | TrollStore 诊断 |

### 自动解锁类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/autounlock/enable` | 启用自动解锁 |
| POST | `/api/autounlock/disable` | 禁用自动解锁 |
| GET | `/api/autounlock/status` | 获取状态 |
| POST | `/api/autounlock/check` | 检查解锁 |

### 后台清理类

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/clearapps/smart` | 智能清理后台 |

### 辅助功能类

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/assistivetouch` | 获取小白点状态 |
| POST | `/api/assistivetouch?action=enable` | 启用小白点 |
| POST | `/api/assistivetouch?action=disable` | 禁用小白点 |

### 其他类

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/trigger?port=3333&delay=5` | 触发懒人精灵 |
| GET | `/` | API 文档首页 |

---

## 核心模块说明

### TVNCApiManager

API 管理器，单例模式，负责处理所有业务逻辑。

**核心方法：**

```objc
// 单例获取
+ (instancetype)sharedManager;

// 截图
- (nullable NSData *)captureScreenshotAsPNG;
- (nullable NSData *)captureScreenshotAsJPEGWithQuality:(CGFloat)quality;
- (nullable NSData *)captureScreenshotWithFormat:(CFStringRef)format 
                                         quality:(CGFloat)quality 
                                       rotation:(NSInteger)rotation 
                                          scale:(CGFloat)scale;

// 输入控制
- (BOOL)inputText:(NSString *)text;
- (BOOL)sendKeyEvent:(NSInteger)keyCode;

// 剪贴板
- (BOOL)setClipboardText:(NSString *)text;
- (nullable NSString *)getClipboardText;

// 文件操作
- (BOOL)writeContent:(NSData *)content 
           toFilePath:(NSString *)path 
               append:(BOOL)append 
                error:(NSError **)error;
```

### TVNCHttpServer

HTTP 服务器，处理 HTTP 请求和路由分发。

**路由处理流程：**
```
请求 → 解析方法/路径/参数 → 路由匹配 → 调用 Handler → 返回响应
```

**主要 Handler：**
- `handleScreenshot:` - 截图处理
- `handleInput:body:` - 文本输入
- `handleKey:` - 按键事件
- `handleReboot:` - 重启设备
- `handleRespring:` - 注销系统
- `handleScreenLock:` - 锁屏
- `handleScreenUnlock:` - 解锁

### STHIDEventGenerator

HID 事件生成器，用于模拟触摸和按键事件。

**主要方法：**
```objc
// 触摸事件
- (void)sendTouchBeganAtX:(CGFloat)x Y:(CGFloat)y;
- (void)sendTouchMovedAtX:(CGFloat)x Y:(CGFloat)y;
- (void)sendTouchEndedAtX:(CGFloat)x Y:(CGFloat)y;

// 按键事件
- (void)sendKeyDown:(uint32_t)keyCode;
- (void)sendKeyUp:(uint32_t)keyCode;
- (void)sendKeyDown:(uint32_t)keyCode options:(uint32_t)options;
```

---

## 开发构建

### 环境要求

- Xcode 15.4+
- theos
- iOS SDK 17.0+
- macOS 13+

### 本地构建

1. 克隆仓库：
```bash
git clone https://github.com/sky5566jf/TrollVNC.git
cd TrollVNC
```

2. 初始化 theos 子模块：
```bash
make init
```

3. 构建：
```bash
make package
```

### GitHub Actions 构建

1. Fork 仓库
2. 进入 Actions → Build TrollVNC → Run workflow
3. 选择参数并运行

**可配置参数：**
- `is_managed`: 是否使用托管配置
- `desktop_name`: 桌面名称
- `port`: VNC 端口（默认 5901）
- `view_only`: 只读模式
- `scale`: 缩放比例
- `frame_rate_spec`: 帧率规格

### 构建产物

| 产物 | 说明 |
|------|------|
| `packages-default/` | 标准安装包 |
| `packages-rootless/` | Rootless 版 |
| `packages-roothide/` | Roothide 版 |
| `packages-bootstrap/` | Bootstrap 版 |

---

## 扩展开发

### 添加新的 API 接口

1. 在 `TVNCHttpServer.mm` 的 `handleRequest:path:query:body:clientAddr:` 方法中添加路由：
```objc
} else if ([path isEqualToString:@"/api/your_endpoint"]) {
    return [self handleYourEndpoint:query body:body];
}
```

2. 实现 Handler 方法：
```objc
- (TVNCHttpResponse *)handleYourEndpoint:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 业务逻辑
    NSString *result = [[TVNCApiManager sharedManager] yourMethod];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *data = @{@"result": result};
    response.body = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    
    return response;
}
```

### 调用私有 API

使用 `dlopen` 和 `dlsym` 动态加载私有 framework：

```objc
#import <dlfcn.h>

- (void)callPrivateAPI {
    // 加载 SpringBoardServices
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (handle) {
        // 获取函数指针
        CFStringRef (*SBSCopyFrontmostApplicationDisplayIdentifier)(void) = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
        
        if (SBSCopyFrontmostApplicationDisplayIdentifier) {
            CFStringRef result = SBSCopyFrontmostApplicationDisplayIdentifier();
            // 处理结果
            CFRelease(result);
        }
        
        dlclose(handle);
    }
}
```

### noVNC 扩展

noVNC 文件位于 `layout/usr/share/trollvnc/webclients/novnc/`

主要文件：
- `vnc.html` - 主页面
- `core/rfb.js` - RFB 协议实现
- `core/ui.js` - UI 逻辑

---

## 常见问题

### 编译错误：CMItemCount

如果遇到 `CMItemCount` 相关错误，在头文件中添加：
```objc
#ifndef CMItemCount
#define CMItemCount int32_t
#endif
```

### HTTP API 无法访问

1. 确认 TrollVNC 服务已启动
2. 检查防火墙设置
3. 确认端口 8182 未被占用

### 截图失败

1. 确认 TrollVNC 有屏幕录制权限
2. 检查设备是否处于锁定状态

---

## 相关链接

- [GitHub 仓库](https://github.com/sky5566jf/TrollVNC)
- [LibVNCServer](https://github.com/LibVNC/libvncserver)
- [noVNC](https://github.com/novnc/noVNC)
- [BuildVNCServer](https://github.com/Lessica/BuildVNCServer)
