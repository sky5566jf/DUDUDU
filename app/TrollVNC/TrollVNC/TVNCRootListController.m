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
#import <spawn.h>
#import <signal.h>
#import <stdlib.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <string.h>
#import <dlfcn.h>

#import "StripedTextTableViewController.h"
#import "TVNCClientListController.h"
// Note: TVNCApiManager is in a different target, so we implement respring/reboot directly
#import "TVNCRootListController.h"
#import "TVNCUtil.h"
#import "ZTSelfSignedCertificate.h"

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
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

        NSString *versionString;
#ifdef THEBOOTSTRAP
        versionString = [[GitHubReleaseUpdater shared] currentVersion];
#else
        versionString = @PACKAGE_VERSION;
#endif

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

    PSSpecifier *portSpec = nil;
    PSSpecifier *httpPortSpec = nil;
    for (PSSpecifier *sp in _specifiers) {
        NSString *key = [sp propertyForKey:@"key"];
        if (!key)
            continue;
        if (!portSpec && [key isEqualToString:@"Port"])
            portSpec = sp;
        else if (!httpPortSpec && [key isEqualToString:@"HttpPort"])
            httpPortSpec = sp;
        if (portSpec && httpPortSpec)
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
    NSString *logsPath = [self.jbrootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];

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
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-cert.pem"];
}

- (NSString *)cakeyPath {
    return [self.jbrootPath
        stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.82flex.trollvnc.ca-key.pem"];
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

#pragma mark - UITableViewDataSource & UITableViewDelegate

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasManagedConfiguration]) {
        return [super tableView:tableView cellForRowAtIndexPath:indexPath];
    }

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
    if (section == 0 && ![self hasManagedConfiguration]) {
#ifdef THEBOOTSTRAP
        do {
            GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
            if (![updater hasNewerVersionInCache]) {
                break;
            }

            GHReleaseInfo *releaseInfo = [updater cachedLatestRelease];
            if (!releaseInfo) {
                break;
            }

            return [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(
                                                  @"A new version %@ is available! You’re currently using v%@. "
                                                  @"Download the latest version from Havoc Marketplace.",
                                                  @"Localizable", self.bundle, nil),
                                              releaseInfo.tagName, [[GitHubReleaseUpdater shared] currentVersion]];
        } while (0);
#endif
    }
    return [super tableView:tableView titleForFooterInSection:section];
}

#pragma mark - Helper Methods

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

#pragma mark - Respring & Reboot

// Helper: kill all processes with the given name
- (void)killall:(NSString *)processName {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return;
    }
    
    size_t count = size / sizeof(struct kinfo_proc);
    
    for (size_t i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        pid_t pid = p->kp_proc.p_pid;
        
        // 获取进程名称 (ki_name 可能为空，改用 ki_comm)
        char nameBuffer[MAXCOMLEN + 1];
        strncpy(nameBuffer, p->kp_proc.p_comm, MAXCOMLEN);
        nameBuffer[MAXCOMLEN] = '\0';
        NSString *procName = [NSString stringWithUTF8String:nameBuffer];
        
        if ([procName isEqualToString:processName]) {
            kill(pid, SIGTERM);
        }
    }
    
    free(procs);
}

- (void)respringDevice {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self killall:@"SpringBoard"];
        [self killall:@"FrontBoard"];
        [self killall:@"BackBoard"];
    });
}

