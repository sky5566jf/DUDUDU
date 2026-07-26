//
//  TVNCHttpServer+System.mm
//  Auto-split from TVNCHttpServer.mm (P3 maintainability refactor, 2026-07-20)
//
#import "TVNCHttpServer+Handlers.h"

// 硬件信息查询所需的 mach 头
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/processor_info.h>
#include <mach/task_info.h>
#include <mach/vm_statistics.h>
#include <time.h>

// v4.34: extern "C" accessors from trollvncserver.mm
extern "C" int tvncGetMemPressureLevel(void);

// v4.37: IOKit C API 声明（IOKit framework 已链接，但公开头文件不暴露这些函数）
// 用于读取电池温度和 SoC 温度传感器
extern "C" {
typedef mach_port_t       io_object_t;
typedef io_object_t       io_service_t;
typedef io_object_t       io_registry_entry_t;
typedef UInt32            IOOptionBits;

io_service_t          IOServiceGetMatchingService(mach_port_t masterPort, CFDictionaryRef matching);
CFMutableDictionaryRef IOServiceNameMatching(const char *name);
kern_return_t         IORegistryEntryCreateCFProperties(io_registry_entry_t entry,
                                                         CFMutableDictionaryRef *properties,
                                                         CFAllocatorRef allocator,
                                                         IOOptionBits options);
kern_return_t         IOObjectRelease(io_object_t object);
}

@interface TVNCHttpServer (System)
@end

@implementation TVNCHttpServer (System)

- (TVNCHttpResponse *)handleReboot {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
#ifndef THEBOOTSTRAP
    // 越狱版：禁用重启 API（App 内重启按钮走直接系统调用，不暴露远程接口）
    TVLog(@"HTTP Server: Reboot API disabled in jailbreak build");
    response.statusCode = 403;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:@{
        @"success": @NO,
        @"error": @"Reboot API is disabled in jailbreak build"
    } options:0 error:nil];
    return response;
#endif
    
    TVLog(@"HTTP Server: Reboot request received");
    
    BOOL success = [[TVNCApiManager sharedManager] rebootDevice];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    
    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Reboot initiated",
            @"warning": @"Device will restart immediately"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to initiate reboot"
        };
    
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleShutdown {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

#ifndef THEBOOTSTRAP
    // 越狱版：禁用关机 API
    TVLog(@"HTTP Server: Shutdown API disabled in jailbreak build");
    response.statusCode = 403;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:@{
        @"success": @NO,
        @"error": @"Shutdown API is disabled in jailbreak build"
    } options:0 error:nil];
    return response;
#endif

    TVLog(@"HTTP Server: Shutdown request received");

    BOOL success = [[TVNCApiManager sharedManager] shutdownDevice];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Shutdown initiated",
            @"warning": @"Device will power off immediately"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to initiate shutdown"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleRespring {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Respring request received");

    BOOL success = [[TVNCApiManager sharedManager] respringDevice];

    // 注销后等待 15 秒，然后解锁屏幕
    if (success) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            TVLog(@"Respring completed, unlocking screen after 15s delay");
            [[TVNCApiManager sharedManager] unlockDeviceScreen];
        });
    }

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Respring initiated",
            @"warning": @"Screen will unlock after 15 seconds"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to initiate respring"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleScreenLock {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Screen lock request received");

    BOOL success = [[TVNCApiManager sharedManager] lockDeviceScreen];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Screen locked"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to lock screen"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleScreenUnlock {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Screen unlock request received");

    BOOL success = [[TVNCApiManager sharedManager] unlockDeviceScreen];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Screen unlocked"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to unlock screen"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleHome {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Home request received");

    BOOL success = [[TVNCApiManager sharedManager] goToHome];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"action": @"home",
            @"message": @"Returned to home screen"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to go to home"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleTaskManager {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Task manager request received");

    BOOL success = [[TVNCApiManager sharedManager] openTaskManager];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"action": @"taskmanager",
            @"message": @"Task manager opened"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to open task manager"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleSwipeBack {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Swipe back request received");

    BOOL success = [[TVNCApiManager sharedManager] swipeBack];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"action": @"swipeBack",
            @"message": @"Edge swipe back gesture sent"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to perform swipe back"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleClearAppsSmart {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Smart clear apps request received");

    NSDictionary *result = [[TVNCApiManager sharedManager] clearBackgroundAppsSmart];

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];

    return response;
}

- (TVNCHttpResponse *)handleClearAppsForce {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Force clear apps request received");

    NSDictionary *result = [[TVNCApiManager sharedManager] clearBackgroundAppsSmartForce:YES];

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];

    return response;
}

- (TVNCHttpResponse *)handleFrontmost {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSDictionary *info = [[TVNCApiManager sharedManager] frontmostAppInfo];
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithDictionary:info];
    id bid = info[@"bundleID"];
    out[@"bundleID"] = [bid isKindOfClass:[NSString class]] ? bid : [NSNull null];
    out[@"onSpringBoard"] = @(![bid isKindOfClass:[NSString class]] ||
        [bid isEqualToString:@"com.apple.springboard"] || [bid isEqualToString:@"SpringBoard"]);

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];

    return response;
}

- (TVNCHttpResponse *)handleAssistiveTouch:(NSDictionary *)query method:(NSString *)method {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSDictionary *result = nil;
    
    if ([method isEqualToString:@"GET"]) {
        // GET 请求：获取状态
        TVLog(@"HTTP Server: AssistiveTouch status request received");
        
        // 使用 popen 获取当前状态
        NSString *status = [self executeCommand:@"defaults read com.apple.Accessibility AXAssistiveTouchEnabled 2>/dev/null"];
        BOOL enabled = [status containsString:@"1"] || [status containsString:@"true"];
        
        result = @{
            @"success": @YES,
            @"action": @"status",
            @"enabled": @(enabled)
        };
        TVLog(@"HTTP Server: AssistiveTouch status: %@", enabled ? @"enabled" : @"disabled");
        
    } else {
        // POST 请求：启用或禁用
        NSString *action = query[@"action"];
        TVLog(@"HTTP Server: AssistiveTouch action request: %@", action ?: @"status");
        
        if ([action isEqualToString:@"enable"]) {
            // 设置启用
            [self runCommand:@"defaults write com.apple.Accessibility AXAssistiveTouchEnabled -bool true 2>/dev/null"];
            
            // Respring 后等待 15 秒，然后解锁屏幕
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                BOOL success = [[TVNCApiManager sharedManager] respringDevice];
                if (success) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        TVLog(@"AssistiveTouch enable: Respring completed, unlocking screen");
                        [[TVNCApiManager sharedManager] unlockDeviceScreen];
                    });
                }
            });
            
            result = @{
                @"success": @YES,
                @"action": @"enable",
                @"message": @"AssistiveTouch enabled, respringing..."
            };
            TVLog(@"HTTP Server: AssistiveTouch enabled, respringing...");
            
        } else if ([action isEqualToString:@"disable"]) {
            // 设置禁用
            [self runCommand:@"defaults write com.apple.Accessibility AXAssistiveTouchEnabled -bool false 2>/dev/null"];
            
            // Respring 后等待 15 秒，然后解锁屏幕
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                BOOL success = [[TVNCApiManager sharedManager] respringDevice];
                if (success) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        TVLog(@"AssistiveTouch disable: Respring completed, unlocking screen");
                        [[TVNCApiManager sharedManager] unlockDeviceScreen];
                    });
                }
            });
            
            result = @{
                @"success": @YES,
                @"action": @"disable",
                @"message": @"AssistiveTouch disabled, respringing..."
            };
            TVLog(@"HTTP Server: AssistiveTouch disabled, respringing...");
            
        } else {
            result = @{
                @"success": @NO,
                @"message": @"Invalid action. Use 'enable' or 'disable'"
            };
        }
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleUninstallApp:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *bundleId = query[@"bundleId"];
    if (!bundleId || bundleId.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing bundleId parameter. Usage: /api/uninstall?bundleId=com.example.app"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 TrollStore 是否可用
    if (![[TVNCApiManager sharedManager] isTrollStoreAvailable]) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"TrollStore is not available. Please ensure TrollStore is installed."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Uninstall app request - bundleId: %@", bundleId);
    
    // 执行卸载
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] uninstallAppWithBundleId:bundleId error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"App uninstalled successfully", @"bundleId": bundleId};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App uninstalled successfully: %@", bundleId);
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Uninstallation failed";
        NSDictionary *result = @{@"success": @NO, @"error": errMsg, @"bundleId": bundleId};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App uninstallation failed: %@", errMsg);
    }
    
    return response;
}

