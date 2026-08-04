//  TVNCHttpServer+AppleAccount.mm
//  远程 Apple ID（App Store / iCloud 主账号）登录 / 登出 API
//
//  符号来源：iOS 13.6 (.71) 与 iOS 16.0.2 (.41) 真机运行时反射均已确认，
//  AKAppleIDAuthenticationController / AKAppleIDAuthenticationContext 的
//  authenticateWithContext:completion: / setUsername: / setPassword: /
//  setShouldPreventInteractiveAuth: / reportSignOutForAllAppleIDsWithCompletion:
//  在两端完全一致，故无需按大版本硬分支（仍保留 NSClassFromString 探测兜底）。
//
//  ⚠️ 安全红线：8182 REST 默认开放，本文件所有接口必须带 ?token= 校验，
//     否则任何人拿到设备 IP 即可远程登你的 Apple ID（含 Activation Lock 风险）。
//  ⚠️ 登出 Apple ID 会连带 iCloud / Find My / iMessage；Find My 开启时硬退
//     可能需要原密码，否则触发 Activation Lock。signout 强制要求 confirm=yes。
//
//  形态：纯后台 API，不弹界面、不 init UIApplication。

#import "TVNCHttpServer.h"
#import "TVNCHttpResponse.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <Accounts/Accounts.h>

// ── token 校验（占位默认值，部署时必须改）──────────────────────────────
// 建议用足够随机的字符串，并通过构建变量 / 配置文件注入，不要硬编码进仓库。
#ifndef TVNC_APPSTORE_API_TOKEN
#define TVNC_APPSTORE_API_TOKEN @"uhoFjAhjfuwzouWiv1ezYEVk8XTgrNglEdSaxkuM0s4"
#endif

// ── 私有 API 非正式声明（仅给编译器方法签名，运行时不链接）──────────────
@protocol TVNCAKAuthController <NSObject>
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (void)authenticateWithContext:(id)context
                      completion:(void (^)(id response, NSError *error))completion;
- (void)reportSignOutForAllAppleIDsWithCompletion:(void (^)(NSError *error))completion;
- (void)reportSignOutForAppleID:(NSString *)appleID
                        service:(NSString *)service
                     completion:(void (^)(NSError *error))completion;
@end

@protocol TVNCAKAuthContext <NSObject>
- (void)setUsername:(NSString *)username;
- (void)setPassword:(NSString *)password;            // iOS14+；iOS13 走 _setPassword: 回退（performSelector）
- (void)setShouldPreventInteractiveAuth:(BOOL)prevent;
- (void)setFirstTimeLogin:(BOOL)firstTime;
- (void)setVerificationCode:(NSString *)code;       // 2FA 验证码（部分版本存在）
@end

// ── 私有框架按需加载 ───────────────────────────────────────────────────
static void TVNCLoadAccountFramework(NSString *name) {
    NSArray *candidates = @[
        [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/var/jb/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/usr/lib/system-intentions/%@.framework/%@", name, name],
    ];
    for (NSString *p in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) {
            dlopen([p UTF8String], RTLD_LAZY | RTLD_LOCAL);
            break;
        }
    }
    dlopen([name UTF8String], RTLD_LAZY | RTLD_LOCAL); // 兜底：共享缓存
}

static BOOL TVNCCheckApiToken(NSDictionary *query) {
    NSString *t = query[@"token"];
    if (![t isKindOfClass:[NSString class]] || t.length == 0) return NO;
    return [t isEqualToString:TVNC_APPSTORE_API_TOKEN];
}

static TVNCHttpResponse *TVNCErr(NSInteger code, NSDictionary *body) {
    TVNCHttpResponse *r = [[TVNCHttpResponse alloc] init];
    r.statusCode = code;
    r.contentType = @"application/json";
    r.body = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return r;
}

