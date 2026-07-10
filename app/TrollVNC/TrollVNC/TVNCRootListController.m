/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Preferences/PSSpecifier.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <notify.h>
#import <signal.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>

#import "StripedTextTableViewController.h"
#import "TVNCClientListController.h"
#import "TVNCRootListController.h"
#import "TVNCUtil.h"
#import "ZTSelfSignedCertificate.h"

#ifdef THEBOOTSTRAP
#endif

// 读取 State:/Network/Global/IPv4（及 IPv6 兜底）的网络字典，供 GetDefaultRouteInterface / TVNCGetDefaultRouter 复用
NS_INLINE NSDictionary *TVNCCopyGlobalIPDict(void) {
    static SCDynamicStoreRef (*_SCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, SCDynamicStoreCallBack,
                                                      SCDynamicStoreContext *) = NULL;
    static CFPropertyListRef (*_SCDynamicStoreCopyValue)(SCDynamicStoreRef, CFStringRef) = NULL;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle =
            dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (handle) {
            _SCDynamicStoreCreate =
                (SCDynamicStoreRef (*)(CFAllocatorRef, CFStringRef, SCDynamicStoreCallBack,
                                       SCDynamicStoreContext *))dlsym(handle, "SCDynamicStoreCreate");
            _SCDynamicStoreCopyValue =
                (CFPropertyListRef (*)(SCDynamicStoreRef, CFStringRef))dlsym(handle, "SCDynamicStoreCopyValue");
        }
    });

    if (!_SCDynamicStoreCreate || !_SCDynamicStoreCopyValue) {
        return nil;
    }

    SCDynamicStoreRef store = _SCDynamicStoreCreate(NULL, CFSTR("TVNCGlobalIP"), NULL, NULL);
    if (!store)
        return nil;

    NSDictionary *dict =
        (NSDictionary *)CFBridgingRelease(_SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4")));
    if (!dict[@"PrimaryInterface"])
        dict = (NSDictionary *)CFBridgingRelease(_SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv6")));
    CFRelease(store);

    return dict;
}

// 默认路由接口名（Wi‑Fi en0 / 以太网 enX）
NS_INLINE NSString *GetDefaultRouteInterface(void) {
    return TVNCCopyGlobalIPDict()[@"PrimaryInterface"];
}

// 默认路由的网关（Router）
NS_INLINE NSString *TVNCGetDefaultRouter(void) {
    return TVNCCopyGlobalIPDict()[@"Router"];
}

// Resolve current IPv4/IPv6 address of interface en0 (Wi‑Fi). Prefer IPv4 if available.
NS_INLINE NSString *TVNCGetEn0IPAddress(void) {
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList)
        return nil;

    NSString *defaultRouteInterface = GetDefaultRouteInterface();
    const char *defaultRouteIfName = defaultRouteInterface ? [defaultRouteInterface UTF8String] : "en0";

    NSString *ipv4 = nil;
    NSString *ipv6 = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name)
            continue;
        if (strcmp(ifa->ifa_name, defaultRouteIfName) != 0)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;

        sa_family_t fam = ifa->ifa_addr->sa_family;
        char buf[INET6_ADDRSTRLEN] = {0};
        if (fam == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                ipv4 = [NSString stringWithUTF8String:buf];
            }
        } else if (fam == AF_INET6) {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ifa->ifa_addr;
            // Skip link-local addresses (fe80::) if possible
            if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) {
                char tmp[INET6_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET6, &sin6->sin6_addr, tmp, sizeof(tmp))) {
                    // Keep as fallback only if no other IPv6 found later
                    if (!ipv6)
                        ipv6 = [NSString stringWithUTF8String:tmp];
                }
            } else {
                char tmp[INET6_ADDRSTRLEN] = {0};
                if (inet_ntop(AF_INET6, &sin6->sin6_addr, tmp, sizeof(tmp))) {
                    ipv6 = [NSString stringWithUTF8String:tmp];
                }
            }
        }
    }
    freeifaddrs(ifaList);
    return ipv4 ?: ipv6; // prefer IPv4
}

typedef struct __SCPreferences *TVNCSCPreferencesRef;

