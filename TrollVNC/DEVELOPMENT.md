# MatisuXCS / TrollVNC 开发文档

> 内部工程名仍为 **TrollVNC**（代码、bundle、设置域均以此命名），对外分发产物统一使用 **MatisuXCS** 前缀。下文以「TrollVNC / 巨魔版」指代 bootstrap 构建，「MatisuXCS / 越狱版」指代 deb 构建。

## 目录

- [项目概述](#项目概述)
- [项目结构](#项目结构)
- [构建变体与条件编译](#构建变体与条件编译)
- [产物命名与分发](#产物命名与分发)
- [偏好域约定（重要）](#偏好域约定重要)
- [重启自启机制](#重启自启机制)
- [HTTP API 接口](#http-api-接口)
- [核心模块说明](#核心模块说明)
- [开发构建](#开发构建)
- [扩展开发](#扩展开发)
- [常见问题与经验教训](#常见问题与经验教训)
- [相关链接](#相关链接)

---

## 项目概述

**MatisuXCS（TrollVNC）** 是一个运行在 iOS 设备上的 VNC 服务器，允许远程访问和控制设备的屏幕。

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
- 两种分发形态：**巨魔版（TrollStore，无越狱）** 与 **越狱版（deb，支持 default/rootless/roothide）**

---

## 项目结构

```
仓库根/
├── Makefile                     # 根构建（版本号 PACKAGE_VERSION、THEBOOTSTRAP 条件）
├── prefs/TrollVNCPrefs/         # 设置面板实现（Root.plist / Managed.plist / TVNCRootListController）
│   └── Resources/Root.plist      # 设置 UI 源（巨魔版 & 越狱版共用）
├── app/
│   ├── TrollVNC/                # 巨魔版子工程（Xcode app → .tipa）
│   │   ├── TrollVNC/            # App 源码（AppDelegate / TVNCHotspotManager / TVNCServiceCoordinator ...）
│   │   ├── TrollVNC.xcodeproj/
│   │   └── Makefile             # 设定 THEBOOTSTRAP=1
│   └── MatisuXCS/               # 越狱版子工程（deb）
├── devkit/                      # 构建脚本（default/rootless/roothide/bootstrap.sh 等）
│   ├── default.sh rootless.sh roothide.sh bootstrap.sh   # 各 scheme 环境变量
│   ├── before-package.sh        # 打包前处理（bundle 整合、entitlements、rootless 路径修正）
│   ├── after-package.sh         # bootstrap 打包成 .tipa
│   └── gen-managed-plist.sh     # 由 workflow 输入生成 Managed.plist
├── TrollVNC/                    # 越狱版 theos 主工程（src/ prefs/ layout/ include/ lib/）
│   ├── src/                     # 核心源码（trollvncserver.mm / TVNCHttpServer / TVNCApiManager ...）
│   ├── layout/                  # 布局（LaunchDaemon plist、web 前端）
│   └── Makefile
├── layout/Library/LaunchDaemons/com.82flex.trollvnc.plist  # 越狱版开机自启
├── .github/workflows/build.yml  # GitHub Actions CI
└── build_output/                # 本地产物归档（同步来自 E:\lmp\ipa）
```

---

## 构建变体与条件编译

仓库同时产出 **4 个产物**（见 [产物命名与分发](#产物命名与分发)），由 `THEBOOTSTRAP` 宏和 `THEOS_PACKAGE_SCHEME` 决定。

### 两种工程形态

| 形态 | 入口子工程 | 条件编译 | 产物格式 | 适用场景 |
|------|-----------|---------|---------|---------|
| 巨魔版 | `app/TrollVNC`（Xcode app） | `THEBOOTSTRAP=1` | `.tipa` | TrollStore 安装，**无越狱** |
| 越狱版 | `app/MatisuXCS` + `TrollVNC/`（theos） | 无 THEBOOTSTRAP | `.deb` | 越狱环境（Dopamine / TrollStore Helper 等） |

- 根 `Makefile` 第 140 行：`ifeq ($(THEBOOTSTRAP),1)` 时 `SUBPROJECTS += app/TrollVNC`，否则 `app/MatisuXCS`。
- 巨魔版 App 自身 bundle id 为 `com.matisu.xcs`（`app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj`）。
- 巨魔版需要 `HotspotHelper` / `HotspotConfiguration` entitlements（`app/TrollVNC/TrollVNC/TrollVNC.entitlements`）；TrollStore permasign 会保留这些 entitlement。

### 4 个构建 scheme（CI matrix）

`build.yml` 的 `strategy.matrix.scheme`：

| scheme | THEOS_PACKAGE_SCHEME | THEBOOTSTRAP | 原始文件名（Release） | 含义 |
|--------|---------------------|-------------|----------------------|------|
| `default` | （空） | 否 | `com.82flex.trollvnc_<ver>_iphoneos-arm.deb` | 标准越狱（legacy 路径 `/usr/bin`） |
| `rootless` | `rootless` | 否 | `com.82flex.trollvnc_<ver>_iphoneos-arm64.deb` | Rootless 越狱（`/var/jb/usr/bin`，LaunchDaemon 路径由 `before-package.sh` 改写） |
| `roothide` | `roothide` | 否 | `com.82flex.trollvnc_<ver>_iphoneos-arm64e.deb` | RootHide 越狱 |
| `bootstrap` | `roothide`（复用 roothide 工具链） | **是** | `TrollVNC_<ver>.tipa` | 巨魔版（TrollStore） |

> 注意：`bootstrap.sh` 故意把 `THEOS_PACKAGE_SCHEME=roothide`（仅借用其 theos 工具链），但配合 `THEBOOTSTRAP=1` 最终产出的是 `.tipa` 而非 deb。

---

## 产物命名与分发

### 版本号

- 单一来源：`Makefile` 顶部 `export PACKAGE_VERSION := 3.53`。每次修改逻辑后**升一位**（3.50→3.51→3.52→3.53）。
- CI 的 `release` job 读取该值生成 tag `v<版本号>` 并创建 GitHub Release。

### 对外命名规范（MatisuXCS 前缀）

GitHub Release 原始文件名是 `TrollVNC_*` / `com.82flex.trollvnc_*`，**分发时统一重命名为 `MatisuXCS` 前缀**：

| 原始文件 | 重命名后 | 说明 |
|----------|---------|------|
| `TrollVNC_<ver>.tipa` | `MatisuXCS_<ver>.tipa` | 巨魔版 |
| `com.82flex.trollvnc_<ver>_iphoneos-arm.deb` | `MatisuXCS_<ver>_default.deb` | 越狱默认版 |
| `com.82flex.trollvnc_<ver>_iphoneos-arm64.deb` | `MatisuXCS_<ver>_rootless.deb` | rootless |
| `com.82flex.trollvnc_<ver>_iphoneos-arm64e.deb` | `MatisuXCS_<ver>_roothide.deb` | roothide |

落盘位置：下载到 `E:\lmp\ipa\`，并同步到仓库 `build_output/`。

---

## 偏好域约定（重要）

这是一个容易踩坑的点：

- App 自身 bundle id = `com.matisu.xcs`（巨魔版）。
- 但**所有 TrollVNC 设置**（含 `PSSwitchCell` 写入、读取）都使用偏好域 **`com.82flex.trollvnc`**，而不是 App 的标准域。

正确读取方式（`TVNCServiceCoordinator.m:82`）：

```objc
_userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
```

`Root.plist` 中每个 `PSSwitchCell` 的 `<key>defaults</key>` 也必须写 `com.82flex.trollvnc`。**用 `standardUserDefaults` 读取开关会永远返回 NO**——这是 v3.51 曾经犯过、已修复的 bug。

---

## 重启自启机制

这是本项目在巨魔版（无越狱）场景下最棘手的部分。结论先行：**纯 TrollStore 没有可靠的系统级冷启动自启机制，唯一的系统级唤醒源是「真实 WiFi 关联」。**

### 巨魔版（bootstrap，无越狱）

重启后 App 进程是"死的"，必须由系统事件把它唤醒。

**唤醒源：`NEHotspotHelper`**（`TVNCHotspotManager.m`）

- `didFinishLaunchingWithOptions:` 中调用 `[[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"]`，注册 `NEHotspotHelper`。
- 当 WiFi 发生关联类事件（`Evaluate` / `Authenticate` / `Maintain` / `PresentUI`）时，系统唤醒 App 并回调 handler → `executeAutoStartupTaskIfNecessary` → `ensureServiceRunning` 启动 VNC 服务。
- 这些命令是 **L2 关联事件（手机连上某个真实 AP）**，与"该 AP 是否有互联网"无关。所以：
  - ✅ 关联到一个**真实 WiFi（有网/没网都行）** → 能唤醒自启。
  - ❌ **纯以太网（不关联任何真实 WiFi）** → 重启后 App 不会被 NEHotspotHelper 唤醒 → **无自启**。

**`SCNetworkReachability` 监控**（`startNetworkReachabilityMonitor`）

- 监听"任意网络可用（WiFi/Ethernet/Cellular）"，在网络从不可达变可达时触发 `executeAutoStartupTaskIfNecessary`。
- ⚠️ 它只在 **App 进程存活时** 有效（用于前后台切换、网络变化后补启服务）。**它无法解决"冷启动"问题**——重启后进程已死，监控器根本没在跑，直到 App 被别的方式唤醒。

**已废弃方案（v3.50–v3.52 引入，v3.53 已彻底移除）：虚拟 WiFi SSID**

- 曾尝试在系统 WiFi 配置里保存一个不存在的网络 `MatisuXCS-AutoStart-Trigger`，期望 iOS 重启后持续扫描从而唤醒 App。
- 实测无效：WiFi 关联需要真实 AP 在范围内广播 beacon，虚拟 SSID 无任何无线电广播，手机永远关联不上，NEHotspotHelper 永不触发。该方案在纯 TrollStore 场景下**从根上走不通**。

**不可行的替代思路（已论证）**

- 快捷指令 + 双击 HOME 解锁：iOS 个人自动化**没有"设备重启"触发器**；快捷指令/任何 App **无法解锁锁屏或模拟物理按键**；且锁屏状态下个人自动化不能启动 App。三者叠加不可行。

### 越狱版（deb）

- 通过 `layout/Library/LaunchDaemons/com.82flex.trollvnc.plist`（rootless 为 `/var/jb/Library/LaunchDaemons/...`）由 `launchd` 在开机时直接拉起 `trollvncserver`。
- **不依赖 WiFi 或网络**，是可靠的重启自启方案。
- `before-package.sh` 在 rootless scheme 下会把 LaunchDaemon 的 `ProgramArguments` / 日志路径改写为 `/var/jb/...`。

### 部署建议对照

| 场景 | 巨魔版重启自启 | 越狱版重启自启 |
|------|--------------|---------------|
| 现场有真实 WiFi（含仅接内网 LAN、无外网） | ✅ 自动加入即自启 | ✅ |
| 纯以太网、无 WiFi | ❌ 无系统级方案 | ✅ |
| 无 WiFi 且需无人值守 | 需放一个纯 LAN AP 当唤醒源，或改用越狱 | ✅ |

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

### TVNCServiceCoordinator

服务协调器，负责启动/保活 VNC 服务进程，并持有正确的偏好域（见 [偏好域约定](#偏好域约定重要)）。

- `registerServiceMonitor`：在 `didFinishLaunching` 注册服务监控。
- `ensureServiceRunning`：确保 `trollvncserver` 进程在运行（被 NEHotspotHelper / 网络可达 / 后台任务等多处调用）。
- `commonInit` 中以 `initWithSuiteName:@"com.82flex.trollvnc"` 初始化偏好读取，并 `registerDefaults:` 合并 `Managed.plist` 的托管配置。

### TVNCHotspotManager（巨魔版唤醒）

见 [重启自启机制](#重启自启机制)。核心职责：
- `registerWithName:` → 注册 `NEHotspotHelper` + 启动 `SCNetworkReachability` 监控。
- `handleCommand:` → 收到 WiFi 关联命令即 `executeAutoStartupTaskIfNecessary`。
- `executeAutoStartupTaskIfNecessary` → 用 `beginBackgroundTask` 延长后台时间，调用 `ensureServiceRunning` 启动服务。

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
- theos（CI 用 `roothide/theos` 子模块，含 iPhoneOS16.5 / 14.5 SDK）
- iOS SDK 17.0+（本地）/ 16.5（CI）
- macOS 13+

### 本地构建（单 scheme）

使用 `devkit/*.sh` 设置环境变量后 `make package`：

```bash
# 越狱版 default
source devkit/default.sh && FINALPACKAGE=1 gmake clean package

# 越狱版 rootless
source devkit/rootless.sh && FINALPACKAGE=1 gmake clean package

# 越狱版 roothide
source devkit/roothide.sh && FINALPACKAGE=1 gmake clean package

# 巨魔版 bootstrap（产出 .tipa）
source devkit/bootstrap.sh && FINALPACKAGE=1 gmake clean package
```

`devkit/build-all.sh` 可一次性构建全部 4 个 scheme。

### GitHub Actions 构建（CI）

触发方式：
1. **推送到 `release` 分支** → 自动跑完整 4-scheme 矩阵构建，并在成功后创建 GitHub Release（tag `v<版本号>`，附带 4 个产物）。
2. **`workflow_dispatch`** → 手动填表构建（见 README "Build with GitHub Actions"）。
3. push 到 `main` / `master` 也会触发构建，但**不会**自动创建 Release（仅上传 artifact）。

> ⚠️ **提交/推送习惯**：修改逻辑后先本地 `git commit`，**推送前需用户确认**再 `git push origin release` 触发 CI。

**CI 关键细节：**
- `bootstrap` scheme 构建时，CI 会卸载 `xcbeautify`/`xcpretty`，避免它们吞掉编译错误（bootstrap 用 Xcode 构建，错误容易被美化工具隐藏）。
- `release` job 依赖 `build` job（`needs: build`），下载全部 `packages-*` artifact 后合并上传到 Release。

### 构建产物（本地 `packages/`）

| 产物 | 说明 |
|------|------|
| `packages/*.deb`（default/rootless/roothide） | 越狱版安装包 |
| `packages/TrollVNC_<ver>.tipa` | 巨魔版（bootstrap） |

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
    void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (handle) {
        CFStringRef (*SBSCopyFrontmostApplicationDisplayIdentifier)(void) = dlsym(handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
        if (SBSCopyFrontmostApplicationDisplayIdentifier) {
            CFStringRef result = SBSCopyFrontmostApplicationDisplayIdentifier();
            CFRelease(result);
        }
        dlclose(handle);
    }
}
```

### bootstrap 中调用私有 API 的注意事项

巨魔版走 Xcode 构建，部分私有 API 在新 SDK 缺头文件，需用 `NSClassFromString` + `objc_msgSend` 绕过（例如 `NEHotspotConfiguration`）。**凡是通过 `objc_msgSend` 传递的 block，必须赋给 `__strong` 局部变量（自动堆拷贝），不要写成 `[^(...){...}]`**（方括号会被当作消息发送导致编译失败，这是 v3.52 曾犯过的 CI 错误）。

### noVNC 扩展

noVNC 文件位于 `layout/usr/share/trollvnc/webclients/novnc/`

主要文件：
- `vnc.html` - 主页面
- `core/rfb.js` - RFB 协议实现
- `core/ui.js` - UI 逻辑

---

## 常见问题与经验教训

### 巨魔版重启后 VNC 不自启

- 见 [重启自启机制](#重启自启机制)。本质：纯 TrollStore 只能靠真实 WiFi 关联唤醒，纯以太网无方案。
- 排查：确认设备 WiFi 开关开启、且保存了一个**真实可连**的 AP（有网没网都行）。

### 巨魔版点击即闪退（v3.50 教训）

- 根因：在 `didFinishLaunching` **同步**调用 `NEHotspotConfiguration` 且无异常保护，一旦抛异常或访问已释放栈 block 直接崩溃。
- 教训：启动期任何网络/私有 API 调用都必须 **异步 + `@try/@catch` 包裹（fail-soft）**，且默认不触发。

### 开关读取永远为 NO（偏好域陷阱）

- 必须用 `initWithSuiteName:@"com.82flex.trollvnc"` 读取；用 `standardUserDefaults` 读取的是 App 自身域（`com.matisu.xcs`），永远读不到设置值。

### 虚拟 WiFi 方案无效（v3.50–v3.52 教训，v3.53 已移除）

- 保存不存在的 SSID 不会触发 NEHotspotHelper（没有 AP 广播它，永远关联不上）。不要重新引入此方案。

### 编译错误：CMItemCount

如果遇到 `CMItemCount` 相关错误，在头文件中添加：
```objc
#ifndef CMItemCount
#define CMItemCount int32_t
#endif
```

### bootstrap 构建在 CI 失败但本地能过

- CI 的 bootstrap 构建会卸载 `xcbeautify`/`xcpretty` 暴露真实错误；本地若装了这些工具可能隐藏错误。编译失败优先看 CI 原始日志。

### HTTP API 无法访问

1. 确认 TrollVNC 服务已启动
2. 检查防火墙设置
3. 确认端口 8182 未被占用

### 截图失败

1. 确认 TrollVNC 有屏幕录制权限
2. 检查设备是否处于锁定状态

---

## 相关链接

- [GitHub 仓库](https://github.com/sky5566jf/DUDUDU)（项目已设为 Public，获取免费 Actions 额度）
- [原 TrollVNC 上游](https://github.com/sky5566jf/TrollVNC)
- [LibVNCServer](https://github.com/LibVNC/libvncserver)
- [noVNC](https://github.com/novnc/noVNC)
- [BuildVNCServer](https://github.com/Lessica/BuildVNCServer)
- [NEHotspotHelper 参考](https://developer.apple.com/documentation/networkextension/nehotspothelper)