// ── TEMP DIAG 4.48：反射 iOS13 私有 API 真实方法签名 ─────────────────────
static NSArray *TVNCInstanceMethods(Class cls) {
    if (!cls) return @[];
    unsigned count = 0;
    Method *m = class_copyMethodList(cls, &count);
    NSMutableArray *a = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        [a addObject:NSStringFromSelector(method_getName(m[i]))];
    free(m);
    return a;
}
static NSArray *TVNCClassMethods(Class cls) {
    if (!cls) return @[];
    return TVNCInstanceMethods(object_getClass(cls));
}
// 只保留和登录/账号相关的 selector，避免刷屏
static NSArray *TVNCFilterAuth(NSArray *names) {
    NSArray *keys = @[@"authenticat", @"apple", @"user", @"pass", @"sign", @"account",
                      @"verify", @"login", @"context", @"session", @"register", @"credential"];
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *n in names) {
        NSString *ln = [n lowercaseString];
        for (NSString *k in keys)
            if ([ln containsString:k]) { [a addObject:n]; break; }
    }
    return [a sortedArrayUsingSelector:@selector(compare:)];
}

// ── 已登录检测（公开 Accounts 框架，跨版本稳定）────────────────────────
static BOOL TVNCIsAppleIDSignedIn(void) {
    Class storeCls = NSClassFromString(@"ACAccountStore");
    if (!storeCls) return NO;
    ACAccountStore *store = [[storeCls alloc] init];
    ACAccountType *type = [store accountTypeWithAccountTypeIdentifier:@"com.apple.AppleAccount"];
    NSArray *accounts = [store accountsWithAccountType:type];
    return accounts.count > 0;
}

// ── 打开 URL（daemon 安全：优先 LSApplicationWorkspace，不依赖 UIApplication 单例）──
@protocol TVNCLSApplicationWorkspace <NSObject>
+ (id)sharedWorkspace;
+ (id)defaultWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

static BOOL TVNCOpenURL(NSURL *url) {
    if (!url) return NO;
    Class LSAW = NSClassFromString(@"LSApplicationWorkspace");
    if (LSAW) {
        id<TVNCLSApplicationWorkspace> ws = nil;
        if ([LSAW respondsToSelector:@selector(sharedWorkspace)])
            ws = [LSAW performSelector:@selector(sharedWorkspace)];
        else if ([LSAW respondsToSelector:@selector(defaultWorkspace)])
            ws = [LSAW performSelector:@selector(defaultWorkspace)];
        if (ws && [ws respondsToSelector:@selector(openURL:)]) {
            return [ws openURL:url];
        }
    }
    return NO;
}

#pragma mark - 路由处理

@implementation TVNCHttpServer (Handlers)

// ── TEMP DIAG 4.48：反射 iOS13 私有 API 真实方法签名 ──
- (TVNCHttpResponse *)handleAppleAccountProbe:(NSDictionary *)query {
    if (!TVNCCheckApiToken(query)) return TVNCErr(401, @{@"error": @"unauthorized"});
    TVNCLoadAccountFramework(@"AppleAccount");
    TVNCLoadAccountFramework(@"AuthKit");
    TVNCLoadAccountFramework(@"Accounts");
    NSArray *classes = @[@"AKAppleIDAuthenticationContext", @"AKAppleIDAuthenticationController",
                         @"AAAccountManager", @"AKAccountManager", @"AKAppleIDSession",
                         @"AKAuthenticationController"];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *cn in classes) {
        Class cls = NSClassFromString(cn);
        if (!cls) { out[cn] = @"NOT_LOADED"; continue; }
        const char *img = class_getImageName(cls);
        out[cn] = @{
            @"image": img ? [NSString stringWithUTF8String:img] : [NSNull null],
            @"class_methods(filtered)": TVNCFilterAuth(TVNCClassMethods(cls)),
            @"instance_methods(filtered)": TVNCFilterAuth(TVNCInstanceMethods(cls)),
        };
    }
    TVNCHttpResponse *r = [[TVNCHttpResponse alloc] init];
    r.statusCode = 200;
    r.contentType = @"application/json";
    r.body = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    return r;
}