// v3.54: 确定性选择要锁定的目标网络接口，优先级：以太网(Ethernet) > Wi‑Fi。
// 以太网 + Wi‑Fi 同时在线 → 锁以太网；仅 Wi‑Fi → 锁 Wi‑Fi；仅以太网 → 锁以太网。
// 返回 @{@"interface", @"serviceID", @"type", @"ip", @"mask", @"router"}；无有效连接返回 nil。
// 巨魔版(mobile) 经 configd 读 Setup（entitlement: SCPreferences-write-access），对 tipa/deb 通用。
NS_INLINE NSDictionary *TVNCSelectPreferredNetwork(void) {
    // 1) 读 Setup:/Network/Service，建立 DeviceName -> {serviceID, type}
    static void *scHandle = NULL;
    static dispatch_once_t once;
    static TVNCSCPreferencesRef (*_SCPreferencesCreateWithOptions)(CFAllocatorRef, CFStringRef, CFStringRef,
                                                                   CFOptionFlags, CFErrorRef *) = NULL;
    static CFDictionaryRef (*_SCPreferencesPathGetValue)(TVNCSCPreferencesRef, CFStringRef) = NULL;
    dispatch_once(&once, ^{
        scHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (scHandle) {
            _SCPreferencesCreateWithOptions = dlsym(scHandle, "SCPreferencesCreateWithOptions");
            _SCPreferencesPathGetValue = dlsym(scHandle, "SCPreferencesPathGetValue");
        }
    });
    if (!_SCPreferencesCreateWithOptions || !_SCPreferencesPathGetValue)
        return nil;

    CFErrorRef createErr = NULL;
    TVNCSCPreferencesRef prefs = _SCPreferencesCreateWithOptions(
        kCFAllocatorDefault, CFSTR("TVNC-SelectNet"), CFSTR("com.apple.SystemConfiguration"), (CFOptionFlags)1,
        &createErr);
    if (!prefs) {
        if (createErr)
            CFRelease(createErr);
        return nil;
    }

    NSDictionary *setup = (__bridge NSDictionary *)_SCPreferencesPathGetValue(prefs, CFSTR("Setup:/"));
    NSDictionary *services = setup[@"Network"] ? setup[@"Network"][@"Service"] : nil;
    NSMutableDictionary *devToService = [NSMutableDictionary dictionary];
    for (NSString *sid in services) {
        NSDictionary *svc = services[sid];
        NSDictionary *iface = svc[@"Interface"];
        NSString *dev = iface ? iface[@"DeviceName"] : nil;
        NSString *type = iface ? iface[@"Type"] : nil;
        if ([dev isKindOfClass:[NSString class]]) {
            [devToService setObject:@{@"serviceID" : sid, @"type" : (type ?: @"")} forKey:dev];
        }
    }
    CFRelease(prefs);

    // 2) getifaddrs 收集所有有 IPv4 的物理接口（排除回环/链路本地/虚拟/蜂窝）
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList)
        return nil;
    NSMutableDictionary<NSString *, NSDictionary *> *ifIPv4 = [NSMutableDictionary dictionary];
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        if (ifa->ifa_addr->sa_family != AF_INET)
            continue; // v1 仅 IPv4
        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        if ([name hasPrefix:@"lo"] || [name hasPrefix:@"pdp_ip"] || [name hasPrefix:@"bridge"] ||
            [name hasPrefix:@"awdl"] || [name hasPrefix:@"llw"] || [name hasPrefix:@"utun"] ||
            [name hasPrefix:@"ipsec"] || [name hasPrefix:@"anpi"] || [name hasPrefix:@"ap"] ||
            [name hasPrefix:@"gif"] || [name hasPrefix:@"stf"] || [name hasPrefix:@"pktap"])
            continue;
        const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
        char buf[INET_ADDRSTRLEN] = {0};
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)))
            continue;
        NSString *ip = [NSString stringWithUTF8String:buf];
        if ([ip isEqualToString:@"0.0.0.0"] || [ip hasPrefix:@"169.254."])
            continue; // 排除无效/链路本地
        NSString *mask = @"";
        if (ifa->ifa_netmask) {
            const struct sockaddr_in *nm = (const struct sockaddr_in *)ifa->ifa_netmask;
            char mbuf[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &nm->sin_addr, mbuf, sizeof(mbuf)))
                mask = [NSString stringWithUTF8String:mbuf];
        }
        ifIPv4[name] = @{@"ip" : ip, @"mask" : mask};
    }
    freeifaddrs(ifaList);

    // 3) 匹配 service 类型，以太网优先，其次 Wi‑Fi
    NSString *ethIf = nil, *wifiIf = nil;
    for (NSString *dev in ifIPv4) {
        NSDictionary *svcInfo = devToService[dev];
        NSString *type = svcInfo[@"type"] ?: @"";
        BOOL isEthernet = [type rangeOfString:@"Ethernet" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL isWiFi = [type rangeOfString:@"Wi‑Fi" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [type rangeOfString:@"AirPort" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [type rangeOfString:@"WiFi" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (isEthernet && !ethIf)
            ethIf = dev;
        else if (isWiFi && !wifiIf)
            wifiIf = dev;
    }
    NSString *selIf = ethIf ?: wifiIf;
    if (!selIf)
        return nil;

    NSDictionary *addr = ifIPv4[selIf];
    NSString *ip = addr[@"ip"];
    NSString *mask = addr[@"mask"] ?: @"";

    // 4) Router：优先取该接口自身的 State IPv4，回退全局默认路由
    NSString *router = nil;
    static void *scStoreHandle = NULL;
    static dispatch_once_t onceStore;
    static SCDynamicStoreRef (*_SCDynamicStoreCreate)(CFAllocatorRef, CFStringRef, SCDynamicStoreCallBack,
                                                      SCDynamicStoreContext *) = NULL;
    static CFPropertyListRef (*_SCDynamicStoreCopyValue)(SCDynamicStoreRef, CFStringRef) = NULL;
    dispatch_once(&onceStore, ^{
        scStoreHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (scStoreHandle) {
            _SCDynamicStoreCreate =
                (SCDynamicStoreRef(*)(CFAllocatorRef, CFStringRef, SCDynamicStoreCallBack, SCDynamicStoreContext *))dlsym(
                    scStoreHandle, "SCDynamicStoreCreate");
            _SCDynamicStoreCopyValue =
                (CFPropertyListRef(*)(SCDynamicStoreRef, CFStringRef))dlsym(scStoreHandle, "SCDynamicStoreCopyValue");
        }
    });
    if (_SCDynamicStoreCreate && _SCDynamicStoreCopyValue) {
        SCDynamicStoreRef store = _SCDynamicStoreCreate(NULL, CFSTR("TVNC-SelectNet-Router"), NULL, NULL);
        if (store) {
            NSString *path = [NSString stringWithFormat:@"State:/Network/Interface/%@/IPv4", selIf];
            NSDictionary *ifDict = (__bridge NSDictionary *)_SCDynamicStoreCopyValue(store, (__bridge CFStringRef)path);
            if (ifDict[@"Router"])
                router = ifDict[@"Router"];
            CFRelease(store);
        }
    }
    if (!router)
        router = TVNCGetDefaultRouter();

    NSDictionary *svcInfo = devToService[selIf];
    return @{
        @"interface" : selIf,
        @"serviceID" : svcInfo[@"serviceID"] ?: @"",
        @"type" : svcInfo[@"type"] ?: @"",
        @"ip" : ip,
        @"mask" : mask,
        @"router" : router ?: @"",
    };
}

// v3.54 (Step 1): 只读展示用，返回 ip/mask/router。
// 优先走 TVNCSelectPreferredNetwork（需要 SCPreferences，root/daemon可通）；
// 在 App 沙盒(mobile)内 SCPreferences 被拦时，回退到 getifaddrs + SCDynamicStore（App内可通）。
NS_INLINE NSDictionary<NSString *, NSString *> *TVNCGetCurrentNetworkInfo(void) {
    NSDictionary *sel = TVNCSelectPreferredNetwork();
    if (sel)
        return @{@"ip" : sel[@"ip"], @"mask" : sel[@"mask"], @"router" : sel[@"router"]};

    // ---- 备用路径：仅依赖 getifaddrs + SCDynamicStore（无需 SCPreferences）----
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList)
        return nil;

    NSString *defaultRouteInterface = GetDefaultRouteInterface();
    const char *ifName = defaultRouteInterface ? [defaultRouteInterface UTF8String] : "en0";

    NSString *ip = nil;
    NSString *mask = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name)
            continue;
        if (strcmp(ifa->ifa_name, ifName) != 0)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;
        if (ifa->ifa_addr->sa_family != AF_INET)
            continue;

        const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
        char buf[INET_ADDRSTRLEN] = {0};
        if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)))
            ip = [NSString stringWithUTF8String:buf];
        if (ifa->ifa_netmask) {
            const struct sockaddr_in *nm = (const struct sockaddr_in *)ifa->ifa_netmask;
            char mbuf[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &nm->sin_addr, mbuf, sizeof(mbuf)))
                mask = [NSString stringWithUTF8String:mbuf];
        }
        if (ip && mask)
            break;
    }
    freeifaddrs(ifaList);

    if (!ip)
        return nil;

    NSString *router = TVNCGetDefaultRouter();
    return @{
        @"ip" : ip,
        @"mask" : (mask ?: @""),
        @"router" : (router ?: @""),
    };
}

