#include "TVNCInputStrategy.h"

TVNCInputMethod TVNCSelectPrimaryInput(const TVNCInputContext *ctx) {
    if (ctx == NULL) return kTVNCInputNone;

    // 约束 1：daemon 下绝不使用 AX（v4.07 崩溃根因），哪怕有授权也禁用。
    // daemon 无界面、无 App 输入服务（原 8184 App 通道已移除），统一剪贴板兜底。
    if (ctx->isDaemon) {
        return kTVNCInputClipboard; // v4.10 统一终态
    }

    // App 进程上下文：有焦点优先第一响应者，有 AX 授权走 AX，否则剪贴板兜底。
    if (ctx->hasFirstResponder) {
        return kTVNCInputFirstResponder;
    }
    if (ctx->hasAXEntitlement) {
        return kTVNCInputAX;
    }
    return kTVNCInputClipboard;
}

bool TVNCIsPortSafeForInputForwarding(int port) {
    // 8183 为 daemon 自有 Group WebSocket 端口，严禁复用做输入转发。
    return port != 8183;
}

bool TVNCCanUseAXInCurrentContext(const TVNCInputContext *ctx) {
    if (ctx == NULL) return false;
    if (ctx->isDaemon) return false;          // daemon 内 AX 必崩
    return ctx->hasAXEntitlement;             // 仅 App 且有授权
}
