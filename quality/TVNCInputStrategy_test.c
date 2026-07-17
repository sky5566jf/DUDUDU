/*
 * 纯 C 单元测试：覆盖 MatisuXCS 文本输入的历史不变式。
 * 不依赖任何测试框架（仅 <stdio.h>/<stdbool.h>），用简单断言计数。
 * 运行：bash quality/run_tests.sh
 */
#include <stdio.h>
#include <stdbool.h>
#include "TVNCInputStrategy.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (cond) { g_pass++; }                                               \
        else { g_fail++; printf("  FAIL: %s  [%s:%d]\n", msg, __FILE__, __LINE__); } \
    } while (0)

static TVNCInputContext ctx_default(void) {
    TVNCInputContext c;
    c.hasFirstResponder = false;
    c.isAllASCII = true;
    c.appProcessAvailable = false;
    c.hasAXEntitlement = false;
    c.isDaemon = false;
    return c;
}

int main(void) {
    printf("=== TVNCInputStrategy unit tests ===\n");

    // ---- 不变式 1：daemon 下绝不选 AX（防 v4.07 崩溃回归）----
    {
        TVNCInputContext c = ctx_default();
        c.isDaemon = true;
        c.hasAXEntitlement = true;           // 即便“有授权”也禁用
        c.appProcessAvailable = true;
        c.hasFirstResponder = true;
        CHECK(TVNCSelectPrimaryInput(&c) != kTVNCInputAX,
              "daemon 下不得选择 AX（v4.07 崩溃根因）");
        CHECK(TVNCCanUseAXInCurrentContext(&c) == false,
              "daemon 上下文 TVNCCanUseAX 必须为 false");
    }

    // ---- 不变式 2：输入转发端口 8183 不安全（防 v4.08 冲突回归）----
    CHECK(TVNCIsPortSafeForInputForwarding(8183) == false,
          "8183 被 daemon Group WS 占用，不可用于输入转发");
    CHECK(TVNCIsPortSafeForInputForwarding(8184) == true,
          "8184 为 App 输入转发端口，安全");

    // ---- 不变式 3：v4.10 终态——有 App 服务 + 第一响应者走第一响应者 ----
    {
        TVNCInputContext c = ctx_default();
        c.appProcessAvailable = true;
        c.hasFirstResponder = true;
        CHECK(TVNCSelectPrimaryInput(&c) == kTVNCInputFirstResponder,
              "有 App 服务且有焦点时应选第一响应者");
    }

    // ---- 不变式 4：无焦点 / 无 App 服务时统一剪贴板兜底（v4.10 终态）----
    {
        TVNCInputContext c = ctx_default();
        c.isDaemon = true;
        c.appProcessAvailable = false;
        c.hasFirstResponder = false;
        CHECK(TVNCSelectPrimaryInput(&c) == kTVNCInputClipboard,
              "daemon 无 App 服务时应剪贴板兜底");
    }

    // ---- 不变式 5：App 进程 + 有 AX 授权时优先 AX（零弹窗通道）----
    {
        TVNCInputContext c = ctx_default();
        c.appProcessAvailable = true;
        c.hasAXEntitlement = true;
        c.hasFirstResponder = false;
        CHECK(TVNCSelectPrimaryInput(&c) == kTVNCInputAX,
              "App 进程有 AX 授权时应选 AX（零弹窗）");
    }

    // ---- 不变式 6：NULL 上下文安全 ----
    CHECK(TVNCSelectPrimaryInput(NULL) == kTVNCInputNone, "NULL 上下文返回 None");
    CHECK(TVNCCanUseAXInCurrentContext(NULL) == false, "NULL 上下文 AX 为 false");

    printf("=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