// v3.54 (Step 2): 通过 SCPreferences API 将默认路由接口的 DHCP 配置锁定为静态（Manual）或回滚 DHCP。
// 走 API 而非直接写 plist：巨魔版(mobile) 经 configd 写入（entitlement: SCPreferences-write-access），
// API 自动抽象 /var/jb 前缀，对 tipa / default / rootless / roothide deb 通用。
// 失败返回 NO，调用方负责把开关回滚，绝不锁死用户。
NS_INLINE BOOL TVNCApplyStaticIPConfiguration(BOOL enabled, NSDictionary<NSString *, NSString *> *netInfo, NSError **outError) {
    static void *scHandle = NULL;
    static dispatch_once_t once;
    static TVNCSCPreferencesRef (*_SCPreferencesCreateWithOptions)(CFAllocatorRef, CFStringRef, CFStringRef, CFOptionFlags, CFErrorRef *) = NULL;
    static CFDictionaryRef (*_SCPreferencesPathGetValue)(TVNCSCPreferencesRef, CFStringRef) = NULL;
    static Boolean (*_SCPreferencesPathSetValue)(TVNCSCPreferencesRef, CFStringRef, CFPropertyListRef) = NULL;
    static Boolean (*_SCPreferencesCommitChanges)(TVNCSCPreferencesRef) = NULL;
    static Boolean (*_SCPreferencesApplyChanges)(TVNCSCPreferencesRef) = NULL;

    dispatch_once(&once, ^{
        scHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (scHandle) {
            _SCPreferencesCreateWithOptions = dlsym(scHandle, "SCPreferencesCreateWithOptions");
            _SCPreferencesPathGetValue = dlsym(scHandle, "SCPreferencesPathGetValue");
            _SCPreferencesPathSetValue = dlsym(scHandle, "SCPreferencesPathSetValue");
            _SCPreferencesCommitChanges = dlsym(scHandle, "SCPreferencesCommitChanges");
            _SCPreferencesApplyChanges = dlsym(scHandle, "SCPreferencesApplyChanges");
        }
    });

    if (!_SCPreferencesCreateWithOptions || !_SCPreferencesPathGetValue || !_SCPreferencesPathSetValue ||
        !_SCPreferencesCommitChanges || !_SCPreferencesApplyChanges) {
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-1 userInfo:@{NSLocalizedDescriptionKey : @"SCPreferences API 不可用"}];
        return NO;
    }

    CFErrorRef createErr = NULL;
    TVNCSCPreferencesRef prefs = _SCPreferencesCreateWithOptions(
        kCFAllocatorDefault,
        CFSTR("TrollVNC-StaticIP"),
        CFSTR("com.apple.SystemConfiguration"), // kSCPreferencesSystemApplicationID
        (CFOptionFlags)1,                         // kSCPreferencesOptionOpenStore
        &createErr);
    if (!prefs) {
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-2 userInfo:@{NSLocalizedDescriptionKey : @"无法打开系统网络配置 (SCPreferences)"}];
        if (createErr) CFRelease(createErr);
        return NO;
    }

    NSDictionary *setup = (__bridge NSDictionary *)_SCPreferencesPathGetValue(prefs, CFSTR("Setup:/"));
    NSDictionary *services = setup[@"Network"] ? setup[@"Network"][@"Service"] : nil;

    // 确定性选择目标服务：以太网优先，其次 Wi‑Fi（与读取展示共用同一逻辑，保证一致）
    NSDictionary *sel = TVNCSelectPreferredNetwork();
    NSString *matchedID = sel[@"serviceID"];
    NSDictionary *matchedSvc = (matchedID.length > 0) ? services[matchedID] : nil;
    if (!matchedSvc) {
        CFRelease(prefs);
        NSString *ifName = sel[@"interface"] ?: @"?";
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-3 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"未找到接口 %@ 对应的网络服务", ifName]}];
        return NO;
    }

    // 写前备份原 IPv4 配置到 App 沙盒，便于极端恢复参考
    @try {
        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (docDir) {
            NSString *backupPath = [docDir stringByAppendingPathComponent:@"static_ip_backup.plist"];
            NSDictionary *backup = @{ @"serviceID" : matchedID, @"ipv4" : (matchedSvc[@"IPv4"] ?: @{}) };
            [backup writeToFile:backupPath atomically:YES];
        }
    } @catch (id e) {
    }

    NSMutableDictionary *ipv4 = [matchedSvc[@"IPv4"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (enabled) {
        ipv4[@"ConfigMethod"] = @"Manual";
        ipv4[@"Addresses"] = @[ netInfo[@"ip"] ?: @"" ];
        ipv4[@"SubnetMasks"] = @[ netInfo[@"mask"] ?: @"" ];
        ipv4[@"Routers"] = @[ netInfo[@"router"] ?: @"" ];
    } else {
        ipv4[@"ConfigMethod"] = @"DHCP";
        [ipv4 removeObjectForKey:@"Addresses"];
        [ipv4 removeObjectForKey:@"SubnetMasks"];
        [ipv4 removeObjectForKey:@"Routers"];
    }

    NSString *path = [NSString stringWithFormat:@"Setup:/Network/Service/%@/IPv4", matchedID];
    Boolean setOk = _SCPreferencesPathSetValue(prefs, (__bridge CFStringRef)path, (__bridge CFPropertyListRef)ipv4);
    if (!setOk) {
        CFRelease(prefs);
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-4 userInfo:@{NSLocalizedDescriptionKey : @"写入 IPv4 配置失败"}];
        return NO;
    }
    Boolean commitOk = _SCPreferencesCommitChanges(prefs);
    if (!commitOk) {
        CFRelease(prefs);
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-5 userInfo:@{NSLocalizedDescriptionKey : @"提交网络配置失败"}];
        return NO;
    }
    Boolean applyOk = _SCPreferencesApplyChanges(prefs);
    CFRelease(prefs);
    if (!applyOk) {
        if (outError) *outError = [NSError errorWithDomain:@"TrollVNC" code:-6 userInfo:@{NSLocalizedDescriptionKey : @"应用网络配置失败"}];
        return NO;
    }
    return YES;
}

NS_INLINE BOOL TVNCIsValidBindHostLiteral(NSString *host) {
    if (!host)
        return YES;

    NSString *trimmed = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return YES; // Empty means bind any interface

    const char *cstr = trimmed.UTF8String;
    if (!cstr || cstr[0] == '\0')
        return YES;

    struct in_addr v4;
    if (inet_pton(AF_INET, cstr, &v4) == 1)
        return YES;

    // Allow optional IPv6 scope suffix (e.g. fe80::1%en0)
    char addrBuf[INET6_ADDRSTRLEN + 1] = {0};
    const char *pct = strchr(cstr, '%');
    size_t copyLen = pct ? (size_t)(pct - cstr) : strlen(cstr);
    if (copyLen >= sizeof(addrBuf))
        copyLen = sizeof(addrBuf) - 1;
    memcpy(addrBuf, cstr, copyLen);
    addrBuf[copyLen] = '\0';

    struct in6_addr v6;
    return inet_pton(AF_INET6, addrBuf, &v6) == 1;
}

@interface TVNCRootListController ()

@property(nonatomic, strong) nw_path_monitor_t monitor;

@property(nonatomic, strong) UINotificationFeedbackGenerator *notificationGenerator;
@property(nonatomic, strong) UIColor *primaryColor;
@property(nonatomic, copy) NSString *jbrootPath;

@property(nonatomic, strong) PSSpecifier *firstGroupSpecifier;
@property(nonatomic, strong) PSSpecifier *enabledSpecifier;
@property(nonatomic, strong) PSSpecifier *certSpecifier;
@property(nonatomic, strong) PSSpecifier *keysSpecifier;
@property(nonatomic, strong) PSSpecifier *exportCertSpecifier;

@property(nonatomic, copy) NSString *defaultFooterText;

@end

@implementation TVNCRootListController {
    int _notifyToken;
}

#ifdef THEBOOTSTRAP
@synthesize bundle = _bundle;

- (NSBundle *)bundle {
    if (!_bundle) {
        _bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs" ofType:@"bundle"]];
    }
    return _bundle;
}
#endif