// 使用 XPC 与 mmaintenanced 通信进行用户空间重启（不需要 root 权限）
- (BOOL)rebootWithXPC {
    // 动态加载 libxpc.dylib
    void *lib = dlopen("/usr/lib/system/libxpc.dylib", RTLD_LAZY);
    if (!lib) {
        return NO;
    }
    
    // 获取 xpc_connection_create_service 函数
    typedef void* (*xpc_connection_create_service_t)(const char *name);
    xpc_connection_create_service_t xpc_connection_create_service = 
        (xpc_connection_create_service_t)dlsym(lib, "xpc_connection_create_service");
    
    if (!xpc_connection_create_service) {
        dlclose(lib);
        return NO;
    }
    
    // 创建到 mmaintenanced 服务的连接
    void *conn = xpc_connection_create_service("com.apple.mmaintenanced");
    if (!conn) {
        dlclose(lib);
        return NO;
    }
    
    // 设置事件处理
    typedef void (*xpc_event_handler_t)(void *conn, void *event);
    typedef void (*xpc_connection_set_event_handler_t)(void *conn, void *handler);
    typedef void (*xpc_connection_resume_t)(void *conn);
    typedef void (*xpc_connection_send_message_with_reply_sync_t)(void *conn, void *msg);
    typedef void* (*xpc_dictionary_create_t)(const void **keys, const void **values, size_t count);
    typedef void* (*xpc_dictionary_get_value_t)(void *dict, const char *key);
    typedef int (*xpc_dictionary_get_int64_t)(void *dict, const char *key);
    
    xpc_connection_set_event_handler_t xpc_connection_set_event_handler = 
        (xpc_connection_set_event_handler_t)dlsym(lib, "xpc_connection_set_event_handler");
    xpc_connection_resume_t xpc_connection_resume = 
        (xpc_connection_resume_t)dlsym(lib, "xpc_connection_resume");
    xpc_dictionary_create_t xpc_dictionary_create = 
        (xpc_dictionary_create_t)dlsym(lib, "xpc_dictionary_create");
    xpc_dictionary_get_int64_t xpc_dictionary_get_int64 = 
        (xpc_dictionary_get_int64_t)dlsym(lib, "xpc_dictionary_get_int64");
    
    // 设置空的事件处理
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {});
    xpc_connection_resume(conn);
    
    // 构造重启命令消息 { cmd = 5 }
    const char *keys[] = {"cmd"};
    int64_t values[] = {5};
    void *dict = xpc_dictionary_create(keys, (const void **)values, 1);
    
    // 发送同步消息
    xpc_connection_send_message_with_reply_sync_t xpc_connection_send_message_with_reply_sync = 
        (xpc_connection_send_message_with_reply_sync_t)dlsym(lib, "xpc_connection_send_message_with_reply_sync");
    
    if (xpc_connection_send_message_with_reply_sync) {
        xpc_connection_send_message_with_reply_sync(conn, dict);
    }
    
    dlclose(lib);
    return YES;
}

- (void)rebootDevice {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 方法1: XPC 用户空间重启（不需要 root 权限）
        BOOL xpcResult = [self rebootWithXPC];
        
        if (xpcResult) {
            return; // XPC 重启成功
        }
        
        // 方法2: 尝试直接调用 reboot 系统调用（需要 root 权限）
        // reboot(0) 在 sys/reboot.h 中定义
        extern int reboot(int);
        reboot(0);
        
        // 方法3: 如果上面都失败，尝试 posix_spawn
        pid_t pid;
        const char *args[] = {"reboot", NULL};
        posix_spawn(&pid, "/usr/sbin/reboot", NULL, NULL, (char **)args, NULL);
    });
}

#pragma mark - AssistiveTouch Control

// Helper: run shell command
- (void)runCommand:(NSString *)command {
    pid_t pid;
    const char *args[] = {"sh", "-c", [command UTF8String], NULL};
    posix_spawn(&pid, "/bin/sh", NULL, NULL, (char **)args, NULL);
}

- (void)setAssistiveTouchEnabled:(BOOL)enabled {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *disabledPlist = @"/var/db/com.apple.xpc.launchd/disabled.plist";
        NSString *tempPlist = @"/tmp/disabled.plist";
        NSString *daemonLabel = @"com.apple.Accessibility.UIServer";
        
        // 复制 plist 到临时位置
        NSString *cpCmd = [NSString stringWithFormat:@"cp \"%@\" \"%@\"", disabledPlist, tempPlist];
        [self runCommand:cpCmd];
        
        // 读取并修改 plist
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:tempPlist];
        if (!plist) {
            plist = [NSMutableDictionary dictionary];
        }
        
        if (enabled) {
            [plist removeObjectForKey:daemonLabel];
        } else {
            plist[daemonLabel] = @YES;
        }
        
        // 写回临时文件
        [plist writeToFile:tempPlist atomically:YES];
        
        // 复制回原位置并设置正确权限
        NSString *mvCmd = [NSString stringWithFormat:@"cp \"%@\" \"%@\" && chmod 644 \"%@\" && chown root:wheel \"%@\"", 
                           tempPlist, disabledPlist, disabledPlist, disabledPlist];
        [self runCommand:mvCmd];
        
        // 清理临时文件
        NSString *rmCmd = [NSString stringWithFormat:@"rm -f \"%@\"", tempPlist];
        [self runCommand:rmCmd];
    });
}

