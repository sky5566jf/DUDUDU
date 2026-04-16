# TrollVNC 项目记忆

## 项目概述
iOS 设备远程控制工具，通过 HTTP API 提供设备操作功能。

## API 接口列表

### 基础控制
- `POST /api/touch` - 触摸操作
- `POST /api/swipe` - 滑动手势
- `POST /api/presshome` - 按 Home 键
- `POST /api/presslock` - 按锁屏键
- `POST /api/pressboth` - 同时按 Home + 锁屏
- `POST /api/doubleclick` - 双击 Home
- `POST /api/tripleclick` - 三击 Home

### 系统信息
- `GET /api/info` - 设备信息
- `GET /api/screenshot` - 截图
- `GET /api/battery` - 电池状态
- `GET /api/memory` - 内存状态
- `GET /api/storage` - 存储状态
- `GET /api/trollstore` - TrollStore 诊断

### 应用管理
- `POST /api/launchapp` - 启动应用
- `POST /api/clearapps` - 清理后台应用
- `POST /api/clearapps/smart` - 智能清理（桌面则跳过）

### 系统控制
- `POST /api/reboot` - 重启设备
- `POST /api/respring` - 注销设备（Respring）

### 触发器
- `GET /api/trigger?port=3333&delay=5` - 触发懒人精灵（自动使用调用者IP）

## GitHub 信息
- 账号：sky5566jf
- 仓库：sky5566jf/TrollVNC（fork 自原版）
- GitHub CLI 已安装（gh v2.45.0）并已用 PAT 授权
- Actions 工作流已存在（.github/workflows/build.yml），支持 4 种编译方案

## 技术要点
- 使用 STHIDEventGenerator 模拟 HID 事件
- 截图支持旋转参数
- 重启/注销使用 notify_post 和 system 命令
- 智能清理通过检测前台应用实现

## 配置文件
- 主界面定义: `prefs/TrollVNCPrefs/Resources/ManagedRoot.plist`（标题 "Matisu" 可自定义）
- API 管理器: `src/TVNCApiManager.h/mm`
- HTTP 服务器: `src/TVNCHttpServer.mm`
- 测试页面: `test_api.html`

## Artifact 下载方法
由于 Azure Blob（`*.blob.core.windows.net`）网络不通，使用 Python 脚本绕过：
```
python devkit/download_artifact.py <artifact_id> <output_path>
```
脚本路径：`devkit/download_artifact.py`
原理：先用 gh token 获取 GitHub API 的重定向 URL，再直接请求 Azure Blob URL（不带 token）。

## 文件管理 API
- `GET /api/filelist?path=xxx` - 列出目录（默认懒人精灵目录）
- `GET /api/readfile?path=xxx` - 读取文件
- `POST /api/deletefile?path=xxx` - 删除文件/目录（使用 spawnRoot）
- `POST /api/createfolder?path=xxx` - 创建目录（使用 spawnRoot）
- 默认操作目录：`/var/mobile/Media/com.matisu.one.nxs.rootcore`

## 仓库状态
- 仓库已改为**公开（Public）**，GitHub Actions 完全免费
- spawnRoot 使用 system()/popen() 实现（iOS 不支持 NSTask、posix_spawnattr_set_persona_np）
- theos-roothide SDK 版本为 iPhoneOS16.5，不含 persona_np API

## 修改历史
- 2025-03-29: 添加重启、注销、智能清理后台应用功能
- 2025-03-29: 修改 `/api/trigger` 自动使用调用者 IP
- 2025-03-29: 代码优化
  - 修复旋转截图内存泄漏（使用 CGDataProvider 释放回调）
  - 添加 notify.h 头文件
  - 改进 `isOnSpringBoard` 检测逻辑，使用 `SBSCopyFrontmostApplicationDisplayIdentifier`
  - 改进 `getFrontmostAppBundleID` 使用 SpringBoardServices 私有 API
  - 修复 TVNCHttpServer 线程安全问题
- 2025-03-30: GitHub Actions 配置修复
  - 修复 SDK 下载 URL（改为 `master-146e41f`）
  - 修复 `sys/reboot.h` 编译错误（iOS SDK 不支持）
  - 编译成功（run 23724901481）
- 2026-04-16: 实现真正的 root 权限（spawnRoot）
  - 创建 shared/TSUtil.m，手动声明 persona API
  - posix_spawnattr_set_persona_np 设置 root persona (99)
  - posix_spawnattr_set_persona_uid_np 设置 UID 0
  - posix_spawnattr_set_persona_gid_np 设置 GID 0
  - 添加 extern "C" 解决 C++ 链接问题
  - 使用条件编译，只在 roothide/bootstrap 方案启用 root 权限
  - rootless/default 方案降级为 mobile 权限
  - 编译成功（run 24492597572）
  - bootstrap tipa 已复制到 C:\lmp\release\public\TrollVNC_3.1.tipa