/* clangd behavior workarounds */
#define STRINGIFY(x) #x
#define EXPAND_AND_STRINGIFY(x) STRINGIFY(x)
#define MYNSSTRINGIFY(x)                                                                                               \
    ^{                                                                                                                 \
        NSString *str = [NSString stringWithUTF8String:EXPAND_AND_STRINGIFY(x)];                                       \
        if ([str hasPrefix:@"\""])                                                                                     \
            str = [str substringFromIndex:1];                                                                          \
        if ([str hasSuffix:@"\""])                                                                                     \
            str = [str substringToIndex:str.length - 1];                                                               \
        return str;                                                                                                    \
    }()

- (BOOL)hasManagedConfiguration {
    static BOOL sIsManaged = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *presetPath = [self.bundle pathForResource:@"Managed" ofType:@"plist"];
        if (presetPath) {
            NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
            if (presetDict) {
                sIsManaged = YES;
            }
        }
    });
    return sIsManaged;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray<PSSpecifier *> *specifiers = nil;

        if (!specifiers) {
            if ([self hasManagedConfiguration]) {
                specifiers = [self loadSpecifiersFromPlistName:@"ManagedRoot" target:self];
            }
        }

        if (!specifiers) {
            specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        }

        PSSpecifier *firstGroup = [specifiers firstObject];
        _firstGroupSpecifier = firstGroup;

        for (PSSpecifier *specifier in specifiers) {
            NSString *actionName = [specifier propertyForKey:@"action"];
            if ([actionName isEqualToString:@"exportCertificate"]) {
                _exportCertSpecifier = specifier;
                break;
            }

            NSString *keyName = [specifier propertyForKey:@"key"];
            if ([keyName isEqualToString:@"SslCertFile"]) {
                _certSpecifier = specifier;
            } else if ([keyName isEqualToString:@"SslKeyFile"]) {
                _keysSpecifier = specifier;
            } else if ([keyName isEqualToString:@"Enabled"]) {
                _enabledSpecifier = specifier;
            }
        }

        _specifiers = specifiers;
        [self updateFirstGroupAndReload:NO];
    }

    return _specifiers;
}

- (void)dealloc {
    if (_monitor) {
        nw_path_monitor_cancel(_monitor);
    }
    if (_notifyToken) {
        notify_cancel(_notifyToken);
    }
}

// Add Apply button in nav bar
- (void)viewDidLoad {
    [super viewDidLoad];

    _notificationGenerator = [[UINotificationFeedbackGenerator alloc] init];
    _primaryColor = [UIColor colorWithRed:35 / 255.0 green:158 / 255.0 blue:171 / 255.0 alpha:1.0];
    [[UISwitch appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setOnTintColor:_primaryColor];
    [[UISlider appearanceWhenContainedInInstancesOfClasses:@[
        [self class],
    ]] setMinimumTrackTintColor:_primaryColor];
    [self.view setTintColor:_primaryColor];

    self.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"TrollVNC"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:nil
                                                                            action:nil];
    self.navigationItem.backBarButtonItem.tintColor = _primaryColor;

    if ([self hasManagedConfiguration]) {
        return;
    }

    UIBarButtonItem *applyItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedStringFromTableInBundle(@"Apply", @"Localizable", self.bundle, nil)
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(applyChanges)];
    applyItem.tintColor = _primaryColor;

    UIBarButtonItem *clientsItem = [[UIBarButtonItem alloc]
        initWithTitle:NSLocalizedStringFromTableInBundle(@"Clients", @"Localizable", self.bundle, nil)
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(showClients)];
    clientsItem.tintColor = _primaryColor;

#ifdef THEBOOTSTRAP
    BOOL isApp = YES;
#else
    BOOL isApp = NO;
#endif

    BOOL isPad = ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad);
    if (isApp || isPad) {
        self.navigationItem.leftBarButtonItem = clientsItem;
        self.navigationItem.rightBarButtonItem = applyItem;
    } else {
        self.navigationItem.rightBarButtonItems = @[
            applyItem,
            clientsItem,
        ];
    }

    self.monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(self.monitor, dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(self.monitor, ^(nw_path_t _Nonnull path) {
        [weakSelf updateFirstGroupAndReload:YES];
    });
    nw_path_monitor_start(self.monitor);

    notify_register_dispatch(TVNC_NOTIFY_PREFS_CHANGED, &_notifyToken, dispatch_get_main_queue(), ^(int token) {
        [weakSelf reloadEnabledSpecifier];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self updateFirstGroupAndReload:YES];
    [self updateDeviceInfoSpecifiers];
}

- (void)showClients {
    TVNCClientListController *vc = [[TVNCClientListController alloc] init];
    vc.bundle = self.bundle;
    vc.primaryColor = self.primaryColor;
    vc.notificationGenerator = self.notificationGenerator;
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:vc];
    [self.navigationController presentViewController:navController animated:YES completion:nil];
}

- (NSString *)defaultFooterText {
    if (!_defaultFooterText) {
        NSString *packageScheme = MYNSSTRINGIFY(THEOS_PACKAGE_SCHEME);
        if (!packageScheme.length) {
            packageScheme = @"legacy";
        }

        NSString *versionString = @PACKAGE_VERSION;

        NSString *footerText = [NSString
            stringWithFormat:NSLocalizedStringFromTableInBundle(@"TrollVNC (%@) v%@", @"Localizable", self.bundle, nil),
                             packageScheme, versionString];
        _defaultFooterText = footerText;
    }
    return _defaultFooterText;
}

- (NSString *)currentStatusText {
    PSSpecifier *revModeSpec = nil;
    for (PSSpecifier *sp in _specifiers) {
        NSString *key = [sp propertyForKey:@"key"];
        if (!key)
            continue;
        if (!revModeSpec && [key isEqualToString:@"ReverseMode"]) {
            revModeSpec = sp;
            break;
        }
    }

    NSString *revMode = @"none";
    id revModeVal = revModeSpec ? [self readPreferenceValue:revModeSpec] : nil;
    if ([revModeVal isKindOfClass:[NSString class]]) {
        revMode = (NSString *)revModeVal;
    }

    NSString *text;
    BOOL isRevModeOn = [revMode caseInsensitiveCompare:@"none"] != NSOrderedSame;
    if (isRevModeOn) {
        NSString *modeFormat =
            NSLocalizedStringFromTableInBundle(@"Reverse Connection: %@", @"Localizable", self.bundle, nil);
        if ([revMode caseInsensitiveCompare:@"repeater"] == NSOrderedSame) {
            revMode = NSLocalizedStringFromTableInBundle(@"Repeater", @"Localizable", self.bundle, nil);
        } else {
            revMode = NSLocalizedStringFromTableInBundle(@"Viewer", @"Localizable", self.bundle, nil);
        }
        text = [NSString stringWithFormat:modeFormat, revMode];
    } else {
        // v3.54 (Step 1): 只读展示当前网络配置（IP / 子网掩码 / 路由器）
        NSDictionary *net = TVNCGetCurrentNetworkInfo();
        NSString *unavail = NSLocalizedStringFromTableInBundle(@"unavailable", @"Localizable", self.bundle, nil);
        NSString *ip = net[@"ip"] ?: unavail;
        NSString *mask = net[@"mask"] ?: unavail;
        NSString *router = net[@"router"] ?: unavail;

        NSString *ipFmt = NSLocalizedStringFromTableInBundle(@"IP Address: %@", @"Localizable", self.bundle, nil);
        NSString *maskFmt = NSLocalizedStringFromTableInBundle(@"Subnet Mask: %@", @"Localizable", self.bundle, nil);
        NSString *routerFmt = NSLocalizedStringFromTableInBundle(@"Router: %@", @"Localizable", self.bundle, nil);

        text = [NSString stringWithFormat:@"%@\n%@\n%@",
                [NSString stringWithFormat:ipFmt, ip],
                [NSString stringWithFormat:maskFmt, mask],
                [NSString stringWithFormat:routerFmt, router]];
    }

    return text;
}