- (TVNCHttpResponse *)handleAppleSignIn:(NSDictionary *)query body:(NSData *)body {
    // 1) 鉴权
    if (!TVNCCheckApiToken(query)) {
        return TVNCErr(401, @{@"status": @"error", @"reason": @"unauthorized"});
    }
    // 2) 解析 body
    NSError *jerr = nil;
    NSDictionary *p = body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:&jerr] : nil;
    NSString *account  = p[@"account"];
    NSString *password = p[@"password"];
    NSString *code     = p[@"code"];   // 可选：2FA 验证码
    NSString *appStoreId = p[@"appStoreId"];   // 可选：App Store 应用数字 ID（已登录时直接打开该商店页）
    if (![account isKindOfClass:[NSString class]] || ![password isKindOfClass:[NSString class]]
        || account.length == 0 || password.length == 0) {
        return TVNCErr(400, @{@"status": @"error", @"reason": @"missing_account_or_password"});
    }

    // 3) 若已提供 appStoreId，构建商店页 URL
    NSURL *storeURL = nil;
    if ([appStoreId isKindOfClass:[NSString class]] && appStoreId.length > 0) {
        storeURL = [NSURL URLWithString:
            [NSString stringWithFormat:@"https://apps.apple.com/cn/app/id%@", appStoreId]];
    }

    // 4) 已登录 → 直接打开商店页（若给了 appStoreId），不再重复登录
    if (TVNCIsAppleIDSignedIn()) {
        BOOL opened = storeURL ? TVNCOpenURL(storeURL) : NO;
        NSMutableDictionary *m = [@{@"status": @"already_signed_in"} mutableCopy];
        if (storeURL) {
            m[@"opened_app_store"] = @(opened);
            m[@"app_store_url"]    = [storeURL absoluteString];
        }
        return TVNCErr(200, m);
    }

    // 5) 未登录 → 加载私有框架并探测类
    TVNCLoadAccountFramework(@"AppleAccount");
    TVNCLoadAccountFramework(@"AuthKit");
    Class ctrlCls = NSClassFromString(@"AKAppleIDAuthenticationController");
    Class ctxCls  = NSClassFromString(@"AKAppleIDAuthenticationContext");
    if (!ctrlCls || !ctxCls) {
        return TVNCErr(503, @{@"status": @"error", @"reason": @"framework_unavailable"});
    }

    // 6) 异步调用 → 同步等待（用专用 run loop 保活 XPC / 网络回调）
    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("tvnc.ak.signin", DISPATCH_QUEUE_SERIAL);

    dispatch_async(q, ^{
        @autoreleasepool {
        @try {
            id<TVNCAKAuthController> ctrl = [[ctrlCls alloc] initWithIdentifier:@"com.apple.AppleAccount"];
            id<TVNCAKAuthContext>   ctx  = [[ctxCls alloc] init];
            [ctx setUsername:account];
            // 密码 setter 跨版本不一致：iOS14+ 为 setPassword:，iOS13 为下划线私有 _setPassword:
            if ([ctx respondsToSelector:@selector(setPassword:)]) {
                [ctx setPassword:password];
            } else {
                SEL setPw = NSSelectorFromString(@"_setPassword:");
                if ([ctx respondsToSelector:setPw]) {
                    [ctx performSelector:setPw withObject:password];
                }
            }
            if ([ctx respondsToSelector:@selector(setShouldPreventInteractiveAuth:)])
                [ctx setShouldPreventInteractiveAuth:YES];
            if ([ctx respondsToSelector:@selector(setFirstTimeLogin:)])
                [ctx setFirstTimeLogin:YES];
            if (code && [ctx respondsToSelector:@selector(setVerificationCode:)])
                [ctx setVerificationCode:code];

            void (^comp)(id, NSError *) = ^(id response, NSError *error) {
                if (error) {
                    NSInteger c = [error code];
                    NSString *domain = [error domain];
                    // AuthKit 2FA / 挑战：常见 error code 区间（实测后细化）
                    BOOL isChallenge = ([domain isEqualToString:@"AKAuthenticationError"] &&
                                        (c == -45054 || c == -45076 || c == -45078));
                    if (isChallenge) {
                        NSMutableDictionary *m = [@{@"status": @"challenge",
                                                    @"methods": @[@"sms", @"trusted_device"]} mutableCopy];
                        if ([error localizedDescription])
                            m[@"detail"] = [error localizedDescription];
                        result = m;
                    } else {
                        NSMutableDictionary *m = [@{@"status": @"error",
                                                   @"reason": @"auth_failed"} mutableCopy];
                        if ([error localizedDescription])
                            m[@"detail"] = [error localizedDescription];
                        m[@"domain"] = domain ?: [NSNull null];
                        m[@"code"]   = @(c);
                        // 完整描述含 userInfo（NSDebugDescription 会点名被拒的 XPC service，如 com.apple.akd）
                        NSString *fullDesc = [error description];
                        if (fullDesc) m[@"debug"] = fullDesc;
                        result = m;
                    }
                } else {
                    NSMutableDictionary *ok = [@{@"status": @"ok"} mutableCopy];
                    if (storeURL) {
                        BOOL opened = TVNCOpenURL(storeURL);
                        ok[@"opened_app_store"] = @(opened);
                        ok[@"app_store_url"]    = [storeURL absoluteString];
                    }
                    result = ok;
                }
                dispatch_semaphore_signal(sem);
            };

            [ctrl authenticateWithContext:ctx completion:comp];

            // run loop 保活，直至回调 signal
            while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC))) != 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            }
        } @catch (NSException *ex) {
            result = @{@"status": @"exception",
                       @"name": [ex name] ?: @"",
                       @"reason": [ex reason] ?: @"",
                       @"callstack": [[ex callStackSymbols] componentsJoinedByString:@"\n"]};
            dispatch_semaphore_signal(sem);
        }
        }
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!result) result = @{@"status": @"error", @"reason": @"timeout"};
    return TVNCErr(200, result);
}