- (TVNCHttpResponse *)handleInstallApp:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *ipaPath = query[@"path"];
    if (!ipaPath || ipaPath.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing path parameter. Usage: /api/install?path=/path/to/app.ipa"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 TrollStore 是否可用
    if (![[TVNCApiManager sharedManager] isTrollStoreAvailable]) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"TrollStore is not available. Please ensure TrollStore is installed."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 IPA 文件是否存在
    if (access([ipaPath UTF8String], F_OK) != 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"IPA file not found", @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Install app request - path: %@", ipaPath);
    
    // 执行安装
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] installAppWithIPAPath:ipaPath error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"App installed successfully", @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App installed successfully: %@", ipaPath);
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Installation failed";
        NSDictionary *result = @{@"success": @NO, @"error": errMsg, @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App installation failed: %@", errMsg);
    }
    
    return response;
}

- (TVNCHttpResponse *)handleInstallTipa:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSString *tipaPath = query[@"path"];
    if (!tipaPath || tipaPath.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing path parameter. Usage: /api/install/tipa?path=/path/to/app.tipa"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }

    // 检查 .tipa 文件是否存在
    if (access([tipaPath UTF8String], F_OK) != 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @".tipa file not found", @"path": tipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }

    TVLog(@"HTTP Server: Install tipa request - path: %@", tipaPath);

    // 1) 探活 TrollVNC.app（端口 8184）。App 被 iOS 挂起时 8184 会失活。
    BOOL appAlive = NO;
    @try {
        NSURL *healthUrl = [NSURL URLWithString:@"http://127.0.0.1:8184/health"];
        NSMutableURLRequest *healthReq = [NSMutableURLRequest requestWithURL:healthUrl];
        [healthReq setHTTPMethod:@"GET"];
        [healthReq setTimeoutInterval:0.3];
        NSURLResponse *hResp = nil;
        NSError *hErr = nil;
        [NSURLConnection sendSynchronousRequest:healthReq returningResponse:&hResp error:&hErr];
        appAlive = (hErr == nil);
    } @catch (NSException *e) {
        appAlive = NO;
    }

    // 2) App 在线：转发给 App，由 App 用 UIApplication openURL 触发 TrollStore
    if (appAlive) {
        @try {
            NSURL *appUrl = [NSURL URLWithString:@"http://127.0.0.1:8184/install/tipa"];
            NSMutableURLRequest *appReq = [NSMutableURLRequest requestWithURL:appUrl];
            [appReq setHTTPMethod:@"POST"];
            [appReq setHTTPBody:[tipaPath dataUsingEncoding:NSUTF8StringEncoding]];
            [appReq setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
            [appReq setTimeoutInterval:3.0];
            NSURLResponse *appResp = nil;
            NSError *appErr = nil;
            NSData *appData = [NSURLConnection sendSynchronousRequest:appReq returningResponse:&appResp error:&appErr];
            if (appData && appData.length > 0) {
                response.statusCode = 200;
                response.contentType = @"application/json";
                response.body = appData;
                TVLog(@"HTTP Server: Tipta install forwarded to App: %@", [[NSString alloc] initWithData:appData encoding:NSUTF8StringEncoding]);
                return response;
            }
            response.statusCode = 502;
            response.contentType = @"application/json";
            response.body = [NSJSONSerialization dataWithJSONObject:@{@"success": @NO, @"error": @"App install handler returned empty response"} options:0 error:nil];
            return response;
        } @catch (NSException *e) {
            response.statusCode = 502;
            response.contentType = @"application/json";
            response.body = [NSJSONSerialization dataWithJSONObject:@{@"success": @NO, @"error": [NSString stringWithFormat:@"Failed to reach App install handler: %@", e.reason]} options:0 error:nil];
            return response;
        }
    }

    // 3) App 不可用（.deb 无 8184，或 App 被挂起）：daemon 无 UIApplication 无法 openURL，明确提示
    response.statusCode = 503;
    response.contentType = @"application/json";
    NSDictionary *error = @{@"success": @NO, @"error": @"TrollVNC.app is not reachable on port 8184. Keep the app running (foreground) so it can hand off the TrollStore install."};
    response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
    TVLog(@"HTTP Server: Tipta install aborted - App not reachable");
    return response;
}

- (TVNCHttpResponse *)handleInstallUrl:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *urlStr = query[@"url"];
    if (!urlStr || urlStr.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing url parameter."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    if (![[TVNCApiManager sharedManager] isTrollStoreAvailable]) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"TrollStore is not available."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Install URL request - url: %@", urlStr);
    
    NSString *encodedUrl = [urlStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *trollstoreUrlStr = [NSString stringWithFormat:@"trollstore://install?url=%@", encodedUrl];
    NSURL *trollstoreUrl = [NSURL URLWithString:trollstoreUrlStr];
    
    if (!trollstoreUrl) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Invalid URL"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:trollstoreUrl options:@{} completionHandler:^(BOOL success) {
            TVLog(@"HTTP Server: TrollStore install URL opened: %@", success ? @"YES" : @"NO");
        }];
    });
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES, @"message": @"TrollStore install requested", @"url": urlStr};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    TVLog(@"HTTP Server: Install URL triggered: %@", urlStr);
    
    return response;
}

- (TVNCHttpResponse *)handleInstallDeb:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *debPath = query[@"path"];
    BOOL shouldCleanup = NO;
    
    // 如果没有 path 参数，尝试从 body 读取上传的 deb 文件
    if (!debPath || debPath.length == 0) {
        if (body && body.length > 0) {
            // 将 body 写入临时文件
            NSString *tmpPath = @"/tmp/trollvnc_upload.deb";
            NSError *writeError = nil;
            [body writeToFile:tmpPath options:NSDataWritingAtomic error:&writeError];
            if (writeError || ![[NSFileManager defaultManager] fileExistsAtPath:tmpPath]) {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{@"success": @NO, @"error": @"Failed to save uploaded deb file"};
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                return response;
            }
            debPath = tmpPath;
            shouldCleanup = YES;
            TVLog(@"HTTP Server: Install deb from uploaded body (%lu bytes)", (unsigned long)body.length);
        } else {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{@"success": @NO, @"error": @"Missing path parameter or request body. Usage: /api/install/deb?path=/path/to/app.deb or POST with deb file content"};
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
    }
    
    // 检查 .deb 文件是否存在（仅当使用 path 参数时）
    if (!shouldCleanup && access([debPath UTF8String], F_OK) != 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @".deb file not found", @"path": debPath};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Install deb request - path: %@", debPath);
    
    // 使用 posix_spawn 安装 .deb 文件
    pid_t pid;
    // 查找 dpkg 路径（支持多种越狱环境）
    const char *dpkgPaths[] = {
        "/usr/bin/dpkg",
        "/var/jb/usr/bin/dpkg",
        NULL
    };
    const char *dpkgPath = NULL;
    for (int i = 0; dpkgPaths[i] != NULL; i++) {
        if (access(dpkgPaths[i], X_OK) == 0) {
            dpkgPath = dpkgPaths[i];
            break;
        }
    }
    if (!dpkgPath) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *resultDict = @{@"success": @NO, @"error": @"dpkg not found."};
        response.body = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
        TVLog(@"HTTP Server: dpkg not found");
        return response;
    }
    const char *args[] = {"dpkg", "-i", [debPath UTF8String], NULL};
    const char *env[] = {NULL};
    
    // 设置文件操作以重定向 stdout 和 stderr 到日志文件
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    
    int logFd = open("/tmp/dpkg_install.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (logFd >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFd);
        // 注意：不能在 posix_spawn 前 close(logFd)
        // addclose 会在子进程中关闭 fd，父进程的 fd 等 spawn 后再关
    }
    
    // 等 posix_spawn 返回后再关闭父进程的 fd 副本
    int spawnResult = posix_spawn(&pid, dpkgPath, &actions, NULL, (char *const *)args, (char *const *)env);
    posix_spawn_file_actions_destroy(&actions);
    if (logFd >= 0) {
        close(logFd);  // 父进程在 spawn 后安全关闭
    }
    
    if (spawnResult != 0) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errorMsg = [NSString stringWithFormat:@"Failed to spawn dpkg: %d", spawnResult];
        NSDictionary *resultDict = @{@"success": @NO, @"error": errorMsg, @"path": debPath};
        response.body = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
        TVLog(@"HTTP Server: Failed to spawn dpkg: %d", spawnResult);
        return response;
    }
    
    int status;
    waitpid(pid, &status, 0);
    BOOL success = (WEXITSTATUS(status) == 0);
    
    if (success) {
        TVLog(@"HTTP Server: DEB installed successfully: %@", debPath);
        
        // 刷新图标缓存 (uicache -a)
        pid_t uicachePid;
        const char *uicachePath = "/usr/bin/uicache";
        const char *uicacheArgs[] = {"uicache", "-a", NULL};
        int uicacheResult = posix_spawn(&uicachePid, uicachePath, NULL, NULL, (char *const *)uicacheArgs, (char *const *)env);
        if (uicacheResult == 0) {
            int uicacheStatus;
            waitpid(uicachePid, &uicacheStatus, 0);
            TVLog(@"HTTP Server: uicache -a completed");
        } else {
            TVLog(@"HTTP Server: Failed to spawn uicache: %d", uicacheResult);
        }
        
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *resultDict = @{@"success": @YES, @"message": @"DEB package installed successfully, uicache triggered", @"path": debPath};
        response.body = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
        
        // 延迟注销设备（让响应先发出去）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TVLog(@"HTTP Server: Triggering respring after deb install");
            [[TVNCApiManager sharedManager] respringDevice];
        });
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *logContent = [NSString stringWithContentsOfFile:@"/tmp/dpkg_install.log" encoding:NSUTF8StringEncoding error:nil];
        NSString *errorMsg = logContent ?: @"DEB installation failed";
        NSDictionary *resultDict = @{@"success": @NO, @"error": errorMsg, @"path": debPath};
        response.body = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
        TVLog(@"HTTP Server: DEB installation failed: %@", errorMsg);
    }
    
    // 清理临时文件
    if (shouldCleanup) {
        [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/trollvnc_upload.deb" error:nil];
    }
    
    return response;
}

