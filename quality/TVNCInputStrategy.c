#include "TVNCInputStrategy.h"

TVNCInputMethod TVNCSelectPrimaryInput(const TVNCInputContext *ctx) {
    if (ctx == NULL) return kTVNCInputNone;

    // 约束 1：daemon 下绝不使用 AX（v4.07 崩溃根因），哪怕有授权也禁用。
    if (ctx->isDaemon) {
        // daemon 无界面、无辅助功能授权、无键盘会话：
        // 有 App 输入服务时走第一响应者 / 剪贴板；都没有时统一剪贴板兜底。
        if (ctx->appProcessAvailable && ctx->hasFirstResponder) {
            return kTVNCInputFirstResponder;
        }
        return kTVNCInputClipboard; // v4.10 统一终态
    }

    // App 进程上下文（TrollVNC.app）：可按能力选择更优方式。
    if (ctx->appProcessAvailable && ctx->hasFirstResponder) {
        return kTVNCInputFirstResponder;
    }
    if (ctx->hasAXEntitlement && ctx->appProcessAvailable) {
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