- (TVNCHttpResponse *)handleAppleSignOut:(NSDictionary *)query {
    // 1) 鉴权
    if (!TVNCCheckApiToken(query)) {
        return TVNCErr(401, @{@"status": @"error", @"reason": @"unauthorized"});
    }
    // 2) 二次确认（防误触 + Activation Lock 风险）
    NSString *confirm = query[@"confirm"];
    if (![confirm isKindOfClass:[NSString class]] || ![confirm isEqualToString:@"yes"]) {
        return TVNCErr(400, @{@"status": @"error",
                              @"reason": @"confirm_required",
                              @"hint": @"append ?confirm=yes (this signs OUT the device Apple ID; Find My may require password / trigger Activation Lock)"});
    }

    // 3) 加载框架并探测
    TVNCLoadAccountFramework(@"AppleAccount");
    TVNCLoadAccountFramework(@"AuthKit");
    Class ctrlCls = NSClassFromString(@"AKAppleIDAuthenticationController");
    if (!ctrlCls) {
        return TVNCErr(503, @{@"status": @"error", @"reason": @"framework_unavailable"});
    }

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t q = dispatch_queue_create("tvnc.ak.signout", DISPATCH_QUEUE_SERIAL);

    dispatch_async(q, ^{
        @autoreleasepool {
            id<TVNCAKAuthController> ctrl = [[ctrlCls alloc] initWithIdentifier:@"com.apple.AppleAccount"];
            void (^comp)(NSError *) = ^(NSError *error) {
                if (error) {
                    result = @{@"status": @"error",
                               @"reason": @"signout_failed",
                               @"detail": [error localizedDescription] ?: [NSString stringWithFormat:@"%@:%ld", [error domain], (long)[error code]]};
                } else {
                    result = @{@"status": @"ok"};
                }
                dispatch_semaphore_signal(sem);
            };
            [ctrl reportSignOutForAllAppleIDsWithCompletion:comp];
            while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC))) != 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            }
        }
    });

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    if (!result) result = @{@"status": @"error", @"reason": @"timeout"};
    return TVNCErr(200, result);
}

@end
