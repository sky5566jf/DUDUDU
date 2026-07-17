/*
 * TVNCRouteSafety — 纯 C 的 8182 REST API 路由安全分类（可单测，零依赖）
 *
 * 设计目的：把散落在 src/TVNCHttpServer.mm handleRequest: 大 if/else 链里的
 * 「这个路由只读 / 写 / 敏感」隐式规则，提炼成可机器验证的**单一真源**。
 *
 * 重要说明：当前 TVNCHttpServer 在分发时未按 method 严格校验（多数 handler
 * 不分 method），故本表的 method 字段标的是「语义预期方法」(GET=只读 / POST=写)；
 * clipboard 系列按运行时实际分流精确标注 GET/POST。未来可让运行时在分发前
 * 调用 TVNCRouteLookup 做 method + 权限校验（加固项，见 docs/QUALITY_GATE.md）。
 *
 * 此文件不参与 daemon 编译（Makefile 未登记），仅由 quality/run_tests.sh 编译运行。
 */
#pragma once
#include <stdbool.h>
#include <stddef.h>   // NULL / size_t

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    TVNC_ROUTE_READONLY   = 1 << 0,  // 不修改设备状态（只读查询）
    TVNC_ROUTE_WRITE      = 1 << 1,  // 修改设备状态
    TVNC_ROUTE_SENSITIVE  = 1 << 2,  // 敏感操作（重启/安装/锁屏/群控），应要求鉴权
} TVNCRouteFlag;

typedef struct {
    const char *method;   // "GET" / "POST" 精确；"*" 表示不区分方法
    const char *path;
    unsigned int flags;
} TVNCRouteEntry;

typedef struct {
    bool found;
    unsigned int flags;
} TVNCRouteInfo;

// 查表 (method,path) -> 是否存在该路由定义。
// method 匹配：entry.method=="*" 匹配任意；否则要求字符串相等（方法均为大写）。
// path 精确匹配。找不到时 out->found=false。method/path 为 NULL 视为不匹配。
bool TVNCRouteLookup(const char *method, const char *path, TVNCRouteInfo *out);

bool TVNCRouteIsReadOnly(const TVNCRouteInfo *info);
bool TVNCRouteIsWrite(const TVNCRouteInfo *info);
bool TVNCRouteIsSensitive(const TVNCRouteInfo *info);

// 启动自检：校验路由表内部一致性（无 NULL 字段、标志非 0、无重复 (method,path)）。
// 返回 0 表示通过；非 0 表示发现不一致（首失败索引）。由 daemon 启动时调用，不阻塞分发。
int TVNCRouteSafetySelfTest(void);

#ifdef __cplusplus
}
#endif
