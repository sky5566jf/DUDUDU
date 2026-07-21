# 24h 稳定性优化 — 实施完成报告

## 概述

基于 `docs/24h稳定性优化报告.md` 识别的 3 个 P0 + 3 个 P1 隐患，全部 6 项改进已完成代码实施。

## 改动文件清单

| 文件 | 改动项 |
|------|--------|
| `src/TVNCHttpServer+Handlers.h` | 新增 4 个 @property + 3 个方法声明 |
| `src/TVNCHttpServer.mm` | P0-1 自动重连 + P0-3 内存监听 + P1-2 日志轮转 + MJPEG 循环改造 |
| `src/TVNCApiManager.h` | 新增 `quickFrameHash` 方法声明 |
| `src/TVNCApiManager.mm` | P0-2 静态帧缓存池 + P1-1 帧哈希采样 |

## 6 项改进详情

### P0-1: WS 客户端心跳 + 指数退避自动重连
- `wsReadFrame` 已自动处理 ping(0x9)→pong(0xA) 响应（含 mask）
- 新增 `scheduleRelayReconnect`：指数退避 2/4/8/16/30s
- `receiveRelayEvents` 退出循环后自动触发重连（仅当 `_relayModeEnabled && _relayIP`）
- `disconnectFromRelay` 重置重连计数器

### P0-2: 截图帧缓存池静态复用（消除 malloc 抖动）
- 静态 `sSrcFrameBuffer`/`sDstFrameBuffer` + `@synchronized(sFrameBufferLock)` 保护并发
- `tvncDataProviderNoOpCallback` 阻止 CGDataProvider 释放缓冲区
- 非缩放路径：复用 `sSrcFrameBuffer`，仅在尺寸增长时 realloc
- 缩放路径：复用 `sSrcFrameBuffer` + `sDstFrameBuffer`，vImage tempBuf 仍 malloc

### P0-3: 内存压力检测 + 截图自动降级
- `dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE)` 监听系统内存压力
- `_memoryPressureLevel`：0=normal, 1=warn, 2=critical
- MJPEG 循环动态调整：
  - CRITICAL: quality≤0.2, scale≤0.25, fps≤3
  - WARN: quality≤0.4, scale≤0.4, fps≤6
- `startServer` 时启动监听

### P1-1: MJPEG 帧哈希去重（静止画面跳过编码）
- `quickFrameHash`：采样 framebuffer 64 个点，djb2 哈希
- MJPEG 循环比对当前帧与上一帧哈希
- 连续 2 帧以上相同 → 发空 `--frameboundary\r\n\r\n` 保活标记，跳过 JPEG 编码

### P1-2: 崩溃日志自动轮转清理
- `cleanupOldCrashLogs`：扫描 `/var/mobile/Library/Logs/CrashReporter/*.ips`
- 删除 7 天前的文件，或总量超 50MB 时按时间排序删除最旧文件
- `startServer` 时执行一次

### P1-3: MJPEG 自适应帧率（按客户端数降负载）
- `_server.activeMjpegStreams` 在 MJPEG 流开始/结束时递增/递减
- 多客户端并发时：`effectiveFps = MAX(2, effectiveFps / activeStreams)`
- 配合 P0-3 内存降级叠加生效

## MJPEG 循环改动要点

```
每帧执行顺序：
1. 读取 _server.memoryPressureLevel → 计算 effectiveQuality/Scale/Fps
2. 读取 _server.activeMjpegStreams → 多客户端降帧
3. 计算 quickFrameHash → 与 lastFrameHash 比对
   - 相同且连续≥2帧 → 发保活 boundary，sleep，continue
   - 不同 → 更新 lastFrameHash，继续编码
4. 截图（用 effective 参数）
5. 编码发送 JPEG 帧
6. sleep(effectiveInterval)
7. recv peek 检测客户端断连
```

## 预期效果

| 指标 | 优化前 | 预期优化后 |
|------|--------|-----------|
| 截图内存分配 | 每帧 malloc+free ~8MB | 静态复用，0 分配（尺寸不变时） |
| WS 断线恢复 | 永不重连，需重启 daemon | 2-30s 自动重连 |
| 内存压力 | 无感知，直到 Jetsam 杀进程 | 分级降级，critical 时大幅减负 |
| 静止画面 CPU | 持续 10fps JPEG 编码 | 跳过编码，仅发保活标记 |
| 崩溃日志 | 无限堆积（实测 85MB/386文件） | 启动时自动清理 |
| 多客户端 | 各自 10fps 独立编码 | 按数量降帧，共享负载 |

## 下一步

代码改动已完成，等待用户指令执行编译发版流程（版本号+1 → commit → push → CI → 下载产物）。
