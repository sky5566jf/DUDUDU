#include "TVNCRouteSafety.h"
#include <string.h>

// 8182 REST API 路由安全分类「规范真源」。
// 路由清单对照 src/TVNCHttpServer.mm handleRequest: 的 if/else 分发。
static const TVNCRouteEntry g_routes[] = {
    // ---- 只读查询（GET）----
    {"GET", "/api/screenshot",             TVNC_ROUTE_READONLY},
    {"GET", "/api/screenshot/fast",        TVNC_ROUTE_READONLY},
    {"GET", "/api/stream.mjpeg",           TVNC_ROUTE_READONLY},
    {"GET", "/api/clipboard",              TVNC_ROUTE_READONLY},
    {"GET", "/api/clipboard_text",         TVNC_ROUTE_READONLY},
    {"GET", "/api/clients",                TVNC_ROUTE_READONLY},
    {"GET", "/api/status",                 TVNC_ROUTE_READONLY},
    {"GET", "/api/device",                 TVNC_ROUTE_READONLY},
    {"GET", "/api/checkfile",              TVNC_ROUTE_READONLY},
    {"GET", "/api/filelist",               TVNC_ROUTE_READONLY},
    {"GET", "/api/readfile",               TVNC_ROUTE_READONLY},
    {"GET", "/api/ping",                   TVNC_ROUTE_READONLY},
    {"GET", "/api/plist",                  TVNC_ROUTE_READONLY},
    {"GET", "/api/trollstore/diagnostics", TVNC_ROUTE_READONLY},
    {"GET", "/api/frontmost",              TVNC_ROUTE_READONLY},
    {"GET", "/api/taskmanager",            TVNC_ROUTE_READONLY},
    {"GET", "/api/webdav/status",          TVNC_ROUTE_READONLY},
    {"GET", "/api/group/status",           TVNC_ROUTE_READONLY},
    {"GET", "/api/group/slaves",           TVNC_ROUTE_READONLY},
    {"GET", "/api/group/proxy-screenshot", TVNC_ROUTE_READONLY},
    {"GET", "/api/endpoints",              TVNC_ROUTE_READONLY},
    {"GET", "/api/network/debug",          TVNC_ROUTE_READONLY},
    {"GET", "/api/network/ip_methods",     TVNC_ROUTE_READONLY},
    {"GET", "/api/network/test_helper",    TVNC_ROUTE_READONLY},

    // ---- 写操作 + 敏感（POST）----
    {"POST", "/api/input",             TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/key",               TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/clipboard",         TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/clipboard_text",    TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/writefile_text",    TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/upload",            TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/volume",            TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/brightness",        TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/reboot",            TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/respring",          TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/screen/lock",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/screen/unlock",     TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/home",              TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/assistivetouch",    TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/install",           TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/install/tipa",      TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/install/url",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/install/deb",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/uninstall",         TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/clearapps/smart",   TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/clearapps/force",   TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/deletefile",        TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/createfolder",      TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/alert",             TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/webdav/start",      TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/webdav/stop",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/start",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/stop",        TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/touch",       TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/connect",     TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/disconnect",  TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/relay/start", TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},
    {"POST", "/api/group/relay/stop",  TVNC_ROUTE_WRITE | TVNC_ROUTE_SENSITIVE},

    {NULL, NULL, 0}  // 哨兵
};

bool TVNCRouteLookup(const char *method, const char *path, TVNCRouteInfo *out) {
    if (out != NULL) { out->found = false; out->flags = 0; }
    if (method == NULL || path == NULL) return false;

    for (size_t i = 0; g_routes[i].path != NULL; i++) {
        const TVNCRouteEntry *e = &g_routes[i];
        bool method_ok = (e->method[0] == '*') || (strcmp(e->method, method) == 0);
        if (method_ok && strcmp(e->path, path) == 0) {
            if (out != NULL) { out->found = true; out->flags = e->flags; }
            return true;
        }
    }
    return false;
}

bool TVNCRouteIsReadOnly(const TVNCRouteInfo *info) {
    return info != NULL && info->found && (info->flags & TVNC_ROUTE_READONLY) != 0;
}
bool TVNCRouteIsWrite(const TVNCRouteInfo *info) {
    return info != NULL && info->found && (info->flags & TVNC_ROUTE_WRITE) != 0;
}
bool TVNCRouteIsSensitive(const TVNCRouteInfo *info) {
    return info != NULL && info->found && (info->flags & TVNC_ROUTE_SENSITIVE) != 0;
}

int TVNCRouteSafetySelfTest(void) {
    for (size_t i = 0; g_routes[i].path != NULL; i++) {
        const TVNCRouteEntry *e = &g_routes[i];
        if (e->method == NULL || e->path == NULL ||
            e->method[0] == '\0' || e->flags == 0) {
            return (int)(i + 1);  // 字段缺失
        }
        for (size_t j = i + 1; g_routes[j].path != NULL; j++) {
            if (strcmp(g_routes[i].method, g_routes[j].method) == 0 &&
                strcmp(g_routes[i].path, g_routes[j].path) == 0) {
                return (int)(i + 1) + 1000;  // 重复条目
            }
        }
    }
    return 0;
}
