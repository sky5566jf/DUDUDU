/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 本文件将 MatisuTrollStore（M巨魔助手，8588）的 6 个 API 合入 XCS 8182，
 路径 / 参数 / 方法 / 响应结构 原样照搬（无 /api 前缀），便于现有 8588 脚本改 IP 即可复用。
 适配器差异：
   - 响应模型由裸 socket send() 改为 XCS 统一的 TVNCHttpResponse（statusCode/contentType/body）。
   - spawnAsRootWithOutput 复用 XCS 全局函数（TVNCHttpServer.mm:89，persona_np 提权）。
   - 启动 App 改用 SBSLaunchApplicationWithIdentifier（dlsym，daemon 已链接 SpringBoardServices），
     不再 re-exec 自身二进制（XCS 不支持 --launch 参数）。
   - trollstorehelper 发现逻辑与 MatisuTrollStore 完全一致（带缓存）。
*/

#import "TVNCHttpServer+Handlers.h"
#import <time.h>          // time(NULL) 用于临时文件名
#import <sys/time.h>      // struct timeval（socket 连接超时）
#import <string.h>        // memset
#import <dlfcn.h>         // dlsym（已在 +Handlers.h 引入，重复引入无害）

// 端口 → bundle ID 映射（与 MatisuTrollStore 一致）
static const int kTrollPortWatchInterval   = 60;   // 检测间隔（秒）
static const int kTrollPortCheckRetryDelay = 3;    // 二次确认延迟（秒）
static const int kTrollPortLaunchCooldown  = 300;  // 同一端口拉起冷却（秒）

#pragma mark - 分类声明

@interface TVNCHttpServer (TrollStore)
- (TVNCHttpResponse *)trollJson:(NSString *)jsonBody statusCode:(int)code;
- (NSString *)trollJsonEscape:(NSString *)s;
- (NSString *)trollAppVersion;
- (NSString *)trollFindHelper;
- (NSString *)trollFindHelperUncached;
- (NSString *)trollDownloadToTemp:(NSString *)urlString error:(NSString **)errorOut;
- (NSString *)trollExtractBundleIdFromOutput:(NSString *)output;
- (NSString *)trollLaunchApp:(NSString *)bundleId;
- (NSString *)trollLaunchApp:(NSString *)bundleId maxRetries:(int)maxRetries retryDelay:(int)retryDelay;
- (BOOL)trollIsPortListening:(int)port;
- (NSArray<NSDictionary *> *)trollPortWatchList;
- (void)trollCheckWatchedPorts;
@end

#pragma mark - 实现

@implementation TVNCHttpServer (TrollStore)

// 端口健康监控状态（category 无法加 ivar，用 static 单例即可，TVNCHttpServer 本身是单例）
static dispatch_source_t sTrollPortWatchTimer = nil;
static dispatch_queue_t  sTrollPortWatchQueue = nil;
static NSMutableDictionary<NSNumber *, NSDate *> *sTrollLastLaunchByPort = nil;
static NSString *sTrollCachedHelperPath = nil;

#pragma mark - JSON 响应 / 转义

- (TVNCHttpResponse *)trollJson:(NSString *)jsonBody statusCode:(int)code {
    TVNCHttpResponse *r = [[TVNCHttpResponse alloc] init];
    r.statusCode = code;
    r.contentType = @"application/json";
    r.body = [jsonBody dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}

- (NSString *)trollJsonEscape:(NSString *)s {
    if (!s) return @"";
    NSMutableString *ms = [NSMutableString stringWithString:s];
    [ms replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\r" withString:@"\\r" options:0 range:NSMakeRange(0, ms.length)];
    [ms replaceOccurrencesOfString:@"\t" withString:@"\\t" options:0 range:NSMakeRange(0, ms.length)];
    return ms;
}

// 版本号唯一真源 = Makefile PACKAGE_VERSION（daemon 无 App Bundle，不能读 Info.plist）
- (NSString *)trollAppVersion {
    return @PACKAGE_VERSION;
}

#pragma mark - GET /  （MatisuTrollStore 风格健康检查）

- (TVNCHttpResponse *)handleTrollHealth {
    NSString *v = [self trollAppVersion];
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"MatisuXCS API\",\"version\":\"%@\",\"port\":8182,\"endpoints\":[\"/install\",\"/uninstall\",\"/status\",\"/launch\",\"/ports\"]}",
        [self trollJsonEscape:v]];
    return [self trollJson:body statusCode:200];
}

#pragma mark - GET /status  （supervisor 状态 + trollstorehelper 路径）

- (TVNCHttpResponse *)handleTrollStatus {
    pid_t pid = getpid();
    NSString *helperPath = [self trollFindHelper];
    NSString *v = [self trollAppVersion];

    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"version\":\"%@\",\"port\":8182,\"supervisor\":{\"pid\":%d,\"running\":true},\"trollstorehelper\":\"%@\"}",
        [self trollJsonEscape:v], (int)pid, [self trollJsonEscape:helperPath ?: @"not_found"]];
    return [self trollJson:body statusCode:200];
}

