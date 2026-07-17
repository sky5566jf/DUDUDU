/*
 * TVNCInputStrategy — 纯 C 输入级联策略与约束（可单测，零 UIKit/theos 依赖）
 *
 * 设计目的：把 MatisuXCS/TrollVNC 文本输入「反复横跳」的历史坑固化成
 * 可机器验证的不变式（见 TVNCInputStrategy_test.c）。主流程（daemon / App）
 * 在调用具体输入方式前，应先查此策略模块做决策，避免再次踩坑。
 *
 * 此文件不参与 daemon 编译（Makefile 未登记），仅由 quality/run_tests.sh
 * 在 CI 与本地用 clang 直接编译运行。
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>   // NULL（接口契约：函数参数为指针，调用方与实现均可能用 NULL）

// extern "C"：本头同时被 C（TVNCInputStrategy.c）与 C++（src/*.mm 以 ObjC++ 编译）
// 包含。不加此包裹，C++ 会对函数名做 name mangling，链接时与 .c 产出的 C 符号对不上，
// 出现「symbol(s) not found for architecture arm64」。这是 v4.17 之后链入策略模块时
// 踩到的真实链接坑，已通过 CI 暴露。
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    kTVNCInputNone = 0,
    kTVNCInputFirstResponder,   // UIKit 第一响应者 replaceRange:
    kTVNCInputClipboard,        // 剪贴板 + Cmd+V（v4.10 统一终态，任何 App 必到）
    kTVNCInputHID,              // 物理键盘事件 (STHIDEventGenerator)
    kTVNCInputAX,               // 无障碍 AXUIElement（仅 App 进程安全）
    kTVNCInputKeyboard,         // UIKeyboardImpl 私有 API
} TVNCInputMethod;

typedef struct {
    bool hasFirstResponder;     // 当前有 UIKit 文本输入焦点
    bool isAllASCII;            // 待输入文本是否纯 ASCII
    bool appProcessAvailable;   // App 内 8184 输入服务可达（TrollVNC.app 存活）
    bool hasAXEntitlement;      // 当前进程持有辅助功能授权
    bool isDaemon;              // 当前是否无界面守护进程 (trollvncserver)
} TVNCInputContext;

// 仅做「决策」，不执行、不返回「成功」——执行与回退由调用方负责。
// 这从设计上杜绝了 v4.02「UIKeyboardImpl 假成功短路级联」类回归。
TVNCInputMethod TVNCSelectPrimaryInput(const TVNCInputContext *ctx);

// 端口安全约束：该端口能否用作输入转发（8183 被 daemon 自身 Group WS 占用 -> false）。
// 防 v4.08 端口冲突回归。
bool TVNCIsPortSafeForInputForwarding(int port);

// 当前上下文是否允许调用 AX（v4.07 根因：daemon 内调用 AX 必崩 -> 永远 false）。
bool TVNCCanUseAXInCurrentContext(const TVNCInputContext *ctx);

#ifdef __cplusplus
}
#endif