- (void)disableAssistiveTouch {
    [self setAssistiveTouchEnabled:NO];
    // 立即重启 SpringBoard 使更改生效
    [self respringDevice];
}

- (void)enableAssistiveTouch {
    [self setAssistiveTouchEnabled:YES];
    // 立即重启 SpringBoard 使更改生效
    [self respringDevice];
}

#pragma mark - Device Info

// 获取设备名称
- (NSString *)deviceName {
    NSString *name = [[UIDevice currentDevice] name];
    if (!name || name.length == 0) {
        name = [[NSProcessInfo processInfo] hostName];
    }
    if (!name || name.length == 0) {
        name = @"iPhone";
    }
    return name;
}

// 获取系统版本
- (NSString *)systemVersion {
    return [[UIDevice currentDevice] systemVersion];
}

// 获取设备型号（友好名称）
- (NSString *)deviceModelName {
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *identifier = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    return [self friendlyModelName:identifier];
}

// 获取局域网IP
- (NSString *)localIPAddress {
    NSString *ip = TVNCGetEn0IPAddress();
    return ip ?: @"不可用";
}

// 将设备标识符转换为友好名称
- (NSString *)friendlyModelName:(NSString *)identifier {
    NSDictionary *modelMap = @{
        // iPhone
        @"iPhone1,1": @"iPhone",
        @"iPhone1,2": @"iPhone 3G",
        @"iPhone2,1": @"iPhone 3GS",
        @"iPhone3,1": @"iPhone 4",
        @"iPhone3,2": @"iPhone 4",
        @"iPhone3,3": @"iPhone 4",
        @"iPhone4,1": @"iPhone 4S",
        @"iPhone5,1": @"iPhone 5",
        @"iPhone5,2": @"iPhone 5",
        @"iPhone5,3": @"iPhone 5c",
        @"iPhone5,4": @"iPhone 5c",
        @"iPhone6,1": @"iPhone 5s",
        @"iPhone6,2": @"iPhone 5s",
        @"iPhone6,3": @"iPhone 5s",
        @"iPhone6,4": @"iPhone 5s",
        @"iPhone7,1": @"iPhone 6 Plus",
        @"iPhone7,2": @"iPhone 6",
        @"iPhone8,1": @"iPhone 6s",
        @"iPhone8,2": @"iPhone 6s Plus",
        @"iPhone8,3": @"iPhone SE (1st)",
        @"iPhone8,4": @"iPhone SE (1st)",
        @"iPhone9,1": @"iPhone 7",
        @"iPhone9,2": @"iPhone 7 Plus",
        @"iPhone9,3": @"iPhone 7",
        @"iPhone9,4": @"iPhone 7 Plus",
        @"iPhone10,1": @"iPhone 8",
        @"iPhone10,2": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X",
        @"iPhone10,4": @"iPhone 8",
        @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,6": @"iPhone X",
        @"iPhone11,2": @"iPhone XS",
        @"iPhone11,4": @"iPhone XS Max",
        @"iPhone11,6": @"iPhone XS Max",
        @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11",
        @"iPhone12,3": @"iPhone 11 Pro",
        @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone12,8": @"iPhone SE (2nd)",
        @"iPhone13,1": @"iPhone 12 mini",
        @"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro",
        @"iPhone13,4": @"iPhone 12 Pro Max",
        @"iPhone14,2": @"iPhone 13 Pro",
        @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,4": @"iPhone 13 mini",
        @"iPhone14,5": @"iPhone 13",
        @"iPhone14,6": @"iPhone SE (3rd)",
        @"iPhone14,7": @"iPhone 14",
        @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro",
        @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPhone15,4": @"iPhone 15",
        @"iPhone15,5": @"iPhone 15 Plus",
        @"iPhone16,1": @"iPhone 15 Pro",
        @"iPhone16,2": @"iPhone 15 Pro Max",
        @"iPhone17,1": @"iPhone 16 Pro",
        @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16",
        @"iPhone17,4": @"iPhone 16",
        @"iPhone17,5": @"iPhone 16 Plus",
        // iPad
        @"iPad1,1": @"iPad",
        @"iPad2,1": @"iPad 2",
        @"iPad2,2": @"iPad 2",
        @"iPad2,3": @"iPad 2",
        @"iPad2,4": @"iPad 2",
        @"iPad3,1": @"iPad (3rd)",
        @"iPad3,2": @"iPad (3rd)",
        @"iPad3,3": @"iPad (3rd)",
        @"iPad3,4": @"iPad (4th)",
        @"iPad3,5": @"iPad (4th)",
        @"iPad3,6": @"iPad (4th)",
        @"iPad4,1": @"iPad Air",
        @"iPad4,2": @"iPad Air",
        @"iPad4,3": @"iPad Air",
        @"iPad5,3": @"iPad Air 2",
        @"iPad5,4": @"iPad Air 2",
        @"iPad6,3": @"iPad Pro 9.7",
        @"iPad6,4": @"iPad Pro 9.7",
        @"iPad6,7": @"iPad Pro 12.9",
        @"iPad6,8": @"iPad Pro 12.9",
        @"iPad6,11": @"iPad (5th)",
        @"iPad6,12": @"iPad (5th)",
        @"iPad7,1": @"iPad Pro 12.9 (2nd)",
        @"iPad7,2": @"iPad Pro 12.9 (2nd)",
        @"iPad7,3": @"iPad Pro 10.5",
        @"iPad7,4": @"iPad Pro 10.5",
        @"iPad7,5": @"iPad (6th)",
        @"iPad7,6": @"iPad (6th)",
        @"iPad7,11": @"iPad (7th)",
        @"iPad7,12": @"iPad (7th)",
        @"iPad8,1": @"iPad Pro 11",
        @"iPad8,2": @"iPad Pro 11",
        @"iPad8,3": @"iPad Pro 11",
        @"iPad8,4": @"iPad Pro 11",
        @"iPad8,5": @"iPad Pro 12.9 (3rd)",
        @"iPad8,6": @"iPad Pro 12.9 (3rd)",
        @"iPad8,7": @"iPad Pro 12.9 (3rd)",
        @"iPad8,8": @"iPad Pro 12.9 (3rd)",
        @"iPad11,1": @"iPad mini (5th)",
        @"iPad11,2": @"iPad mini (5th)",
        @"iPad11,3": @"iPad Air (3rd)",
        @"iPad11,4": @"iPad Air (3rd)",
        @"iPad13,1": @"iPad Air (4th)",
        @"iPad13,2": @"iPad Air (4th)",
        @"iPad13,4": @"iPad Pro 11 (3rd)",
        @"iPad13,5": @"iPad Pro 11 (3rd)",
        @"iPad13,6": @"iPad Pro 11 (3rd)",
        @"iPad13,7": @"iPad Pro 11 (3rd)",
        @"iPad13,8": @"iPad Pro 12.9 (5th)",
        @"iPad13,9": @"iPad Pro 12.9 (5th)",
        @"iPad13,10": @"iPad Pro 12.9 (5th)",
        @"iPad13,11": @"iPad Pro 12.9 (5th)",
        @"iPad13,16": @"iPad Air (5th)",
        @"iPad13,17": @"iPad Air (5th)",
        @"iPad13,18": @"iPad (10th)",
        @"iPad13,19": @"iPad (10th)",
        @"iPad14,1": @"iPad mini (6th)",
        @"iPad14,2": @"iPad mini (6th)",
    };
    
    return modelMap[identifier] ?: identifier ?: @"Unknown";
}

// 更新设备信息到 specifiers
- (void)updateDeviceInfoSpecifiers {
    for (PSSpecifier *specifier in _specifiers) {
        NSString *specId = [specifier propertyForKey:@"id"];
        
        if ([specId isEqualToString:@"DeviceName"]) {
            [specifier setProperty:[self deviceName] forKey:@"footerText"];
        } else if ([specId isEqualToString:@"SystemVersion"]) {
            [specifier setProperty:[NSString stringWithFormat:@"iOS %@", [self systemVersion]] forKey:@"footerText"];
        } else if ([specId isEqualToString:@"DeviceModel"]) {
            [specifier setProperty:[self deviceModelName] forKey:@"footerText"];
        } else if ([specId isEqualToString:@"DeviceIP"]) {
            [specifier setProperty:[self localIPAddress] forKey:@"footerText"];
        }
    }
}

// 重写 viewWillAppear 以更新设备信息
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self updateFirstGroupAndReload:YES];
    [self updateDeviceInfoSpecifiers];
    [self reloadSpecifiers];
}

@end