- (TVNCHttpResponse *)handleTrollStoreDiagnostics {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSDictionary *diagnostics = [[TVNCApiManager sharedManager] getTrollStoreDiagnostics];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:diagnostics options:NSJSONWritingPrettyPrinted error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleVolume:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *valueStr = query[@"value"];
    if (valueStr) {
        // 设置音量
        CGFloat volume = [valueStr floatValue];
        if (volume < 0.0 || volume > 1.0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{@"success": @NO, @"error": @"Volume must be between 0.0 and 1.0"};
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        BOOL success = [[TVNCApiManager sharedManager] setVolume:volume];
        response.statusCode = success ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = success ? 
            @{@"success": @YES, @"volume": @(volume)} :
            @{@"success": @NO, @"error": @"Failed to set volume"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        // 获取当前音量
        CGFloat currentVolume = [[TVNCApiManager sharedManager] getCurrentVolume];
        response.statusCode = (currentVolume >= 0) ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = (currentVolume >= 0) ? 
            @{@"success": @YES, @"volume": @(currentVolume)} :
            @{@"success": @NO, @"error": @"Failed to get volume"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

- (TVNCHttpResponse *)handleBrightness:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *valueStr = query[@"value"];
    if (valueStr) {
        // 设置亮度
        CGFloat brightness = [valueStr floatValue];
        if (brightness < 0.0 || brightness > 1.0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{@"success": @NO, @"error": @"Brightness must be between 0.0 and 1.0"};
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        BOOL success = [[TVNCApiManager sharedManager] setBrightness:brightness];
        response.statusCode = success ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = success ? 
            @{@"success": @YES, @"brightness": @(brightness)} :
            @{@"success": @NO, @"error": @"Failed to set brightness"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        // 获取当前亮度
        CGFloat currentBrightness = [[TVNCApiManager sharedManager] getCurrentBrightness];
        response.statusCode = (currentBrightness >= 0) ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = (currentBrightness >= 0) ? 
            @{@"success": @YES, @"brightness": @(currentBrightness)} :
            @{@"success": @NO, @"error": @"Failed to get brightness"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

- (TVNCHttpResponse *)handleKey:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *codeStr = query[@"code"];
    if (!codeStr) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Missing code parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    NSInteger keyCode = [codeStr integerValue];
    BOOL success = [[TVNCApiManager sharedManager] sendKeyCode:keyCode];
    
    response.statusCode = success ? 200 : 400;
    response.contentType = @"application/json";
    NSDictionary *result = success ? 
        @{@"success": @YES, @"keyCode": @(keyCode)} :
        @{@"success": @NO, @"error": @"Failed to send key or no active input field"};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleInput:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    // 解析 body 为 UTF-8 文本
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid UTF-8 text"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }

    TVLog(@"HTTP Server: Input text request - length: %lu", (unsigned long)text.length);

    // 方案1: 转发到 TrollVNC.app (端口 8184) 执行 AX API
    // App 是有界面进程，可以安全使用 AX API 支持中文
    // 先快速探活 App 的 /health：App 一旦被 iOS 挂起，8184 端口即失活，
    // 探活超时(0.3s)可立即判定，避免直接 POST /input 干等 2 秒才回退。
    BOOL appAlive = NO;
    @try {
        NSURL *healthUrl = [NSURL URLWithString:@"http://127.0.0.1:8184/health"];
        NSMutableURLRequest *healthReq = [NSMutableURLRequest requestWithURL:healthUrl];
        [healthReq setHTTPMethod:@"GET"];
        [healthReq setTimeoutInterval:0.3];
        NSURLResponse *healthResp = nil;
        NSError *healthErr = nil;
        NSData *healthData = [NSURLConnection sendSynchronousRequest:healthReq
                                                   returningResponse:&healthResp
                                                               error:&healthErr];
        if (!healthErr && healthData && [(NSHTTPURLResponse *)healthResp statusCode] == 200) {
            appAlive = YES;
        }
    } @catch (NSException *e) {
        appAlive = NO;
    }

    if (appAlive) {
        @try {
            NSURL *appUrl = [NSURL URLWithString:@"http://127.0.0.1:8184/input"];
            NSMutableURLRequest *appRequest = [NSMutableURLRequest requestWithURL:appUrl];
            [appRequest setHTTPMethod:@"POST"];
            [appRequest setHTTPBody:body];
            [appRequest setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
            [appRequest setTimeoutInterval:2.0];

            NSURLResponse *appResponse = nil;
            NSError *appError = nil;
            NSData *responseData = [NSURLConnection sendSynchronousRequest:appRequest
                                                        returningResponse:&appResponse
                                                                    error:&appError];

            if (!appError && responseData) {
                NSDictionary *result = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
                if ([result[@"success"] boolValue]) {
                    TVLog(@"HTTP Server: Input via App AX succeeded");
                    response.statusCode = 200;
                    response.contentType = @"application/json";
                    response.body = responseData;
                    return response;
                }
            }
            TVLog(@"HTTP Server: App AX forward failed: %@", appError.localizedDescription ?: @"unknown");
        } @catch (NSException *exception) {
            TVLog(@"HTTP Server: App AX forward exception: %@", exception.reason);
        }
    } else {
        TVLog(@"HTTP Server: App 8184 not alive (suspended or not running), skip forward");
    }

    // 方案2: 回退到 daemon 自身的 inputText（仅支持 ASCII）
    TVLog(@"HTTP Server: Falling back to daemon inputText");
    BOOL hasFocus = [[TVNCApiManager sharedManager] inputText:text];

    if (hasFocus) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"text": text, @"length": @(text.length), @"method": @"daemon"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"No active text input field found. Please focus an input field first."};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }

    return response;
}

- (TVNCHttpResponse *)handleAlert:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    NSString *message = query[@"message"];
    if (!message || message.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"Missing message parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }

    NSString *title = query[@"title"] ?: @"MatisuXCS";
    NSString *durationStr = query[@"duration"] ?: @"0";
    NSTimeInterval duration = [durationStr doubleValue];

    TVLog(@"HTTP Server: Show alert - title: %@, message: %@, duration: %.1f", title, message, duration);

    // 在主线程显示弹窗
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];

            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

            // 获取当前最上层 ViewController
            UIWindow *window = nil;
            if (@available(iOS 13.0, *)) {
                for (UIWindow *w in [UIApplication sharedApplication].connectedScenes) {
                    if ([w isKindOfClass:[UIWindowScene class]]) {
                        UIWindowScene *scene = (UIWindowScene *)w;
                        window = scene.keyWindow;
                        if (window && window.rootViewController) break;
                    }
                }
            }
            if (!window) {
                window = [UIApplication sharedApplication].keyWindow;
            }

            UIViewController *rootVC = window.rootViewController;
            while (rootVC.presentedViewController) {
                rootVC = rootVC.presentedViewController;
            }

            if (rootVC) {
                [rootVC presentViewController:alert animated:YES completion:nil];

                // duration > 0 时自动关闭弹窗
                if (duration > 0) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [alert dismissViewControllerAnimated:YES completion:nil];
                    });
                }
            } else {
                TVLog(@"HTTP Server: Cannot show alert - no rootViewController");
            }
        } @catch (NSException *e) {
            TVLog(@"HTTP Server: Show alert exception: %@", e);
        }
    });

    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"message": @"Alert shown",
        @"title": title,
        @"duration": @(duration)
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handlePing {
    TVNCHttpResponse *r = [[TVNCHttpResponse alloc] init];
    r.statusCode = 200;
    r.contentType = @"application/json";
    r.body = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}

- (TVNCHttpResponse *)handleStatus {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    
    // 使用局部变量避免多线程竞争
    NSUInteger currentPort = self.port;
    
    // 运行时从 bundle 读取版本号，避免编译缓存导致版本号不匹配
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    if (!version) {
        version = @PACKAGE_VERSION;
    }
    
    NSDictionary *result = @{
        @"status": @"running",
        @"httpPort": @(currentPort),
        @"version": version,
        @"memPressure": @(tvncGetMemPressureLevel()) // v4.34: 0=normal 1=warn 2=critical
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleClients {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 这里需要访问 trollvncserver 中的客户端列表
    // 暂时返回空列表，后续可以添加全局访问接口
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"clients": @[], @"count": @0};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleNetworkTestHelper {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    response.contentType = @"application/json";
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"parent_uid"] = @(getuid());
    result[@"parent_gid"] = @(getgid());
    
    // 获取自身路径
    char selfPath[PATH_MAX];
    uint32_t pathSize = sizeof(selfPath);
    if (_NSGetExecutablePath(selfPath, &pathSize) != 0) {
        result[@"success"] = @NO;
        result[@"error"] = @"_NSGetExecutablePath failed";
        response.statusCode = 500;
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    NSString *execPath = [NSString stringWithUTF8String:selfPath];
    result[@"execPath"] = execPath;
    
    // spawn 自身带 --root-helper test 参数
    NSString *helperOutput = nil;
    int helperExit = spawnAsRootWithOutput(execPath, @[@"--root-helper", @"test", @"{}"], &helperOutput);
    
    result[@"helperExit"] = @(helperExit);
    result[@"helperOutput"] = helperOutput ?: @"";
    result[@"helperOutputLength"] = @(helperOutput.length);
    
    // 尝试解析 helper 输出
    if (helperOutput.length > 0) {
        NSData *outData = [helperOutput dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *outJson = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
        if (outJson) {
            result[@"helperParsed"] = outJson;
            result[@"helperUid"] = outJson[@"uid"];
            result[@"success"] = @([outJson[@"success"] boolValue]);
        }
    }
    
    result[@"spawnWorked"] = @(helperExit != -1);
    
    response.statusCode = 200;
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleNetworkIpMethods:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    response.contentType = @"application/json";
    response.statusCode = 200;
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"uid"] = @(getuid());
    result[@"gid"] = @(getgid());
    result[@"euid"] = @(geteuid());
    
    // ---- 1. 检查 preferences.plist 文件权限 ----
    struct stat st;
    const char *prefsPath = "/var/preferences/SystemConfiguration/preferences.plist";
    if (stat(prefsPath, &st) == 0) {
        result[@"prefs_mode"] = [NSString stringWithFormat:@"%o", st.st_mode & 0777];
        result[@"prefs_uid"] = @(st.st_uid);
        result[@"prefs_gid"] = @(st.st_gid);
        result[@"prefs_size"] = @(st.st_size);
        result[@"prefs_writable_by_us"] = @((st.st_mode & S_IWOTH) || 
            (st.st_uid == getuid() && (st.st_mode & S_IWUSR)) ||
            (st.st_gid == getgid() && (st.st_mode & S_IWGRP)));
    } else {
        result[@"prefs_stat_error"] = [NSString stringWithFormat:@"stat failed: %s", strerror(errno)];
    }
    
    // 检查目录权限（是否可写）
    const char *dirPath = "/var/preferences/SystemConfiguration";
    if (stat(dirPath, &st) == 0) {
        result[@"dir_mode"] = [NSString stringWithFormat:@"%o", st.st_mode & 0777];
        result[@"dir_uid"] = @(st.st_uid);
        result[@"dir_gid"] = @(st.st_gid);
        result[@"dir_writable_by_us"] = @((st.st_mode & S_IWOTH) || 
            (st.st_uid == getuid() && (st.st_mode & S_IWUSR)) ||
            (st.st_gid == getgid() && (st.st_mode & S_IWGRP)));
    }
    
    // ---- 2. 尝试 ipconfig set 命令 ----
    // ipconfig 通过 configd IPC 通信，可能不需要 root
    NSString *testIp = query[@"ip"] ?: @"192.69.0.78";
    NSString *testMask = query[@"mask"] ?: @"255.255.255.0";
    
    // 先获取当前接口名
    NSString *iface = query[@"interface"] ?: @"en0";
    
    NSMutableDictionary *ipconfigResult = [NSMutableDictionary dictionary];
    
    // 尝试 ipconfig getifaddr 看看命令是否存在
    {
        FILE *pipe = popen("/usr/sbin/ipconfig getifaddr en0 2>&1", "r");
        if (pipe) {
            char buf[256];
            NSString *output = @"";
            if (fgets(buf, sizeof(buf), pipe)) {
                output = [NSString stringWithUTF8String:buf];
            }
            int exitCode = pclose(pipe);
            ipconfigResult[@"getifaddr_output"] = output;
            ipconfigResult[@"getifaddr_exit"] = @(exitCode);
        } else {
            ipconfigResult[@"getifaddr_error"] = @"popen failed";
        }
    }
    
    // 检查 ipconfig 路径
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *ipconfigPaths = @[@"/usr/sbin/ipconfig", @"/sbin/ipconfig", @"/usr/bin/ipconfig"];
    for (NSString *p in ipconfigPaths) {
        if ([fm fileExistsAtPath:p]) {
            ipconfigResult[@"ipconfig_path"] = p;
            break;
        }
    }
    if (!ipconfigResult[@"ipconfig_path"]) {
        ipconfigResult[@"ipconfig_path"] = @"not found";
    }
    
    // 尝试 ipconfig set en0 MANUAL ip mask
    if (![ipconfigResult[@"ipconfig_path"] isEqualToString:@"not found"]) {
        NSString *ipconfigPath = ipconfigResult[@"ipconfig_path"];
        NSString *cmd = [NSString stringWithFormat:@"%@ set %@ MANUAL %@ %@ 2>&1", 
                         ipconfigPath, iface, testIp, testMask];
        ipconfigResult[@"set_cmd"] = cmd;
        
        FILE *pipe = popen([cmd UTF8String], "r");
        if (pipe) {
            char buf[512];
            NSMutableString *output = [NSMutableString string];
            while (fgets(buf, sizeof(buf), pipe)) {
                [output appendString:[NSString stringWithUTF8String:buf]];
            }
            int exitCode = pclose(pipe);
            ipconfigResult[@"set_exit"] = @(exitCode);
            ipconfigResult[@"set_output"] = output;
            ipconfigResult[@"set_success"] = @(exitCode == 0);
        } else {
            ipconfigResult[@"set_error"] = @"popen failed";
        }
        
        // 也尝试设置 router
        NSString *routerCmd = [NSString stringWithFormat:@"%@ set %@ router %@ 2>&1",
                              ipconfigPath, iface, query[@"router"] ?: @"192.69.0.1"];
        FILE *rPipe = popen([routerCmd UTF8String], "r");
        if (rPipe) {
            char buf[256];
            NSString *rOut = @"";
            if (fgets(buf, sizeof(buf), rPipe)) {
                rOut = [NSString stringWithUTF8String:buf];
            }
            int rExit = pclose(rPipe);
            ipconfigResult[@"router_exit"] = @(rExit);
            ipconfigResult[@"router_output"] = rOut;
        }
    }
    
    result[@"ipconfig"] = ipconfigResult;
    
    // ---- 3. 尝试 SCDynamicStore ----
    NSMutableDictionary *scStoreResult = [NSMutableDictionary dictionary];
    void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
    if (!sc) {
        sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/Versions/Current/SystemConfiguration", RTLD_NOW);
    }
    
    if (sc) {
        typedef void* SCDynamicStoreRef;
        SCDynamicStoreRef (*pSCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, void*, void*) =
            (SCDynamicStoreRef (*)(CFAllocatorRef, CFStringRef, void*, void*))dlsym(sc, "SCDynamicStoreCreate");
        CFPropertyListRef (*pSCDynamicStoreCopyValue)(SCDynamicStoreRef, CFStringRef) =
            (CFPropertyListRef (*)(SCDynamicStoreRef, CFStringRef))dlsym(sc, "SCDynamicStoreCopyValue");
        Boolean (*pSCDynamicStoreSetValue)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef) =
            (Boolean (*)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef))dlsym(sc, "SCDynamicStoreSetValue");
        Boolean (*pSCDynamicStoreAddTemporaryValue)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef) =
            (Boolean (*)(SCDynamicStoreRef, CFStringRef, CFPropertyListRef))dlsym(sc, "SCDynamicStoreAddTemporaryValue");
        CFArrayRef (*pSCDynamicStoreCopyKeyList)(SCDynamicStoreRef, CFStringRef) =
            (CFArrayRef (*)(SCDynamicStoreRef, CFStringRef))dlsym(sc, "SCDynamicStoreCopyKeyList");
        
        scStoreResult[@"dlopen"] = @"ok";
        scStoreResult[@"SCDynamicStoreCreate"] = pSCDynamicStoreCreate ? @"ok" : @"null";
        scStoreResult[@"SCDynamicStoreCopyValue"] = pSCDynamicStoreCopyValue ? @"ok" : @"null";
        scStoreResult[@"SCDynamicStoreSetValue"] = pSCDynamicStoreSetValue ? @"ok" : @"null";
        scStoreResult[@"SCDynamicStoreAddTemporaryValue"] = pSCDynamicStoreAddTemporaryValue ? @"ok" : @"null";
        
        if (pSCDynamicStoreCreate) {
            SCDynamicStoreRef store = pSCDynamicStoreCreate(NULL, CFSTR("TrollVNC-diag"), NULL, NULL);
            scStoreResult[@"store_created"] = store ? @"yes" : @"no";
            
            if (store) {
                // 读当前全局 IPv4 状态
                if (pSCDynamicStoreCopyValue) {
                    CFPropertyListRef val = pSCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
                    if (val) {
                        scStoreResult[@"read_global_ipv4"] = (__bridge NSDictionary *)val;
                        CFRelease(val);
                    } else {
                        scStoreResult[@"read_global_ipv4"] = @"null";
                    }
                    
                    // 列出所有 Setup: 和 State: 键
                    if (pSCDynamicStoreCopyKeyList) {
                        CFArrayRef keys = pSCDynamicStoreCopyKeyList(store, CFSTR("State:/Network/Service/.*IPv4"));
                        if (keys) {
                            NSArray *keyArr = (__bridge NSArray *)keys;
                            scStoreResult[@"state_ipv4_keys"] = keyArr;
                            CFRelease(keys);
                        }
                        
                        CFArrayRef setupKeys = pSCDynamicStoreCopyKeyList(store, CFSTR("Setup:/Network/Service/.*IPv4"));
                        if (setupKeys) {
                            NSArray *setupKeyArr = (__bridge NSArray *)setupKeys;
                            scStoreResult[@"setup_ipv4_keys"] = setupKeyArr;
                            CFRelease(setupKeys);
                        }
                    }
                }
                
                // 尝试 AddTemporaryValue (可能不需要写权限)
                if (pSCDynamicStoreAddTemporaryValue) {
                    NSDictionary *testVal = @{
                        @"Addresses": @[testIp],
                        @"SubnetMasks": @[testMask],
                        @"InterfaceName": iface
                    };
                    Boolean addOK = pSCDynamicStoreAddTemporaryValue(store, 
                        CFSTR("State:/Network/Service/trollvnc-test/IPv4"),
                        (__bridge CFPropertyListRef)testVal);
                    scStoreResult[@"add_temp_value"] = @(addOK);
                }
                
                // 尝试 SetValue (需要写权限)
                if (pSCDynamicStoreSetValue) {
                    NSDictionary *testVal = @{
                        @"Addresses": @[testIp],
                        @"SubnetMasks": @[testMask],
                        @"InterfaceName": iface
                    };
                    Boolean setOK = pSCDynamicStoreSetValue(store,
                        CFSTR("State:/Network/Service/trollvnc-test/IPv4"),
                        (__bridge CFPropertyListRef)testVal);
                    scStoreResult[@"set_value"] = @(setOK);
                }
                
                CFRelease(store);
            }
        }
    } else {
        scStoreResult[@"dlopen"] = @"failed";
    }
    result[@"scdynamic_store"] = scStoreResult;
    
    // ---- 4. 尝试直接写 preferences.plist（确认失败）----
    NSMutableDictionary *writeTest = [NSMutableDictionary dictionary];
    @try {
        NSString *testPath = @"/var/preferences/SystemConfiguration/.trollvnc_write_test";
        NSString *testContent = @"test";
        BOOL writeOK = [testContent writeToFile:testPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        writeTest[@"direct_write_test"] = @(writeOK);
        if (writeOK) {
            [fm removeItemAtPath:testPath error:nil];
        }
        
        // 也测试写到目录
        struct stat dirSt;
        if (stat("/var/preferences/SystemConfiguration", &dirSt) == 0) {
            writeTest[@"dir_mode"] = [NSString stringWithFormat:@"%o", dirSt.st_mode & 0777];
            writeTest[@"can_create_file"] = @((dirSt.st_mode & S_IWOTH) || 
                (dirSt.st_uid == getuid() && (dirSt.st_mode & S_IWUSR)) ||
                (dirSt.st_gid == getgid() && (dirSt.st_mode & S_IWGRP)));
        }
    } @catch (NSException *e) {
        writeTest[@"exception"] = e.description;
    }
    result[@"write_test"] = writeTest;
    
    // ---- 5. 尝试 ifconfig 命令 ----
    NSMutableDictionary *ifconfigResult = [NSMutableDictionary dictionary];
    {
        // 检查 ifconfig 路径
        NSArray *ifconfigPaths = @[@"/sbin/ifconfig", @"/usr/sbin/ifconfig", @"/usr/bin/ifconfig"];
        for (NSString *p in ifconfigPaths) {
            if ([fm fileExistsAtPath:p]) {
                ifconfigResult[@"ifconfig_path"] = p;
                break;
            }
        }
        if (!ifconfigResult[@"ifconfig_path"]) {
            ifconfigResult[@"ifconfig_path"] = @"not found";
        }
        
        if (![ifconfigResult[@"ifconfig_path"] isEqualToString:@"not found"]) {
            // 读取当前 ifconfig en0
            NSString *cmd = [NSString stringWithFormat:@"%@ %@ 2>&1", ifconfigResult[@"ifconfig_path"], iface];
            FILE *pipe = popen([cmd UTF8String], "r");
            if (pipe) {
                char buf[2048];
                NSMutableString *output = [NSMutableString string];
                while (fgets(buf, sizeof(buf), pipe)) {
                    [output appendString:[NSString stringWithUTF8String:buf]];
                }
                pclose(pipe);
                ifconfigResult[@"ifconfig_output"] = output;
            }
        }
    }
    result[@"ifconfig"] = ifconfigResult;
    
    result[@"success"] = @YES;
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleNetworkDebug {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    response.contentType = @"application/json";
    response.statusCode = 200;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    // 1. 列出所有 SystemConfiguration 目录
    NSArray *dirs = @[
        @"/Library/Preferences/SystemConfiguration",
        @"/var/preferences/SystemConfiguration",
        @"/var/jb/Library/Preferences/SystemConfiguration",
        @"/var/jb/var/preferences/SystemConfiguration"
    ];
    
    NSMutableDictionary *dirInfo = [NSMutableDictionary dictionary];
    for (NSString *dir in dirs) {
        NSError *dirErr = nil;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&dirErr];
        if (files) {
            NSMutableDictionary *fileDetails = [NSMutableDictionary dictionary];
            for (NSString *file in files) {
                NSString *fullPath = [dir stringByAppendingPathComponent:file];
                NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                if (attrs) {
                    struct stat st;
                    NSString *statInfo = @"";
                    if (stat([fullPath UTF8String], &st) == 0) {
                        statInfo = [NSString stringWithFormat:@"mode=%o uid=%d gid=%d size=%lld",
                                    st.st_mode, st.st_uid, st.st_gid, st.st_size];
                    }
                    fileDetails[file] = @{
                        @"size": attrs[NSFileSize] ?: @0,
                        @"stat": statInfo
                    };
                }
            }
            dirInfo[dir] = fileDetails;
        } else {
            dirInfo[dir] = @{@"error": dirErr.localizedDescription ?: @"not found"};
        }
    }
    result[@"directories"] = dirInfo;
    
    // 2. 读取 com.apple.wifi.plist
    NSArray *wifiPaths = @[
        @"/var/preferences/SystemConfiguration/com.apple.wifi.plist",
        @"/Library/Preferences/SystemConfiguration/com.apple.wifi.plist",
        @"/var/jb/var/preferences/SystemConfiguration/com.apple.wifi.plist"
    ];
    
    for (NSString *wifiPath in wifiPaths) {
        if ([fm fileExistsAtPath:wifiPath]) {
            NSDictionary *wifiPlist = [NSDictionary dictionaryWithContentsOfFile:wifiPath];
            if (wifiPlist) {
                result[@"wifi_plist_path"] = wifiPath;
                result[@"wifi_plist_top_keys"] = wifiPlist.allKeys;
                
                // 返回每个顶层 key 的值类型和摘要
                NSMutableDictionary *structure = [NSMutableDictionary dictionary];
                for (NSString *key in wifiPlist) {
                    id value = wifiPlist[key];
                    if ([value isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *d = value;
                        structure[key] = [NSString stringWithFormat:@"dict(%lu keys): %@",
                                          (unsigned long)d.count, d.allKeys.description];
                    } else if ([value isKindOfClass:[NSArray class]]) {
                        NSArray *a = value;
                        structure[key] = [NSString stringWithFormat:@"array(%lu items)",
                                          (unsigned long)a.count];
                    } else if ([value isKindOfClass:[NSData class]]) {
                        structure[key] = [NSString stringWithFormat:@"data(%lu bytes)",
                                          (unsigned long)[value length]];
                    } else {
                        structure[key] = [value description];
                    }
                }
                result[@"wifi_plist_structure"] = structure;
            } else {
                result[@"wifi_plist_error"] = [NSString stringWithFormat:@"Found %@ but cannot read as plist", wifiPath];
            }
            break;
        }
    }
    
    // 3. 读取 com.apple.wifi-manager.plist (如果存在)
    NSArray *wifiMgrPaths = @[
        @"/var/preferences/SystemConfiguration/com.apple.wifi-manager.plist",
        @"/Library/Preferences/SystemConfiguration/com.apple.wifi-manager.plist"
    ];
    for (NSString *mgrPath in wifiMgrPaths) {
        if ([fm fileExistsAtPath:mgrPath]) {
            NSDictionary *mgrPlist = [NSDictionary dictionaryWithContentsOfFile:mgrPath];
            if (mgrPlist) {
                result[@"wifi_manager_path"] = mgrPath;
                result[@"wifi_manager_keys"] = mgrPlist.allKeys;
            }
            break;
        }
    }
    
    // 4. 测试写入权限
    NSMutableDictionary *writeTest = [NSMutableDictionary dictionary];
    NSArray *testPaths = @[
        @"/var/preferences/SystemConfiguration/",
        @"/Library/Preferences/SystemConfiguration/",
        @"/var/jb/var/preferences/SystemConfiguration/",
        @"/tmp/"
    ];
    for (NSString *testDir in testPaths) {
        NSString *testFile = [testDir stringByAppendingPathComponent:@".trollvnc_write_test"];
        NSString *testData = @"test";
        NSError *writeErr = nil;
        BOOL ok = [testData writeToFile:testFile atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
        writeTest[testDir] = @{
            @"can_write": @(ok),
            @"error": writeErr ? writeErr.localizedDescription : @"ok"
        };
        if (ok) {
            [fm removeItemAtPath:testFile error:nil];
        }
    }
    result[@"write_test"] = writeTest;
    
    // 5. 当前进程信息
    result[@"process"] = @{
        @"uid": @(getuid()),
        @"gid": @(getgid()),
        @"pid": @(getpid())
    };
    
    // 6. 检查关键命令是否存在
    NSArray *cmds = @[
        @"/bin/cp", @"/usr/bin/cp",
        @"/bin/chmod", @"/usr/bin/chmod",
        @"/usr/bin/plutil", @"/usr/bin/defaults",
        @"/bin/launchctl", @"/usr/bin/launchctl",
        @"/usr/bin/id", @"/bin/id",
        @"/bin/ls", @"/usr/bin/ls",
        @"/usr/bin/cat", @"/bin/cat"
    ];
    NSMutableDictionary *cmdCheck = [NSMutableDictionary dictionary];
    for (NSString *cmd in cmds) {
        cmdCheck[cmd] = @(access([cmd UTF8String], X_OK) == 0);
    }
    result[@"commands"] = cmdCheck;
    
    // 7. spawnAsRoot 测试 - 执行 id 命令验证 persona API 是否生效
    NSString *idOutput = nil;
    NSString *idPath = access("/usr/bin/id", X_OK) == 0 ? @"/usr/bin/id" : 
                       (access("/bin/id", X_OK) == 0 ? @"/bin/id" : nil);
    if (idPath) {
        int idExit = spawnAsRootWithOutput(idPath, nil, &idOutput);
        result[@"spawnAsRoot_test"] = @{
            @"command": idPath,
            @"exit_code": @(idExit),
            @"output": idOutput ?: @"(no output)"
        };
    } else {
        result[@"spawnAsRoot_test"] = @{@"error": @"id command not found"};
    }
    
    // 8. 读取 preferences.plist 结构（CurrentSet 和 Service 列表）
    NSString *prefsPath = @"/Library/Preferences/SystemConfiguration/preferences.plist";
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefsPath];
    if (prefs) {
        NSMutableDictionary *prefsInfo = [NSMutableDictionary dictionary];
        prefsInfo[@"top_keys"] = prefs.allKeys;
        
        NSString *currentSet = prefs[@"CurrentSet"]; // e.g. "/Sets/A1B2C3..."
        prefsInfo[@"current_set"] = currentSet ?: @"(not found)";
        
        // 读取 Sets -> CurrentSet -> Network -> Service
        if (currentSet) {
            NSDictionary *sets = prefs[@"Sets"];
            if (sets && [sets isKindOfClass:[NSDictionary class]]) {
                NSDictionary *currentSetDict = sets[currentSet];
                if (currentSetDict && [currentSetDict isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *network = currentSetDict[@"Network"];
                    if (network && [network isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *services = network[@"Service"];
                        if (services && [services isKindOfClass:[NSDictionary class]]) {
                            NSMutableDictionary *svcInfo = [NSMutableDictionary dictionary];
                            for (NSString *svcID in services) {
                                NSDictionary *svc = services[svcID];
                                if ([svc isKindOfClass:[NSDictionary class]]) {
                                    NSString *name = svc[@"UserDefinedName"] ?: @"(no name)";
                                    NSDictionary *ipv4 = svc[@"IPv4"];
                                    NSDictionary *iface = svc[@"Interface"];
                                    NSString *type = iface[@"Type"] ?: @"(no type)";
                                    svcInfo[svcID] = @{
                                        @"name": name,
                                        @"type": type,
                                        @"has_ipv4": @(ipv4 != nil),
                                        @"ipv4_keys": ipv4 ? ipv4.allKeys : @[]
                                    };
                                }
                            }
                            prefsInfo[@"services"] = svcInfo;
                        }
                    }
                }
            }
        }
        result[@"preferences_plist"] = prefsInfo;
    } else {
        result[@"preferences_plist"] = @{@"error": @"cannot read preferences.plist"};
    }
    
    response.body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONReadingAllowFragments error:nil];
    return response;
}

- (TVNCHttpResponse *)handleTestInterface {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    response.statusCode = 200;
    response.contentType = @"application/json";
    
    NSDictionary *result = @{
        @"status": @"ok",
        @"message": @"TrollVNC HTTP API is working",
        @"version": @PACKAGE_VERSION
    };
    
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleRoot {
    // 根路径只显示极简运行状态，完整 API 文档需访问 /api/endpoints?key=xxx
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    NSString *html = @"<!DOCTYPE html>"
        "<html><head><meta charset='UTF-8'><title>TrollVNC</title></head>"
        "<body><h1>Matisu欢迎你</h1>"
        "</body></html>";
    response.statusCode = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    return response;
}

- (TVNCHttpResponse *)handleEndpoints:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    NSString *key = query[@"key"];
    if (![key isEqualToString:kTVNCEndpointsKey]) {
        response.statusCode = 403;
        response.contentType = @"application/json";
        NSDictionary *err = @{@"error": @"Forbidden", @"message": @"missing or invalid key"};
        response.body = [NSJSONSerialization dataWithJSONObject:err options:0 error:nil];
        return response;
    }

    // 按分类顺序自动生成文档（分类顺序以此数组为准）
    NSArray<NSString *> *categoryOrder = @[@"截图 / 流媒体", @"文件", @"剪贴板", @"输入", @"状态 / 设备",
                                           @"系统控制", @"安装 / 卸载", @"网络调试", @"群控", @"页面"];
    NSArray<NSDictionary *> *routes = [[self class] tvncRouteRegistry];

    NSMutableString *html = [NSMutableString stringWithString:
        @"<!DOCTYPE html><html><head><meta charset='UTF-8'><title>TrollVNC API</title>"
        "<style>body{font-family:-apple-system,system-ui,sans-serif;margin:24px;background:#0f1115;color:#e6e6e6}"
        "h1{color:#4fd1ff}h2{color:#9aa0a6;margin-top:28px;border-bottom:1px solid #2a2f36;padding-bottom:6px}"
        "li{margin:6px 0;line-height:1.5}code{color:#7ee787}</style></head><body>"
        "<h1>TrollVNC HTTP API</h1>"];

    NSString *lastCategory = nil;
    for (NSString *cat in categoryOrder) {
        BOOL printedHeader = NO;
        for (NSDictionary *r in routes) {
            if (![r[@"category"] isEqualToString:cat]) continue;
            if (!printedHeader) {
                [html appendFormat:@"<h2>%@</h2><ul>", cat];
                printedHeader = YES;
                lastCategory = cat;
            }
            [html appendFormat:@"<li><code><b>%@</b></code> - %@</li>", r[@"path"], r[@"doc"]];
        }
        if (printedHeader) [html appendString:@"</ul>"];
    }
    // 兜底：注册表中存在但不在 categoryOrder 里的分类
    for (NSDictionary *r in routes) {
        if ([categoryOrder containsObject:r[@"category"]]) continue;
        if (![lastCategory isEqualToString:r[@"category"]]) {
            [html appendFormat:@"<h2>%@</h2><ul>", r[@"category"]];
            lastCategory = r[@"category"];
        }
        [html appendFormat:@"<li><code><b>%@</b></code> - %@</li>", r[@"path"], r[@"doc"]];
    }
    [html appendString:@"</body></html>"];

    response.statusCode = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];

    return response;
}

// GET /api/hardware
// 返回设备硬件详细信息：CPU（核心数/使用率/family）、内存（总量/已用/空闲）、电池（电量/充电状态）、散热状态、系统运行时间
- (TVNCHttpResponse *)handleHardware:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // ─── CPU 信息 ───
    NSMutableDictionary *cpu = [NSMutableDictionary dictionary];
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];

    // 核心数
    cpu[@"coreCount"] = @(processInfo.processorCount);
    cpu[@"activeCoreCount"] = @(processInfo.activeProcessorCount);

    // CPU family (A系列芯片标识)
    int cpuFamily = 0;
    size_t familySize = sizeof(cpuFamily);
    if (sysctlbyname("hw.cpufamily", &cpuFamily, &familySize, NULL, 0) == 0) {
        cpu[@"cpuFamily"] = @(cpuFamily);
        cpu[@"cpuFamilyHex"] = [NSString stringWithFormat:@"0x%08X", cpuFamily];
    } else {
        cpu[@"cpuFamily"] = @"unknown";
    }

    // CPU subtype
    int cpuSubtype = 0;
    size_t subtypeSize = sizeof(cpuSubtype);
    if (sysctlbyname("hw.cpusubtype", &cpuSubtype, &subtypeSize, NULL, 0) == 0) {
        cpu[@"cpuSubtype"] = @(cpuSubtype);
    }

    // CPU 使用率（通过 host_processor_info — 累计值，仅供参考）
    processor_info_array_t cpuInfo = NULL;
    mach_msg_type_number_t cpuInfoCount = 0;
    natural_t processorCount = 0;
    natural_t cpuLoadInfoCount = 0;

    kern_return_t kr = host_processor_info(mach_host_self(),
                                           PROCESSOR_CPU_LOAD_INFO,
                                           &processorCount,
                                           &cpuInfo,
                                           &cpuLoadInfoCount);
    if (kr == KERN_SUCCESS && cpuInfo != NULL && processorCount > 0) {
        float totalUser = 0, totalSystem = 0, totalIdle = 0, totalNice = 0;
        for (natural_t i = 0; i < processorCount; i++) {
            natural_t offset = i * CPU_STATE_MAX;
            totalUser   += cpuInfo[offset + CPU_STATE_USER];
            totalSystem += cpuInfo[offset + CPU_STATE_SYSTEM];
            totalIdle   += cpuInfo[offset + CPU_STATE_IDLE];
            totalNice   += cpuInfo[offset + CPU_STATE_NICE];
        }
        float totalTicks = totalUser + totalSystem + totalIdle + totalNice;
        if (totalTicks > 0) {
            cpu[@"usageUserPercent"]   = @(totalUser   * 100.0 / totalTicks);
            cpu[@"usageSystemPercent"] = @(totalSystem * 100.0 / totalTicks);
            cpu[@"usageIdlePercent"]   = @(totalIdle   * 100.0 / totalTicks);
            cpu[@"usagePercent"]       = @((totalUser + totalSystem + totalNice) * 100.0 / totalTicks);
        }
        vm_deallocate(mach_task_self_, (vm_address_t)cpuInfo, cpuInfoCount * sizeof(integer_t));
    }

    // CPU 使用率（"最近负载"快照法 — 100ms 间隔采样取差值，更准确反映瞬时负载）
    {
        host_cpu_load_info_data_t prevLoad, currLoad;
        mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
        if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&prevLoad, &count) == KERN_SUCCESS) {
            usleep(100000); // 100ms
            count = HOST_CPU_LOAD_INFO_COUNT;
            if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&currLoad, &count) == KERN_SUCCESS) {
                natural_t userDiff   = currLoad.cpu_ticks[CPU_STATE_USER]   - prevLoad.cpu_ticks[CPU_STATE_USER];
                natural_t systemDiff = currLoad.cpu_ticks[CPU_STATE_SYSTEM] - prevLoad.cpu_ticks[CPU_STATE_SYSTEM];
                natural_t idleDiff   = currLoad.cpu_ticks[CPU_STATE_IDLE]   - prevLoad.cpu_ticks[CPU_STATE_IDLE];
                natural_t niceDiff   = currLoad.cpu_ticks[CPU_STATE_NICE]   - prevLoad.cpu_ticks[CPU_STATE_NICE];
                natural_t totalDiff  = userDiff + systemDiff + idleDiff + niceDiff;

                if (totalDiff > 0) {
                    cpu[@"usageUserPercentInstant"]   = @(userDiff   * 100.0 / totalDiff);
                    cpu[@"usageSystemPercentInstant"] = @(systemDiff * 100.0 / totalDiff);
                    cpu[@"usageIdlePercentInstant"]   = @(idleDiff   * 100.0 / totalDiff);
                    cpu[@"usagePercentInstant"]       = @((userDiff + systemDiff + niceDiff) * 100.0 / totalDiff);
                }
            }
        }
    }

    result[@"cpu"] = cpu;

    // ─── 内存信息 ───
    NSMutableDictionary *ram = [NSMutableDictionary dictionary];

    // 总物理内存
    uint64_t totalMem = processInfo.physicalMemory;
    ram[@"totalBytes"] = @(totalMem);

    // VM 统计（页大小 x 各类页数）
    mach_port_t hostPort = mach_host_self();
    vm_size_t pageSize = 0;
    host_page_size(hostPort, &pageSize);

    vm_statistics64_data_t vmStat;
    mach_msg_type_number_t vmCount = HOST_VM_INFO64_COUNT;
    if (host_statistics64(hostPort, HOST_VM_INFO64, (host_info64_t)&vmStat, &vmCount) == KERN_SUCCESS) {
        uint64_t freePages        = vmStat.free_count;
        uint64_t activePages      = vmStat.active_count;
        uint64_t inactivePages    = vmStat.inactive_count;
        uint64_t wiredPages       = vmStat.wire_count;
        uint64_t speculativePages = vmStat.speculative_count;
        uint64_t compressedPages  = vmStat.compressor_page_count;
        uint64_t purgeablePages   = vmStat.purgeable_count;

        uint64_t usedPages = wiredPages + activePages + compressedPages;
        uint64_t freeUsablePages = freePages + inactivePages + speculativePages + purgeablePages;

        ram[@"freeBytes"]       = @(freePages * pageSize);
        ram[@"activeBytes"]     = @(activePages * pageSize);
        ram[@"inactiveBytes"]   = @(inactivePages * pageSize);
        ram[@"wiredBytes"]      = @(wiredPages * pageSize);
        ram[@"compressedBytes"] = @(compressedPages * pageSize);
        ram[@"usedBytes"]       = @(usedPages * pageSize);
        ram[@"usableFreeBytes"] = @(freeUsablePages * pageSize);
        ram[@"usedPercent"]     = @(totalMem > 0 ? (usedPages * pageSize * 100.0 / totalMem) : 0);
    }

    // 易读格式
    ram[@"totalMB"] = @(totalMem / (1024.0 * 1024.0));
    if (ram[@"usedBytes"]) {
        uint64_t used = [ram[@"usedBytes"] unsignedLongLongValue];
        ram[@"usedMB"] = @(used / (1024.0 * 1024.0));
    }
    if (ram[@"freeBytes"]) {
        uint64_t free = [ram[@"freeBytes"] unsignedLongLongValue];
        ram[@"freeMB"] = @(free / (1024.0 * 1024.0));
    }

    // 内存压力级别（OS 级别 — kern.memorystatus_level）
    {
        int pressureLevel = 0;
        size_t psize = sizeof(pressureLevel);
        if (sysctlbyname("kern.memorystatus_level", &pressureLevel, &psize, NULL, 0) == 0) {
            // 0=normal, 1=warn, 2=critical, 4=urgent
            ram[@"memoryPressureLevel"] = @(pressureLevel);
            NSString *pressureStr = @"normal";
            if (pressureLevel >= 4)      pressureStr = @"urgent";
            else if (pressureLevel >= 2) pressureStr = @"critical";
            else if (pressureLevel >= 1) pressureStr = @"warn";
            ram[@"memoryPressure"] = pressureStr;
        }
    }

    result[@"ram"] = ram;

    // ─── 电池信息 ───
    NSMutableDictionary *battery = [NSMutableDictionary dictionary];
    UIDevice *device = [UIDevice currentDevice];
    [device setBatteryMonitoringEnabled:YES];

    float level = device.batteryLevel;
    battery[@"level"] = (level >= 0) ? @(level * 100.0) : @(-1);
    battery[@"levelRaw"] = @(level);

    UIDeviceBatteryState bstate = device.batteryState;
    NSString *stateStr = @"unknown";
    BOOL isCharging = NO;
    switch (bstate) {
        case UIDeviceBatteryStateUnplugged: stateStr = @"discharging"; break;
        case UIDeviceBatteryStateCharging:  stateStr = @"charging"; isCharging = YES; break;
        case UIDeviceBatteryStateFull:      stateStr = @"full"; isCharging = YES; break;
        default: break;
    }
    battery[@"state"] = stateStr;
    battery[@"isCharging"] = @(isCharging);

    [device setBatteryMonitoringEnabled:NO];
    result[@"battery"] = battery;

    // ─── 散热状态 ───
    NSMutableDictionary *thermal = [NSMutableDictionary dictionary];
    NSProcessInfoThermalState tstate = processInfo.thermalState;
    NSString *thermalStr = @"unknown";
    switch (tstate) {
        case NSProcessInfoThermalStateNominal:  thermalStr = @"nominal"; break;
        case NSProcessInfoThermalStateFair:     thermalStr = @"fair"; break;
        case NSProcessInfoThermalStateSerious:  thermalStr = @"serious"; break;
        case NSProcessInfoThermalStateCritical: thermalStr = @"critical"; break;
        default: break;
    }
    thermal[@"state"] = thermalStr;
    thermal[@"level"] = @(tstate);

    // v4.37: 具体温度值（通过 IOKit 读取传感器）
    // 尝试多个温度源：电池（最可靠）+ SoC（尝试多个节点）
    NSMutableDictionary *temps = [NSMutableDictionary dictionary];

    // 1. 电池温度 — IOServiceNameMatching("battery") → "Temperature" 属性
    //    Temperature 是 int32_t，单位 1/100°C（如 3250 = 32.50°C）
    {
        io_service_t batSvc = IOServiceGetMatchingService(0, IOServiceNameMatching("battery"));
        if (batSvc) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(batSvc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFNumberRef tempRef = (CFNumberRef)CFDictionaryGetValue(props, CFSTR("Temperature"));
                if (tempRef && CFGetTypeID(tempRef) == CFNumberGetTypeID()) {
                    int32_t tempRaw = 0;
                    if (CFNumberGetValue(tempRef, kCFNumberSInt32Type, &tempRaw)) {
                        double celsius = tempRaw / 100.0;
                        temps[@"battery"] = @{
                            @"celsius":    @(celsius),
                            @"fahrenheit": @(celsius * 1.8 + 32.0)
                        };
                    }
                }
                CFRelease(props);
            }
            IOObjectRelease(batSvc);
        }
    }

    // 2. SoC/CPU 温度 — 尝试多个传感器节点
    //    AppleARMTemperatureSensor：A 系列芯片温度传感器（常见于 A10+）
    //    ARMIODevice：旧设备
    //    AppleSMCTherMO：Mac 风格 SMC（部分 iPad/iOS 设备）
    {
        NSArray *sensorCandidates = @[
            @"AppleARMTemperatureSensor",
            @"ARMIODevice",
            @"AppleSMCTherMO"
        ];
        BOOL foundSOC = NO;
        for (NSString *sensorName in sensorCandidates) {
            if (foundSOC) break;
            io_service_t socSvc = IOServiceGetMatchingService(0, IOServiceNameMatching([sensorName UTF8String]));
            if (!socSvc) continue;

            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(socSvc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                NSMutableDictionary *socTemps = [NSMutableDictionary dictionary];
                CFIndex count = CFDictionaryGetCount(props);
                if (count > 0) {
                    const void **keys   = (const void **)malloc(sizeof(void *) * count);
                    const void **values = (const void **)malloc(sizeof(void *) * count);
                    CFDictionaryGetKeysAndValues(props, keys, values);
                    for (CFIndex i = 0; i < count; i++) {
                        NSString *key = (__bridge NSString *)keys[i];
                        CFTypeRef   val = values[i];
                        // 只处理数值类型的温度属性
                        if (CFGetTypeID(val) != CFNumberGetTypeID()) continue;
                        if (![key containsString:@"Temperature"] && ![key hasSuffix:@"Temp"]) continue;

                        int32_t rawVal = 0;
                        if (CFNumberGetValue((CFNumberRef)val, kCFNumberSInt32Type, &rawVal)) {
                            // 不同传感器缩放因子不同：
                            // - AppleARMTemperatureSensor 通常用 1/1000°C（如 35000 = 35.00°C）
                            // - battery 用 1/100°C
                            // 启发式：> 10000 → /1000，否则 → /100
                            double celsius;
                            if (rawVal > 10000) {
                                celsius = rawVal / 1000.0;
                            } else {
                                celsius = rawVal / 100.0;
                            }
                            // 合理性检查：-20°C ~ 120°C
                            if (celsius > -20.0 && celsius < 120.0) {
                                socTemps[key] = @{
                                    @"celsius":    @(celsius),
                                    @"fahrenheit": @(celsius * 1.8 + 32.0)
                                };
                            }
                        }
                    }
                    free(keys);
                    free(values);
                }
                if (socTemps.count > 0) {
                    temps[@"soc"] = socTemps;
                    foundSOC = YES;
                }
                CFRelease(props);
            }
            IOObjectRelease(socSvc);
        }
    }

    if (temps.count > 0) {
        thermal[@"temperatures"] = temps;
    } else {
        thermal[@"temperatures"] = @{ @"note": @"IOKit temperature sensors not accessible (sandbox or permission restricted)" };
    }

    result[@"thermal"] = thermal;

    // ─── 系统运行时间 ───
    NSMutableDictionary *uptime = [NSMutableDictionary dictionary];
    {
        struct timespec ts;
        if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
            uptime[@"seconds"] = @(ts.tv_sec);
            uint64_t totalSec = (uint64_t)ts.tv_sec;
            uint64_t days    = totalSec / 86400;
            uint64_t hours   = (totalSec % 86400) / 3600;
            uint64_t minutes = (totalSec % 3600) / 60;
            uint64_t seconds = totalSec % 60;
            uptime[@"human"] = [NSString stringWithFormat:@"%llu天 %llu小时 %llu分钟 %llu秒",
                                days, hours, minutes, seconds];
        } else {
            uptime[@"error"] = @"clock_gettime failed";
        }
    }
    result[@"uptime"] = uptime;

    // ─── 系统内核 / 架构信息 ───
    {
        struct utsname sysInfo;
        if (uname(&sysInfo) == 0) {
            result[@"kernelVersion"] = [NSString stringWithUTF8String:sysInfo.release];
            result[@"machineArch"]   = [NSString stringWithUTF8String:sysInfo.machine];
            result[@"kernelName"]    = [NSString stringWithUTF8String:sysInfo.sysname];
            result[@"nodeName"]      = [NSString stringWithUTF8String:sysInfo.nodename];
        }
    }

    // ─── 当前进程虚拟内存统计 ───
    {
        struct task_vm_info vmInfo;
        mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
            NSMutableDictionary *procVm = [NSMutableDictionary dictionary];
            procVm[@"virtualSizeMB"]      = @(vmInfo.virtual_size / (1024.0 * 1024.0));
            procVm[@"residentSizeMB"]     = @(vmInfo.resident_size / (1024.0 * 1024.0));
            procVm[@"residentSizePeakMB"] = @(vmInfo.resident_size_peak / (1024.0 * 1024.0));
            result[@"processMemory"] = procVm;
        }
    }

    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];

    TVLog(@"HTTP Server: /api/hardware CPU=%@%%, RAM=%@MB/%@MB, Battery=%@%@%%, Thermal=%@, Temp=%@",
          cpu[@"usagePercentInstant"] ?: cpu[@"usagePercent"] ?: @"N/A",
          ram[@"usedMB"] ?: @"N/A",
          ram[@"totalMB"] ?: @"N/A",
          [battery[@"isCharging"] boolValue] ? @"⚡" : @"",
          battery[@"level"] ?: @"N/A",
          thermal[@"state"] ?: @"N/A",
          [temps[@"battery"] objectForKey:@"celsius"] ?: @"N/A");

    return response;
}

@end