- (void)updateFirstGroupAndReload:(BOOL)reload {
    if (!_firstGroupSpecifier) {
        return;
    }

    NSString *footerText = [NSString stringWithFormat:@"%@\n%@", [self defaultFooterText], [self currentStatusText]];
    [_firstGroupSpecifier setProperty:footerText forKey:@"footerText"];

    if (reload) {
        [self reloadSpecifier:_firstGroupSpecifier animated:NO];
    }
}

- (void)reloadEnabledSpecifier {
    if (!_enabledSpecifier) {
        return;
    }

    [self reloadSpecifier:_enabledSpecifier animated:NO];
}

#pragma mark - Actions

- (void)applyChanges {
    // Resign first responder status
    [self.view endEditing:YES];

    // Validate ports before restarting service, using -readPreferenceValue: to get live edits
    int port = 5901;
    int httpPort = 0;
    NSString *bindHost = @"";

    PSSpecifier *portSpec = nil;
    PSSpecifier *httpPortSpec = nil;
    PSSpecifier *bindHostSpec = nil;
    for (PSSpecifier *sp in _specifiers) {
        NSString *key = [sp propertyForKey:@"key"];
        if (!key)
            continue;
        if (!portSpec && [key isEqualToString:@"Port"])
            portSpec = sp;
        else if (!httpPortSpec && [key isEqualToString:@"HttpPort"])
            httpPortSpec = sp;
        else if (!bindHostSpec && [key isEqualToString:@"BindHost"])
            bindHostSpec = sp;
        if (portSpec && httpPortSpec && bindHostSpec)
            break;
    }

    id portVal = portSpec ? [self readPreferenceValue:portSpec] : nil;
    if ([portVal isKindOfClass:[NSNumber class]]) {
        port = [portVal intValue];
    } else if ([portVal isKindOfClass:[NSString class]]) {
        port = [(NSString *)portVal intValue];
    }

    id httpPortVal = httpPortSpec ? [self readPreferenceValue:httpPortSpec] : nil;
    if ([httpPortVal isKindOfClass:[NSNumber class]]) {
        httpPort = [httpPortVal intValue];
    } else if ([httpPortVal isKindOfClass:[NSString class]]) {
        httpPort = [(NSString *)httpPortVal intValue];
    }

    id bindHostVal = bindHostSpec ? [self readPreferenceValue:bindHostSpec] : nil;
    if ([bindHostVal isKindOfClass:[NSString class]]) {
        bindHost = (NSString *)bindHostVal;
    }

    BOOL portInvalid = (port < 1024 || port > 65535);
    BOOL httpInvalid = (httpPort != 0 && (httpPort < 1024 || httpPort > 65535));
    if (portInvalid || httpInvalid) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Port", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"TCP/HTTP ports must be 1024..65535 (HTTP can be 0 to disable). The server will fallback to defaults.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    if (!TVNCIsValidBindHostLiteral(bindHost)) {
        NSString *t = NSLocalizedStringFromTableInBundle(@"Invalid Bind Address", @"Localizable", self.bundle, nil);
        NSString *msg = NSLocalizedStringFromTableInBundle(
            @"Bind address must be a valid IPv4/IPv6 literal, or empty to listen on all interfaces.",
            @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:t
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return; // do not restart now
    }

    NSString *title = NSLocalizedStringFromTableInBundle(@"Apply Changes", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(@"Are you sure you want to restart the VNC service?",
                                                           @"Localizable", self.bundle, nil);

    NSString *fullMessage = [NSString stringWithFormat:@"%@\n%@", message, [self currentStatusText]];
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *restart = NSLocalizedStringFromTableInBundle(@"Restart", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:fullMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:restart
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                TVNCRestartVNCService();
                                                [weakSelf.notificationGenerator
                                                    notificationOccurred:UINotificationFeedbackTypeSuccess];
                                                [weakSelf.view endEditing:YES];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)jbrootPath {
    if (!_jbrootPath) {
        NSString *rootPath = [self.bundle bundlePath];
        do {
            if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
                [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
                // Found the jailbreak root
                break;
            }
            if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
                // Found the jailbreak root (NathanLR)
                break;
            }
            if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
                // Reached the root without finding jailbreak root
                break;
            }
            rootPath = [rootPath stringByDeletingLastPathComponent];
        } while (YES);
        _jbrootPath = rootPath;
    }
    return _jbrootPath;
}

- (void)viewLogs {
#if TARGET_IPHONE_SIMULATOR
    NSString *logsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#else
    NSString *logsPath = [self.jbrootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];
#endif

    StripedTextTableViewController *logsVC = [[StripedTextTableViewController alloc] initWithPath:logsPath];
    logsVC.primaryColor = self.primaryColor;

    [logsVC setAutoReload:YES];
    [logsVC setMaximumNumberOfRows:1000];
    [logsVC setMaximumNumberOfLines:20];
    [logsVC setReversed:YES];
    [logsVC setAllowDismissal:YES];
    [logsVC setAllowMultiline:YES];
    [logsVC setAllowTrash:NO];
    [logsVC setAllowSearch:YES];
    [logsVC setAllowShare:YES];
    [logsVC setPullToReload:YES];
    [logsVC setTapToCopy:YES];
    [logsVC setPressToCopy:YES];
    [logsVC setPreserveEmptyLines:NO];
    [logsVC setRemoveDuplicates:NO];

    NSRegularExpression *rowRegex =
        [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\b"
                                                  options:0
                                                    error:nil];

    [logsVC setRowPrefixRegularExpression:rowRegex];
    [logsVC setRowSeparator:@"\r\n"];
    [logsVC setTitle:NSLocalizedStringFromTableInBundle(@"View Logs", @"Localizable", self.bundle, nil)];
    [logsVC setLocalizationBundle:self.bundle];

    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:logsVC];
    [self presentViewController:navController animated:YES completion:nil];
}

- (NSString *)cacertPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
#endif
}

- (NSString *)cakeyPath {
#if TARGET_IPHONE_SIMULATOR
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#else
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
#endif
}

- (void)exportCertificate {
    NSString *cacertPath = [self cacertPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:cacertPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Certificate Not Found", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(
            @"You need to generate a self-signed CA certificate first before exporting it.", @"Localizable",
            self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSURL *fileURL = [NSURL fileURLWithPath:cacertPath];
    if (!fileURL) {
        return;
    }

    UIActivityViewController *activityViewController =
        [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

    PSTableCell *exportCertCell = nil;
    if (_exportCertSpecifier) {
        exportCertCell = [self cachedCellForSpecifier:_exportCertSpecifier];
    }
    activityViewController.popoverPresentationController.sourceView = exportCertCell ?: self.view;

    [self presentViewController:activityViewController animated:YES completion:nil];
}

- (void)generateKeys {
    NSString *cakeyPath = [self cakeyPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:cakeyPath]) {
        NSString *title =
            NSLocalizedStringFromTableInBundle(@"Overwrite Existing Keys", @"Localizable", self.bundle, nil);
        NSString *message =
            NSLocalizedStringFromTableInBundle(@"A CA private key already exists. Generating new keys will overwrite "
                                               @"the existing ones. Are you sure you want to continue?",
                                               @"Localizable", self.bundle, nil);
        NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
        NSString *generate = NSLocalizedStringFromTableInBundle(@"Overwrite", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:generate
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf _reallyGenerateKeys];
                                                }]];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(
                                                            @"Export Certificate…", @"Localizable", self.bundle, nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_Nonnull action) {
                                                    [weakSelf exportCertificate];
                                                }]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [self _reallyGenerateKeys];
}

