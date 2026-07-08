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

#import "StripedTextTableViewController.h"
#import "TVNCClientListController.h"
#import "TVNCRootListController.h"
#import "TVNCUtil.h"
#import "ZTSelfSignedCertificate.h"

#ifdef THEBOOTSTRAP
#endif

NS_INLINE NSString *GetDefaultRouteInterface(void) {
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

    SCDynamicStoreRef store = _SCDynamicStoreCreate(NULL, CFSTR("RouteInfo"), NULL, NULL);
    if (!store)
        return nil;

    NSDictionary *dict =
        (NSDictionary *)CFBridgingRelease(_SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4")));
    if (!dict[@"PrimaryInterface"])
        dict = (NSDictionary *)CFBridgingRelease(_SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv6")));
    CFRelease(store);

    return dict[@"PrimaryInterface"];
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

// ─── 崩溃日志自动保存 ───
// 保存路径: /var/mobile/Media/xcs/TrollVNC_crash_log.txt (单文件覆盖)
static void TVNCCrashWriteToFile(NSString *log) {
    // Save to /var/mobile/Media/xcs/ (create directory if missing)
    NSString *crashDir = @"/var/mobile/Media/xcs";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:crashDir]) {
        [fm createDirectoryAtPath:crashDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // Single file, overwrite each time
    NSString *path = [crashDir stringByAppendingPathComponent:@"TrollVNC_crash_log.txt"];
    [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    NSLog(@"[TrollVNC CrashLog] saved to: %@", path);
}

static void TVNCCrashHandleSignal(int sig) {
    // 先恢复默认 handler，避免递归
    signal(sig, SIG_DFL);
    
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"=== TrollVNC Crash Log ===\n"];
    [log appendFormat:@"Time: %@\n", [NSDate date]];
    [log appendFormat:@"Signal: %d (%s)\n", sig, strsignal(sig)];
    
    // 设备信息
    UIDevice *dev = [UIDevice currentDevice];
    [log appendFormat:@"Device: %@\n", dev.name];
    [log appendFormat:@"System: %@ %@\n", dev.systemName, dev.systemVersion];
    [log appendFormat:@"Model: %@\n", dev.model];
    [log appendFormat:@"App Version: 3.35\n"];

    // 调用栈
    [log appendString:@"\nCall Stack:\n"];
    NSArray *symbols = [NSThread callStackSymbols];
    for (NSString *s in symbols) {
        [log appendFormat:@"  %@\n", s];
    }
    [log appendString:@"\n"];
    
    TVNCCrashWriteToFile(log);
    
    // 让进程退出（触发系统生成 .crash 文件）
    kill(getpid(), sig);
}

static void TVNCCrashHandleException(NSException *exception) {
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"=== TrollVNC Crash Log ===\n"];
    [log appendFormat:@"Time: %@\n", [NSDate date]];
    [log appendFormat:@"Exception: %@\n", exception.name];
    [log appendFormat:@"Reason: %@\n", exception.reason];
    
    UIDevice *dev = [UIDevice currentDevice];
    [log appendFormat:@"Device: %@\n", dev.name];
    [log appendFormat:@"System: %@ %@\n", dev.systemName, dev.systemVersion];
    [log appendFormat:@"Model: %@\n", dev.model];
    [log appendFormat:@"App Version: 3.35\n"];

    [log appendString:@"\nCall Stack:\n"];
    NSArray *symbols = exception.callStackSymbols;
    if (symbols) {
        for (NSString *s in symbols) {
            [log appendFormat:@"  %@\n", s];
        }
    } else {
        for (NSString *s in [NSThread callStackSymbols]) {
            [log appendFormat:@"  %@\n", s];
        }
    }
    [log appendString:@"\n"];
    
    TVNCCrashWriteToFile(log);
}

@implementation TVNCRootListController {
    int _notifyToken;
}

+ (void)setupCrashLogger {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // ObjC 异常捕获
        NSSetUncaughtExceptionHandler(&TVNCCrashHandleException);

        // POSIX 信号捕获
        int signals[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
        for (int i = 0; i < sizeof(signals)/sizeof(signals[0]); i++) {
            signal(signals[i], TVNCCrashHandleSignal);
        }

        // 尝试 SIGPIPE（避免写入坏管道崩溃）
        signal(SIGPIPE, SIG_IGN);

        NSLog(@"[TrollVNC] Crash logger initialized. Logs at /var/mobile/Media/xcs/TrollVNC_crash_log.txt");
    });
}

+ (void)load {
    [self setupCrashLogger];
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
        // Append current en0 IP on a second line, if available
        NSString *ip = TVNCGetEn0IPAddress();
        NSString *ipUnavailable = NSLocalizedStringFromTableInBundle(@"unavailable", @"Localizable", self.bundle, nil);
        NSString *ipFormat =
            NSLocalizedStringFromTableInBundle(@"Current IP Address: %@", @"Localizable", self.bundle, nil);
        text = [NSString stringWithFormat:ipFormat, (ip.length ? ip : ipUnavailable)];
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
    NSString *name = [[UIDevice currentDevice] name];
    if (!name || name.length == 0) name = [[NSProcessInfo processInfo] hostName];
    if (!name || name.length == 0) name = @"iPhone";
    return name;
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

@end
