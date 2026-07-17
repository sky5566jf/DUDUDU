/*
 * 纯 C 单元测试：覆盖 8182 REST API 路由安全分类的不变式。
 * 运行：bash quality/run_tests.sh
 */
#include <stdio.h>
#include <stdbool.h>
#include "TVNCRouteSafety.h"

static int g_pass = 0;
static int g_fail = 0;

#define CHECK(cond, msg)                                                      \
    do {                                                                      \
        if (cond) { g_pass++; }                                               \
        else { g_fail++; printf("  FAIL: %s  [%s:%d]\n", msg, __FILE__, __LINE__); } \
    } while (0)

int main(void) {
    printf("=== TVNCRouteSafety unit tests ===\n");

    TVNCRouteInfo info;

    // ---- 只读路由 ----
    CHECK(TVNCRouteLookup("GET", "/api/status", &info) && TVNCRouteIsReadOnly(&info),
          "GET /api/status 是只读");
    CHECK(!TVNCRouteIsWrite(&info) && !TVNCRouteIsSensitive(&info),
          "status 既非写也非敏感");
    CHECK(TVNCRouteLookup("GET", "/api/device", &info) && TVNCRouteIsReadOnly(&info),
          "GET /api/device 是只读");

    // ---- 写 + 敏感路由 ----
    CHECK(TVNCRouteLookup("POST", "/api/input", &info) && TVNCRouteIsWrite(&info),
          "POST /api/input 是写");
    CHECK(TVNCRouteIsSensitive(&info), "input 是敏感操作");
    CHECK(TVNCRouteLookup("POST", "/api/reboot", &info) && TVNCRouteIsSensitive(&info),
          "reboot 是敏感写");
    CHECK(TVNCRouteLookup("POST", "/api/install", &info) && TVNCRouteIsSensitive(&info),
          "install 是敏感写");

    // ---- clipboard 按 method 分流：GET 只读 / POST 写 ----
    CHECK(TVNCRouteLookup("GET", "/api/clipboard", &info) && TVNCRouteIsReadOnly(&info),
          "GET /api/clipboard 是只读");
    CHECK(TVNCRouteLookup("POST", "/api/clipboard", &info) && TVNCRouteIsWrite(&info),
          "POST /api/clipboard 是写");

    // ---- method 不匹配：只注册 GET 的路由用 POST/DELETE 查不到 ----
    CHECK(!TVNCRouteLookup("POST", "/api/status", NULL),
          "POST /api/status 未注册 -> 不匹配");
    CHECK(!TVNCRouteLookup("DELETE", "/api/status", NULL),
          "DELETE /api/status 未注册 -> 不匹配");

    // ---- 未知路由 ----
    CHECK(!TVNCRouteLookup("GET", "/api/nonexistent", NULL), "未知只读路由未找到");
    CHECK(!TVNCRouteLookup("POST", "/api/rebootzzz", NULL), "未知写路由未找到");

    // ---- NULL 参数防护 ----
    CHECK(!TVNCRouteLookup(NULL, "/api/status", &info), "NULL method 不匹配");
    CHECK(!TVNCRouteLookup("GET", NULL, &info), "NULL path 不匹配");
    CHECK(TVNCRouteLookup("GET", "/api/status", NULL) == true,
          "NULL out 时不崩溃且仍返回找到");

    printf("=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