#pragma mark - trollstorehelper 查找（带缓存，与 MatisuTrollStore 一致）

- (NSString *)trollFindHelper {
    @synchronized([TVNCHttpServer class]) {
        if (sTrollCachedHelperPath && access([sTrollCachedHelperPath UTF8String], X_OK) == 0) {
            return sTrollCachedHelperPath;
        }
        sTrollCachedHelperPath = [self trollFindHelperUncached];
        return sTrollCachedHelperPath;
    }
}

- (NSString *)trollFindHelperUncached {
    NSArray *fixedPaths = @[
        @"/var/containers/Bundle/Application/com.opa334.TrollStore/trollstorehelper",
        @"/var/mobile/trollstorehelper",
        @"/Applications/TrollStore.app/trollstorehelper",
        @"/usr/bin/trollstorehelper",
        @"/usr/local/bin/trollstorehelper",
        @"/var/jb/usr/bin/trollstorehelper",
        @"/var/jb/bin/trollstorehelper"
    ];
    for (NSString *p in fixedPaths) {
        if (access([p UTF8String], X_OK) == 0) {
            TVLog(@"[TrollStore] found trollstorehelper (fixed): %@", p);
            return p;
        }
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *searchDirs = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application"
    ];
    for (NSString *searchDir in searchDirs) {
        NSError *err = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:searchDir error:&err];
        if (!contents) continue;
        for (NSString *uuidDir in contents) {
            NSString *fullPath = [searchDir stringByAppendingPathComponent:uuidDir];
            BOOL isTS = ([uuidDir rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                         [uuidDir rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound);
            if (isTS) {
                NSString *helper = [fullPath stringByAppendingPathComponent:@"trollstorehelper"];
                if (access([helper UTF8String], X_OK) == 0) {
                    TVLog(@"[TrollStore] found trollstorehelper (UUID dir): %@", helper);
                    return helper;
                }
            }
            NSArray *subContents = [fm contentsOfDirectoryAtPath:fullPath error:nil];
            for (NSString *sub in subContents) {
                if ([sub hasSuffix:@".app"] &&
                    ([sub rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                     [sub rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
                    NSString *helper = [[fullPath stringByAppendingPathComponent:sub]
                                        stringByAppendingPathComponent:@"trollstorehelper"];
                    if (access([helper UTF8String], X_OK) == 0) {
                        TVLog(@"[TrollStore] found trollstorehelper (app bundle): %@", helper);
                        return helper;
                    }
                }
            }
        }
    }
    TVLog(@"[TrollStore] trollstorehelper not found anywhere");
    return nil;
}

#pragma mark - 流式下载 tipa/ipa 到临时文件（照搬 MatisuTrollStore，并增强中文/非ASCII URL 容错）

- (NSString *)trollDownloadToTemp:(NSString *)urlString error:(NSString **)errorOut {
    // HTTP 框架取 query 参数时已完成 URL 解码，若原始链接含中文/空格等非 ASCII 字符，
    // 解码后的串直接交给 NSURL URLWithString: 会返回 nil -> invalid_url。
    // 这里在第一次构造失败时，对原始串做 percent-encode 兜底，确保中文文件名等场景可正常下载。
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSString *encoded = [urlString stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]];
        url = [NSURL URLWithString:encoded];
    }
    if (!url) {
        if (errorOut) *errorOut = @"invalid_url";
        return nil;
    }

    TVLog(@"[TrollStore] downloading from: %@", urlString);

    NSString *urlPath = url.path ?: @"";
    NSString *ext = @"ipa";
    NSRange dotRange = [urlPath rangeOfString:@"." options:NSBackwardsSearch];
    if (dotRange.location != NSNotFound && dotRange.location + 1 < urlPath.length) {
        NSString *rawExt = [urlPath substringFromIndex:dotRange.location + 1];
        NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
        NSString *cleanExt = [[rawExt componentsSeparatedByCharactersInSet:
                               [allowed invertedSet]] componentsJoinedByString:@""];
        if (cleanExt.length > 0 && cleanExt.length <= 10) {
            ext = [cleanExt lowercaseString];
        }
    }

    NSString *tempPath = [NSString stringWithFormat:@"/tmp/matisu_install_%lld.%@",
                          (long long)(time(NULL)), ext];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 120;
    config.timeoutIntervalForResource = 300;

    __block NSError *sessionError = nil;
    __block BOOL downloadComplete = NO;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                sessionError = error;
            } else if (location) {
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtURL:location
                                                         toURL:[NSURL fileURLWithPath:tempPath]
                                                         error:&moveError];
                if (moveError) sessionError = moveError;
            }
            downloadComplete = YES;
        }];

    [task resume];

    while (!downloadComplete) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    [session invalidateAndCancel];

    if (sessionError) {
        NSString *errMsg = sessionError.localizedDescription ?: @"unknown_error";
        TVLog(@"[TrollStore] download failed: %@", errMsg);
        if (errorOut) *errorOut = [NSString stringWithFormat:@"download_failed: %@", errMsg];
        unlink([tempPath UTF8String]);
        return nil;
    }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tempPath error:nil];
    unsigned long long fileSize = [attrs fileSize];
    if (fileSize == 0) {
        if (errorOut) *errorOut = @"download_empty";
        unlink([tempPath UTF8String]);
        return nil;
    }

    TVLog(@"[TrollStore] downloaded %llu bytes to: %@", fileSize, tempPath);
    return tempPath;
}