- (void)_reallyGenerateKeys {
    NSString *randomUUID = [[[NSUUID UUID] UUIDString] substringFromIndex:28];
    NSString *commonName = [NSString stringWithFormat:@"TrollVNC %@", randomUUID];

    ZTSelfSignedCertificate *ca = [ZTSelfSignedCertificate generateWithCommonName:commonName];
    if (!ca) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message = NSLocalizedStringFromTableInBundle(@"Failed to generate self-signed CA certificate.",
                                                               @"Localizable", self.bundle, nil);
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    BOOL succeed = YES;
    NSError *error = nil;
    do {
        NSString *cacertPath = [self cacertPath];
        succeed = [ca.certificatePEM writeToFile:cacertPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cacertPath
                                                          error:&error];
        if (!succeed) {
            break;
        }

        NSString *cakeyPath = [self cakeyPath];
        succeed = [ca.privateKeyPEM writeToFile:cakeyPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!succeed) {
            break;
        }

        succeed = [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600}
                                                   ofItemAtPath:cakeyPath
                                                          error:&error];
        if (!succeed) {
            break;
        }
    } while (0);

    if (!succeed) {
        NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Failed", @"Localizable", self.bundle, nil);
        NSString *message =
            [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(@"Failed to save generated keys: %@",
                                                                          @"Localizable", self.bundle, nil),
                                       error.localizedDescription];
        NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [super setPreferenceValue:[self cacertPath] specifier:[self certSpecifier]];
    [super setPreferenceValue:[self cakeyPath] specifier:[self keysSpecifier]];

    [self reloadSpecifiers];

    NSString *title = NSLocalizedStringFromTableInBundle(@"Generation Succeeded", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"The self-signed CA certificate and private key have been successfully generated. You need to trust this "
        @"certificate in your client browser or operating system. Restart the service to apply the changes.",
        @"Localizable", self.bundle, nil);
    NSString *ok = NSLocalizedStringFromTableInBundle(@"OK", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:ok style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Export Certificate…",
                                                                                       @"Localizable", self.bundle, nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [self exportCertificate];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetDefaults {
    NSString *title = NSLocalizedStringFromTableInBundle(@"Reset to Defaults", @"Localizable", self.bundle, nil);
    NSString *message = NSLocalizedStringFromTableInBundle(
        @"Are you sure you want to reset all settings to their defaults?", @"Localizable", self.bundle, nil);
    NSString *cancel = NSLocalizedStringFromTableInBundle(@"Cancel", @"Localizable", self.bundle, nil);
    NSString *reset = NSLocalizedStringFromTableInBundle(@"Reset", @"Localizable", self.bundle, nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:reset
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                [weakSelf _reallyResetDefaults];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyResetDefaults {
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:@"com.82flex.trollvnc"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self reloadSpecifiers];
}

- (void)support {
    NSURL *url = [NSURL URLWithString:@"https://havoc.app/search/82Flex"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)source {
    NSURL *url = [NSURL URLWithString:@"https://github.com/OwnGoalStudio/TrollVNC"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark - Logout / Restart Device Actions

- (void)respringDevice:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认注销"
                                                                   message:@"确定要注销设备吗？这将关闭所有应用并返回锁屏界面。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancel  = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认注销"
                                                     style:UIAlertActionStyleDestructive
                                                   handler:^(UIAlertAction *a) {
        [self _reallyLogoutDevice];
    }];
    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyLogoutDevice {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[MatisuXCS] Logging out device...");
        int result = [self runAsRoot:@"sbreload"];
        NSLog(@"[MatisuXCS] sbreload returned: %d", result);
        if (result == 0) return;
        [self _killall:@"SpringBoard"];
        notify_post("com.apple.springboard.rebootRequested");
        NSLog(@"[MatisuXCS] All logout methods attempted");
    });
}

- (void)restartDevice:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认重启"
                                                                   message:@"确定要重启设备吗？所有未保存的数据将丢失。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancel  = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确认重启"
                                                     style:UIAlertActionStyleDestructive
                                                   handler:^(UIAlertAction *a) {
        [self _reallyRestartDevice];
    }];
    [alert addAction:cancel];
    [alert addAction:confirm];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_reallyRestartDevice {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[MatisuXCS] Rebooting device...");

        // 方法1: FBSSystemService reboot (需要 com.apple.frontboard.shutdown 权限)
        @try {
            Class FBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
            if (FBSSystemServiceClass) {
                id fbsService = [FBSSystemServiceClass performSelector:@selector(sharedService)];
                if (fbsService && [fbsService respondsToSelector:@selector(reboot)]) {
                    NSLog(@"[MatisuXCS] Trying FBSSystemService reboot...");
                    [fbsService performSelector:@selector(reboot)];
                    [NSThread sleepForTimeInterval:3.0];
                    NSLog(@"[MatisuXCS] FBSSystemService reboot did not terminate in 3s, trying fallbacks...");
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[MatisuXCS] FBSSystemService exception: %@", e);
        }

        // 方法2: XPC 调用 mmaintenanced
        BOOL xpcResult = [self rebootWithXPC];
        NSLog(@"[MatisuXCS] XPC reboot returned: %d", xpcResult);
        [NSThread sleepForTimeInterval:1.0];

        // 方法3: posix_spawn /sbin/reboot (绝对路径)
        int result = [self runAsRoot:@"/sbin/reboot"];
        NSLog(@"[MatisuXCS] /sbin/reboot via persona_np returned: %d", result);
        if (result == 0) {
            [NSThread sleepForTimeInterval:3.0];
        }

        // 方法4: notify_post 触发重启
        notify_post("com.apple.system.powermanagement.rebootRequested");
        notify_post("com.apple.shutdown.reboot");
        NSLog(@"[MatisuXCS] All reboot methods attempted");
    });
}

#pragma mark - Killall Helper

- (void)_killall:(NSString *)processName {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) { free(procs); return; }
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        char buf[MAXCOMLEN + 1];
        strncpy(buf, procs[i].kp_proc.p_comm, MAXCOMLEN);
        buf[MAXCOMLEN] = '\0';
        if (strcmp(buf, processName.UTF8String) == 0) {
            kill(procs[i].kp_proc.p_pid, SIGKILL);
        }
    }
    free(procs);
}

#pragma mark - Reboot via XPC

