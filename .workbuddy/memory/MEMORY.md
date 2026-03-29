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

## 技术要点
- 使用 STHIDEventGenerator 模拟 HID 事件
- 截图支持旋转参数
- 重启/注销使用 notify_post 和 system 命令
- 智能清理通过检测前台应用实现

## 文件位置
- API 管理器: `src/TVNCApiManager.h/mm`
- HTTP 服务器: `src/TVNCHttpServer.mm`
- 测试页面: `test_api.html`

## 修改历史
- 2025-03-29: 添加重启、注销、智能清理后台应用功能
- 2025-03-29: 修改 `/api/trigger` 自动使用调用者 IP