#pragma mark - 从 trollstorehelper 输出解析 bundle ID（照搬）

- (NSString *)trollExtractBundleIdFromOutput:(NSString *)output {
    if (!output || output.length == 0) return nil;

    NSRange idRange = [output rangeOfString:@"ID: "];
    if (idRange.location != NSNotFound) {
        NSString *afterId = [output substringFromIndex:idRange.location + 4];
        NSRange spaceRange = [afterId rangeOfString:@" "];
        if (spaceRange.location != NSNotFound && spaceRange.location > 0) {
            NSString *bundleId = [afterId substringToIndex:spaceRange.location];
            if ([bundleId containsString:@"."]) {
                return bundleId;
            }
        }
    }

    NSRange pathRange = [output rangeOfString:@"[installApp] new app path: "];
    if (pathRange.location != NSNotFound) {
        NSString *afterPath = [output substringFromIndex:pathRange.location + 28];
        NSArray *pathParts = [afterPath componentsSeparatedByString:@"\n"];
        if (pathParts.count > 0) {
            NSString *appPath = [pathParts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *infoPlistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
            if (infoPlist) {
                NSString *bundleId = infoPlist[@"CFBundleIdentifier"];
                if (bundleId && bundleId.length > 0) return bundleId;
            }
        }
    }

    NSRegularExpression *bidRegex = [NSRegularExpression
        regularExpressionWithPattern:@"\\b([a-zA-Z][a-zA-Z0-9]*\\.[a-zA-Z][a-zA-Z0-9]*(?:\\.[a-zA-Z][a-zA-Z0-9]*)+)\\b"
        options:0 error:nil];
    NSArray *matches = [bidRegex matchesInString:output options:0 range:NSMakeRange(0, output.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *candidate = [output substringWithRange:[match rangeAtIndex:1]];
        if ([candidate hasPrefix:@"com."] || [candidate hasPrefix:@"org."] ||
            [candidate hasPrefix:@"net."] || [candidate hasPrefix:@"io."] ||
            [candidate hasPrefix:@"live."] || [candidate hasPrefix:@"app."]) {
            return candidate;
        }
    }
    return nil;
}

#pragma mark - 启动已安装 App（SBS，带延迟重试）

// 通过 SpringBoardServices 私有 API 启动 GUI App（daemon 已链接该框架，entitlements 含 launchapplications 授权）
static int tvnc_sbsLaunchApp(CFStringRef bid) {
    static int (*sbs)(CFStringRef, int) = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        sbs = (int (*)(CFStringRef, int))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
        if (!sbs) {
            void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            if (!h) h = dlopen("SpringBoardServices", RTLD_LAZY);
            if (h) sbs = (int (*)(CFStringRef, int))dlsym(h, "SBSLaunchApplicationWithIdentifier");
        }
        TVLog(@"[TrollStore] SBSLaunchApplicationWithIdentifier=%s", sbs ? "resolved" : "-");
    }
    if (!sbs) return -2;
    return sbs(bid, 0);
}

- (NSString *)trollLaunchApp:(NSString *)bundleId {
    return [self trollLaunchApp:bundleId maxRetries:2 retryDelay:3];
}

- (NSString *)trollLaunchApp:(NSString *)bundleId maxRetries:(int)maxRetries retryDelay:(int)retryDelay {
    int totalAttempts = maxRetries + 1;
    for (int attempt = 1; attempt <= totalAttempts; attempt++) {
        if (attempt > 1) {
            TVLog(@"[TrollStore] retry launching %@ (attempt %d/%d) after %ds", bundleId, attempt, totalAttempts, retryDelay);
            sleep(retryDelay);
        }
        TVLog(@"[TrollStore] launching app %@ via SBSLaunchApplicationWithIdentifier attempt %d/%d", bundleId, attempt, totalAttempts);
        int ret = tvnc_sbsLaunchApp((__bridge CFStringRef)bundleId);
        NSString *result = [NSString stringWithFormat:@"exitCode:%d|ret=%d", (ret == 0 ? 0 : 1), ret];
        TVLog(@"[TrollStore] launch result (attempt %d/%d): %@", attempt, totalAttempts, result);
        if (ret == 0) {
            if (attempt > 1) result = [result stringByAppendingFormat:@" [succeeded on attempt %d]", attempt];
            return result;
        }
        if (attempt == totalAttempts) {
            return [result stringByAppendingFormat:@" [failed after %d attempts]", totalAttempts];
        }
    }
    return @"unexpected";
}

#pragma mark - GET /install?url=&launch=

- (TVNCHttpResponse *)handleTrollInstall:(NSDictionary *)query {
    NSString *urlParam = query[@"url"];
    if (urlParam.length == 0) {
        return [self trollJson:@"{\"status\":\"error\",\"msg\":\"url required\"}" statusCode:400];
    }
    NSString *decoded = urlParam;
    NSString *launchParam = query[@"launch"]; // 已 URL 解码

    NSString *dlError = nil;
    NSString *helperPath = [self trollFindHelper];
    if (helperPath) {
        TVLog(@"[TrollStore] trying trollstorehelper direct install");
        NSString *tempPath = [self trollDownloadToTemp:decoded error:&dlError];
        if (tempPath) {
            NSString *output = nil;
            int exitCode = spawnAsRootWithOutput(helperPath, @[@"install", tempPath], &output);
            unlink([tempPath UTF8String]);

            NSString *statusStr = (exitCode == 0) ? @"ok" : @"error";
            NSString *escOutput = [self trollJsonEscape:output];
            NSString *escUrl = [self trollJsonEscape:decoded];

            NSMutableArray *launchResultArray = [NSMutableArray array];
            if (exitCode == 0 && launchParam) {
                TVLog(@"[TrollStore] install ok, waiting 2s for Installd registration before launch");
                sleep(2);

                NSArray *bundleIds = nil;
                if ([launchParam isEqualToString:@"true"]) {
                    NSString *autoBid = [self trollExtractBundleIdFromOutput:output];
                    TVLog(@"[TrollStore] auto-detected bundleId: %@", autoBid);
                    if (autoBid) bundleIds = @[autoBid];
                } else {
                    bundleIds = [launchParam componentsSeparatedByString:@","];
                }

                NSUInteger launchIndex = 0;
                for (NSString *bid in bundleIds) {
                    NSString *trimmed = [bid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0) continue;
                    if (launchIndex > 0) {
                        TVLog(@"[TrollStore] waiting 10s before launching next app: %@", trimmed);
                        sleep(10);
                    }
                    NSString *result = [self trollLaunchApp:trimmed];
                    [launchResultArray addObject:[NSString stringWithFormat:
                        @"{\"bundleId\":\"%@\",\"result\":\"%@\"}",
                        [self trollJsonEscape:trimmed], [self trollJsonEscape:result]]];
                    launchIndex++;
                }
                if (launchResultArray.count == 0 && bundleIds.count == 0) {
                    [launchResultArray addObject:@"{\"bundleId\":\"\",\"result\":\"no_bundle_id\"}"];
                }
            }

            NSString *launchJson = [launchResultArray componentsJoinedByString:@","];
            NSString *body = [NSString stringWithFormat:
                @"{\"status\":\"%@\",\"url\":\"%@\",\"method\":\"trollstorehelper\",\"exitCode\":%d,\"output\":\"%@\",\"launch\":[%@]}",
                statusStr, escUrl, exitCode, escOutput, launchJson];
            return [self trollJson:body statusCode:(exitCode == 0 ? 200 : 500)];
        }
        TVLog(@"[TrollStore] download failed: %@", dlError);
    }

    // trollstorehelper 不可用 / 下载失败
    NSString *reason = helperPath ? [NSString stringWithFormat:@"download_failed: %@", dlError ?: @"unknown"] : @"trollstorehelper not found";
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"error\",\"url\":\"%@\",\"msg\":\"%@\"}",
        [self trollJsonEscape:decoded], [self trollJsonEscape:reason]];
    return [self trollJson:body statusCode:500];
}