- (BOOL)rebootWithXPC {
    void *lib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
    if (!lib) return NO;
    typedef void* (*xpc_conn_create_t)(const char *, dispatch_queue_t, uint64_t);
    typedef void  (*xpc_conn_set_handler_t)(void *, void *);
    typedef void  (*xpc_conn_resume_t)(void *);
    typedef void* (*xpc_dict_create_t)(const void * const *, const void * const *, size_t);
    typedef void  (*xpc_dict_set_i64_t)(void *, const char *, int64_t);
    typedef void  (*xpc_conn_send_t)(void *, void *);
    xpc_conn_create_t   fn_create   = (xpc_conn_create_t)  dlsym(lib, "xpc_connection_create_mach_service");
    xpc_conn_set_handler_t fn_hdl   = (xpc_conn_set_handler_t)dlsym(lib, "xpc_connection_set_event_handler");
    xpc_conn_resume_t   fn_resume   = (xpc_conn_resume_t)   dlsym(lib, "xpc_connection_resume");
    xpc_dict_create_t   fn_dict     = (xpc_dict_create_t)   dlsym(lib, "xpc_dictionary_create");
    xpc_dict_set_i64_t  fn_set_i64  = (xpc_dict_set_i64_t)  dlsym(lib, "xpc_dictionary_set_int64");
    xpc_conn_send_t     fn_send     = (xpc_conn_send_t)     dlsym(lib, "xpc_connection_send_message_with_reply_sync");
    if (!fn_create || !fn_dict || !fn_set_i64) { dlclose(lib); return NO; }
    void *conn = fn_create("com.apple.mmaintenanced", NULL, 0);
    if (!conn) { dlclose(lib); return NO; }
    fn_hdl(conn, (__bridge_retained void *)^(void *e) {});
    fn_resume(conn);
    void *dict = fn_dict(NULL, NULL, 0);
    fn_set_i64(dict, "cmd", 5);
    if (fn_send) fn_send(conn, dict);
    dlclose(lib);
    return YES;
}

#pragma mark - Run Command As Root via posix_spawn + persona_np

- (int)runAsRoot:(NSString *)command {
    pid_t pid;
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) return err;
    typedef int (*set_persona_np_t)(posix_spawnattr_t *, uint32_t, uint32_t);
    typedef int (*set_uid_np_t)(posix_spawnattr_t *, uid_t);
    typedef int (*set_gid_np_t)(posix_spawnattr_t *, gid_t);
    set_persona_np_t fn_persona = (set_persona_np_t)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    set_uid_np_t     fn_uid     = (set_uid_np_t)    dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    set_gid_np_t     fn_gid     = (set_gid_np_t)    dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (fn_persona) { err = fn_persona(&attr, 99, 1); if (err) { posix_spawnattr_destroy(&attr); return err; } }
    if (fn_uid)     { err = fn_uid(&attr, 0);         if (err) { posix_spawnattr_destroy(&attr); return err; } }
    if (fn_gid)     { err = fn_gid(&attr, 0);         if (err) { posix_spawnattr_destroy(&attr); return err; } }
    const char *cmdPath = command.UTF8String;
    const char *argv[] = { cmdPath, NULL };
    char *envp[] = { NULL };
    err = posix_spawn(&pid, cmdPath, NULL, &attr, (char *const *)argv, envp);
    posix_spawnattr_destroy(&attr);
    return err;
}

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];

    if ([key isEqualToString:@"PSButtonCell"]) {
        UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];

        BOOL isDestructive =
            ([specifier propertyForKey:@"isDestructive"] && [[specifier propertyForKey:@"isDestructive"] boolValue]);
        cell.textLabel.textColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        cell.textLabel.highlightedTextColor = isDestructive ? [UIColor systemRedColor] : self.primaryColor;
        return cell;
    }

    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSString *key = [specifier propertyForKey:@"cell"];
    if ([key isEqualToString:@"PSSliderCell"]) {
        // Find any UILabel in the cell's content view recursively
        UILabel *label = [self findLabelInView:cell.contentView];
        if (label) {
            // Do something with the label
            [label sizeToFit];
        }
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [super tableView:tableView titleForFooterInSection:section];
}

#pragma mark - Helper Methods

#pragma mark - Device Info Getters

- (NSString *)appVersionValue {
    return [NSString stringWithFormat:@"v%@", @PACKAGE_VERSION];
}

- (NSString *)deviceNameValue {
    // v3.43: 与服务端 tvncGetRealDeviceName 保持一致，修复 iOS 16+ 主界面（App 沙盒上下文）返回 "iPhone" 的问题
    // iOS 16+ App 沙盒中 UIDevice name 返回泛化 "iPhone"（隐私保护），依次尝试多路兜底：
    // UIDevice name → MGCopyAnswer → MobileGestalt cache plist → preferences.plist → sysctl hostname → "iPhone"
    NSString *uidName = [[UIDevice currentDevice] name];

    // 1. UIDevice 返回非泛化 "iPhone" 直接用
    if (uidName && uidName.length > 0 && ![uidName isEqualToString:@"iPhone"]) {
        return uidName;
    }

    // 2. MGCopyAnswer("DeviceName") 私有 API
    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (mg) {
        CFStringRef (*MGCopyAnswerPtr)(CFStringRef) = (CFStringRef (*)(CFStringRef))dlsym(mg, "MGCopyAnswer");
        if (MGCopyAnswerPtr) {
            CFStringRef mgName = MGCopyAnswerPtr(CFSTR("DeviceName"));
            if (mgName) {
                NSString *result = [(__bridge_transfer NSString *)mgName
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (result.length > 0 && ![result isEqualToString:@"iPhone"]) {
                    return result;
                }
            }
        }
    }

    // 3. 读 MobileGestalt cache plist（纯文件读取，不需要 entitlement）—— 这是 iOS 16+ 主界面拿真名的关键兜底
    NSMutableArray *mgCachePaths = [NSMutableArray array];
    if (access("/var/jb", F_OK) == 0) {
        [mgCachePaths addObject:@"/var/jb/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"];
    }
    [mgCachePaths addObject:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"];
    for (NSString *mgPath in mgCachePaths) {
        NSDictionary *mgCache = [NSDictionary dictionaryWithContentsOfFile:mgPath];
        NSDictionary *cacheExtra = mgCache[@"CacheExtra"];
        NSString *devName = cacheExtra[@"DeviceName"];
        if ([devName isKindOfClass:[NSString class]] && devName.length > 0 && ![devName isEqualToString:@"iPhone"]) {
            return devName;
        }
    }

    // 4. 读 SystemConfiguration preferences.plist 的 DeviceName
    NSMutableArray *plistPaths = [NSMutableArray array];
    if (access("/var/jb", F_OK) == 0) {
        [plistPaths addObject:@"/var/jb/var/mobile/Library/Preferences/SystemConfiguration/preferences.plist"];
        [plistPaths addObject:@"/var/jb/var/preferences/SystemConfiguration/preferences.plist"];
    }
    [plistPaths addObject:@"/var/mobile/Library/Preferences/SystemConfiguration/preferences.plist"];
    [plistPaths addObject:@"/var/preferences/SystemConfiguration/preferences.plist"];
    for (NSString *plistPath in plistPaths) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *devName = prefs[@"Controller"][@"DeviceName"];
        if (devName && devName.length > 0 && ![devName isEqualToString:@"iPhone"]) {
            return devName;
        }
    }

    // 5. sysctl kern.hostname（iOS 上 hostname 通常由设备名派生）
    char hostname[256] = {0};
    size_t hsize = sizeof(hostname);
    if (sysctlbyname("kern.hostname", hostname, &hsize, NULL, 0) == 0) {
        NSString *hn = [[NSString stringWithUTF8String:hostname]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hn.length > 0 && ![hn isEqualToString:@"iPhone"] && ![hn isEqualToString:@"localhost"]) {
            return hn;
        }
    }

    // 6. 兜底
    if (uidName && uidName.length > 0) return uidName;
    NSString *procHostname = [[NSProcessInfo processInfo] hostName];
    if (procHostname && procHostname.length > 0) return procHostname;

    return @"iPhone";
}

- (NSString *)systemVersionValue {
    return [NSString stringWithFormat:@"iOS %@", [[UIDevice currentDevice] systemVersion]];
}

- (NSString *)deviceModelValue {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *identifier = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    NSDictionary *modelMap = @{
        @"iPhone7,1": @"iPhone 6 Plus", @"iPhone7,2": @"iPhone 6",
        @"iPhone8,1": @"iPhone 6s", @"iPhone8,2": @"iPhone 6s Plus",
        @"iPhone8,4": @"iPhone SE (1st)", @"iPhone9,1": @"iPhone 7",
        @"iPhone9,2": @"iPhone 7 Plus", @"iPhone9,3": @"iPhone 7",
        @"iPhone9,4": @"iPhone 7 Plus", @"iPhone10,1": @"iPhone 8",
        @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,3": @"iPhone X",
        @"iPhone10,4": @"iPhone 8", @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,6": @"iPhone X", @"iPhone11,2": @"iPhone XS",
        @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max",
        @"iPhone11,8": @"iPhone XR", @"iPhone12,1": @"iPhone 11",
        @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone12,8": @"iPhone SE (2nd)", @"iPhone13,1": @"iPhone 12 mini",
        @"iPhone13,2": @"iPhone 12", @"iPhone13,3": @"iPhone 12 Pro",
        @"iPhone13,4": @"iPhone 12 Pro Max", @"iPhone14,2": @"iPhone 13 Pro",
        @"iPhone14,3": @"iPhone 13 Pro Max", @"iPhone14,4": @"iPhone 13 mini",
        @"iPhone14,5": @"iPhone 13", @"iPhone14,6": @"iPhone SE (3rd)",
        @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPhone15,4": @"iPhone 15", @"iPhone15,5": @"iPhone 15 Plus",
        @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
        @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16", @"iPhone17,4": @"iPhone 16 Plus",
    };
    return modelMap[identifier] ?: identifier;
}

- (NSString *)deviceIPValue {
    NSString *ip = TVNCGetEn0IPAddress();
    return ip ?: @"不可用";
}

- (NSString *)storageSpaceValue {
    NSString *storagePath = @"/var/mobile";
    if (access(storagePath.UTF8String, F_OK) != 0) storagePath = NSHomeDirectory();
    NSDictionary *fsAttrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:storagePath error:nil];
    if (!fsAttrs) return @"无法获取";
    double totalGB = [fsAttrs[NSFileSystemSize] unsignedLongLongValue] / (1024.0 * 1024.0 * 1024.0);
    double freeGB  = [fsAttrs[NSFileSystemFreeSize] unsignedLongLongValue] / (1024.0 * 1024.0 * 1024.0);
    return [NSString stringWithFormat:@"总 %.1f GB / 可用 %.1f GB", totalGB, freeGB];
}

- (void)updateDeviceInfoSpecifiers {
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSSet *deviceInfoIds = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            deviceInfoIds = [NSSet setWithObjects:
                @"DeviceName", @"SystemVersion",
                @"DeviceModel", @"StorageSpace", nil];
        });
        for (PSSpecifier *specifier in self->_specifiers) {
            NSString *specId = [specifier propertyForKey:@"id"];
            if ([deviceInfoIds containsObject:specId]) {
                [self reloadSpecifier:specifier animated:NO];
            }
        }
    });
}

- (UILabel *)findLabelInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            return (UILabel *)subview;
        }
        UILabel *label = [self findLabelInView:subview];
        if (label) {
            return label;
        }
    }
    return nil;
}

#pragma mark - 静态 IP（DHCP → Manual）

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"StaticIPEnabled"]) {
        [self tvnc_handleStaticIPToggle:[value boolValue] specifier:specifier];
    }
}

- (void)tvnc_handleStaticIPToggle:(BOOL)enabled specifier:(PSSpecifier *)specifier {
    NSDictionary *net = TVNCGetCurrentNetworkInfo();
    if (enabled && !net) {
        [self tvnc_revertStaticIPSwitch:specifier];
        [self tvnc_showAlertWithTitle:@"无法锁定静态 IP"
                               message:@"当前没有有效的 IP 地址（Wi-Fi / 以太网未连接或未获取到 DHCP 租约）。请连接网络后重试。"];
        return;
    }

    // 方案A: 由 daemon(root) 代理写入 SCPreferences
    // 默认HTTP端口5801；如果可能从NSUserDefaults读取（兼容用户自定义端口）
    NSString *httpPort = @"8182";
    NSString *configPort = [[NSUserDefaults standardUserDefaults] stringForKey:@"HttpPort"];
    if (configPort.length && configPort.intValue > 0) httpPort = configPort;
    NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:%@/api/network/static_ip", httpPort];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"enabled"] = @(enabled);
    if (net) {
        body[@"ip"] = net[@"ip"] ?: @"";
        body[@"mask"] = net[@"mask"] ?: @"";
        body[@"router"] = net[@"router"] ?: @"";
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;

    PSSpecifier *capturedSpecifier = specifier;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *taskError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (taskError) {
                [strongSelf tvnc_revertStaticIPSwitch:capturedSpecifier];
                [strongSelf tvnc_showAlertWithTitle:(enabled ? @"锁定失败" : @"恢复失败")
                                             message:[NSString stringWithFormat:@"无法连接本地服务\n%@\n\n请确认：\n① VNC服务端口 %@ 已开启\n② HTTP(noVNC)端口未设为0", urlStr, httpPort]];
                return;
            }

            NSInteger statusCode = [(NSHTTPURLResponse *)resp statusCode];
            NSDictionary *res = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

            if (statusCode == 200 && [res[@"success"] boolValue]) {
                if (enabled) {
                    [strongSelf tvnc_showAlertWithTitle:@"已锁定为静态 IP"
                                                 message:[NSString stringWithFormat:@"IP: %@\n子网: %@\n路由器: %@",
                                                          net[@"ip"], net[@"mask"], net[@"router"]]];
                } else {
                    [strongSelf tvnc_showAlertWithTitle:@"已恢复自动 DHCP"
                                                 message:@"网络接口已切换回自动获取 IP 地址。"];
                }
                [strongSelf updateFirstGroupAndReload:YES];
            } else {
                [strongSelf tvnc_revertStaticIPSwitch:capturedSpecifier];
                NSString *errMsg = res[@"error"] ?: @"写入网络配置失败";
                [strongSelf tvnc_showAlertWithTitle:(enabled ? @"锁定失败" : @"恢复失败")
                                             message:errMsg];
            }
        });
    }];
    [task resume];
}

- (void)tvnc_revertStaticIPSwitch:(PSSpecifier *)specifier {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"StaticIPEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if ([self respondsToSelector:@selector(reloadSpecifier:animated:)]) {
        [self reloadSpecifier:specifier animated:NO];
    } else if ([self respondsToSelector:@selector(reloadSpecifiers)]) {
        [self reloadSpecifiers];
    }
}

- (void)tvnc_showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