#pragma mark - GET /uninstall?bundle_id=

- (TVNCHttpResponse *)handleTrollUninstall:(NSDictionary *)query {
    NSString *bundleId = query[@"bundle_id"];
    if (bundleId.length == 0) {
        return [self trollJson:@"{\"status\":\"error\",\"msg\":\"bundle_id required\"}" statusCode:400];
    }

    NSString *helperPath = [self trollFindHelper];
    if (!helperPath) {
        TVLog(@"[TrollStore] trollstorehelper not found, cannot uninstall");
        return [self trollJson:@"{\"status\":\"error\",\"msg\":\"trollstorehelper not found\"}" statusCode:500];
    }

    TVLog(@"[TrollStore] uninstalling app: %@ via trollstorehelper", bundleId);
    NSString *output = nil;
    int exitCode = spawnAsRootWithOutput(helperPath, @[@"uninstall", bundleId], &output);

    NSString *statusStr = (exitCode == 0) ? @"ok" : @"error";
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"%@\",\"bundleId\":\"%@\",\"method\":\"trollstorehelper\",\"exitCode\":%d,\"output\":\"%@\"}",
        statusStr, [self trollJsonEscape:bundleId], exitCode, [self trollJsonEscape:output]];
    return [self trollJson:body statusCode:(exitCode == 0 ? 200 : 500)];
}

#pragma mark - GET /launch?apps=&interval=

- (TVNCHttpResponse *)handleTrollLaunch:(NSDictionary *)query {
    NSString *appsParam = query[@"apps"] ?: query[@"bundle_ids"];
    if (appsParam.length == 0) {
        return [self trollJson:@"{\"status\":\"error\",\"msg\":\"apps required (comma-separated bundle ids)\"}" statusCode:400];
    }

    NSArray *bundleIds = [appsParam componentsSeparatedByString:@","];

    int interval = 5;
    NSString *intStr = query[@"interval"];
    if (intStr) {
        int parsed = [intStr intValue];
        if (parsed >= 1 && parsed <= 60) interval = parsed;
    }

    TVLog(@"[TrollStore] /launch apps=%@ interval=%ds", bundleIds, interval);

    NSMutableArray *launchResultArray = [NSMutableArray array];
    NSUInteger idx = 0;
    for (NSString *rawBid in bundleIds) {
        NSString *bid = [rawBid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bid.length == 0) continue;
        if (idx > 0) {
            TVLog(@"[TrollStore] /launch waiting %ds before next app: %@", interval, bid);
            sleep(interval);
        }
        NSString *result = [self trollLaunchApp:bid];
        [launchResultArray addObject:[NSString stringWithFormat:
            @"{\"bundleId\":\"%@\",\"result\":\"%@\"}",
            [self trollJsonEscape:bid], [self trollJsonEscape:result]]];
        idx++;
    }

    if (launchResultArray.count == 0) {
        return [self trollJson:@"{\"status\":\"error\",\"msg\":\"no valid bundle id provided\"}" statusCode:400];
    }

    NSString *launchJson = [launchResultArray componentsJoinedByString:@","];
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"interval\":%d,\"launches\":[%@]}", interval, launchJson];
    return [self trollJson:body statusCode:200];
}

#pragma mark - GET /ports  （端口健康监控状态）

- (BOOL)trollIsPortListening:(int)port {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    struct timeval tv;
    tv.tv_sec = 2; tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int ret = connect(sock, (const struct sockaddr *)&addr, sizeof(addr));
    close(sock);
    return ret == 0;
}

- (NSArray<NSDictionary *> *)trollPortWatchList {
    return @[
        @{@"port": @8588, @"bundle": @"com.matisu.trollassistant"},
        @{@"port": @3333, @"bundle": @"com.matisu.one.nxs"},
        @{@"port": @8182, @"bundle": @"com.matisu.xcs"},
    ];
}

- (void)trollCheckWatchedPorts {
    for (NSDictionary *entry in [self trollPortWatchList]) {
        int port = [entry[@"port"] intValue];
        NSString *bundle = entry[@"bundle"];

        if ([self trollIsPortListening:port]) {
            [sTrollLastLaunchByPort removeObjectForKey:@(port)];
            continue;
        }

        TVLog(@"[TrollPortWatch] port %d not listening, re-checking in %ds", port, kTrollPortCheckRetryDelay);
        sleep(kTrollPortCheckRetryDelay);
        if ([self trollIsPortListening:port]) {
            [sTrollLastLaunchByPort removeObjectForKey:@(port)];
            continue;
        }

        NSDate *last = sTrollLastLaunchByPort[@(port)];
        if (last) {
            NSTimeInterval since = -[last timeIntervalSinceNow];
            if (since < kTrollPortLaunchCooldown) {
                TVLog(@"[TrollPortWatch] port %d launch cooldown (%.0fs left), skip", port, kTrollPortLaunchCooldown - since);
                continue;
            }
        }

        TVLog(@"[TrollPortWatch] port %d still down, launching %@", port, bundle);
        [self trollLaunchApp:bundle];
        sTrollLastLaunchByPort[@(port)] = [NSDate date];
    }
}

- (void)startTrollPortWatcher {
    if (sTrollPortWatchTimer) return;  // 防重复启动
    sTrollLastLaunchByPort = [NSMutableDictionary dictionary];
    sTrollPortWatchQueue = dispatch_queue_create("com.matisu.trollportwatch", DISPATCH_QUEUE_SERIAL);
    sTrollPortWatchTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sTrollPortWatchQueue);
    dispatch_source_set_timer(sTrollPortWatchTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)kTrollPortWatchInterval * (int64_t)NSEC_PER_SEC),
                              (uint64_t)kTrollPortWatchInterval * NSEC_PER_SEC,
                              (uint64_t)(kTrollPortWatchInterval / 2) * NSEC_PER_SEC);
    __weak __typeof__(self) weakSelf = self;
    dispatch_source_set_event_handler(sTrollPortWatchTimer, ^{
        [weakSelf trollCheckWatchedPorts];
    });
    dispatch_resume(sTrollPortWatchTimer);
    TVLog(@"[TrollPortWatch] started: 8588->com.matisu.trollassistant, 3333->com.matisu.one.nxs, 8182->com.matisu.xcs, interval=%ds", kTrollPortWatchInterval);
}

- (TVNCHttpResponse *)handleTrollPorts {
    NSMutableArray *ports = [NSMutableArray array];
    for (NSDictionary *entry in [self trollPortWatchList]) {
        int port = [entry[@"port"] intValue];
        NSString *bundle = entry[@"bundle"];
        BOOL listening = [self trollIsPortListening:port];
        NSDate *last = sTrollLastLaunchByPort[@(port)];
        NSString *ago = last ? [NSString stringWithFormat:@"%.0f", -[last timeIntervalSinceNow]] : @"null";
        [ports addObject:[NSString stringWithFormat:
            @"{\"port\":%d,\"bundle\":\"%@\",\"listening\":%@,\"lastLaunchAgoSec\":%@}",
            port, [self trollJsonEscape:bundle], listening ? @"true" : @"false", ago]];
    }
    NSString *body = [NSString stringWithFormat:
        @"{\"status\":\"ok\",\"interval\":%d,\"cooldown\":%d,\"ports\":[%@]}",
        kTrollPortWatchInterval, kTrollPortLaunchCooldown, [ports componentsJoinedByString:@","]];
    return [self trollJson:body statusCode:200];
}

@end
