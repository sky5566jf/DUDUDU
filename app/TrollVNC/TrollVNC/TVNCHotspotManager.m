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

#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"
#import <NetworkExtension/NetworkExtension.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <UIKit/UIKit.h>
#ifdef THEBOOTSTRAP
#import <objc/message.h>
#endif

// Phantom WiFi SSID used to ensure iOS always scans for WiFi after reboot,
// which triggers NEHotspotHelper and wakes the app for auto-start.
static NSString *const kPhantomSSID = @"MatisuXCS-AutoStart-Trigger";
static NSString *const kPhantomPassword = @"MatisuXCS2025Trigger";

@interface TVNCHotspotManager ()
@property (nonatomic, assign) SCNetworkReachabilityRef reachability;
@property (nonatomic, assign) BOOL lastNetworkState;
@property (nonatomic, assign) BOOL lastPhantomWiFiState;
@end

@implementation TVNCHotspotManager

+ (instancetype)sharedManager {
    static TVNCHotspotManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lastNetworkState = NO;
    }
    return self;
}

- (BOOL)registerWithName:(NSString *)name {
    // Register NEHotspotHelper for WiFi events
    NSDictionary *options = @{kNEHotspotHelperOptionDisplayName: name};
    __weak typeof(self) weakSelf = self;
    BOOL result = [NEHotspotHelper registerWithOptions:options queue:dispatch_get_main_queue() handler:^(NEHotspotHelperCommand * _Nonnull cmd) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf handleCommand:cmd];
    }];
    
    // Also start Ethernet reachability monitor
    [self startNetworkReachabilityMonitor];
    
    // v3.50: Observe the "虚拟 WiFi 自启" toggle so it takes effect immediately without relaunch
    _lastPhantomWiFiState = [self isPhantomWiFiEnabled];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(phantomWiFiPreferenceChanged:)
                                                 name:NSUserDefaultsDidChangeNotification
                                               object:nil];
    
    // v3.50: Save a phantom WiFi configuration so iOS always scans for WiFi after reboot,
    // which triggers NEHotspotHelper and wakes the app (even in Ethernet-only environments).
    // Only when the user enables the toggle. Deferred + exception-safe so it can never
    // block or crash app launch.
    if (_lastPhantomWiFiState) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                [self savePhantomWiFiConfiguration];
            } @catch (NSException *e) {
                NSLog(@"[TVNC] Phantom WiFi save failed with exception: %@", e);
            }
        });
    }
    
    return result;
}

- (void)startNetworkReachabilityMonitor {
    // Monitor ANY network connection (WiFi, Ethernet, Cellular)
    // This fixes the issue where Ethernet-only connections don't trigger NEHotspotHelper
    struct sockaddr_in zeroAddress;
    memset(&zeroAddress, 0, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    self.reachability = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zeroAddress);
    
    if (self.reachability) {
        SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
        SCNetworkReachabilitySetCallback(self.reachability, ReachabilityCallback, &context);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, dispatch_get_main_queue());
        
        // Check initial state
        SCNetworkReachabilityFlags flags;
        if (SCNetworkReachabilityGetFlags(self.reachability, &flags)) {
            BOOL initialConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
            if (initialConnected) {
                NSLog(@"[TVNC] Network: initial state = connected (Ethernet/WiFi)");
                [self executeAutoStartupTaskIfNecessary];
            }
        }
        
        NSLog(@"[TVNC] Network: reachability monitor started");
    }
}

static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    TVNCHotspotManager *manager = (__bridge TVNCHotspotManager *)info;
    
    BOOL isConnected = (flags & kSCNetworkReachabilityFlagsReachable) != 0;
    BOOL wasConnected = manager.lastNetworkState;
    manager.lastNetworkState = isConnected;
    
    NSLog(@"[TVNC] Network: reachability changed, connected=%d (was=%d)", isConnected, wasConnected);
    
    if (isConnected && !wasConnected) {
        // Network just became available (WiFi or Ethernet)
        NSLog(@"[TVNC] Network: connection detected, triggering service startup");
        [manager executeAutoStartupTaskIfNecessary];
    }
}

- (void)handleCommand:(NEHotspotHelperCommand *)command {
    switch (command.commandType) {
        case kNEHotspotHelperCommandTypeNone:
            break;
        case kNEHotspotHelperCommandTypeFilterScanList:
        case kNEHotspotHelperCommandTypeEvaluate:
        case kNEHotspotHelperCommandTypeAuthenticate:
        case kNEHotspotHelperCommandTypePresentUI:
        case kNEHotspotHelperCommandTypeMaintain:
        case kNEHotspotHelperCommandTypeLogoff:
            [self executeAutoStartupTaskIfNecessary];
            break;
        default:
            break;
    }
}

- (void)executeAutoStartupTaskIfNecessary {
    // v3.43: 使用 beginBackgroundTask 延长后台执行时间
    // iOS 15 上 NEHotspotHelper 唤醒 app 后，如果没有 background task，
    // 系统可能会在服务启动前就杀死 app
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];

    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];

    // 给服务一点时间启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
        if (bgTaskId != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTaskId];
            bgTaskId = UIBackgroundTaskInvalid;
        }
    });
}

- (void)savePhantomWiFiConfiguration {
    // v3.50: Save a phantom WPA2 WiFi SSID to the system configuration.
    // iOS remembers this SSID and will always try to find it during WiFi scanning after reboot.
    // This scanning process triggers NEHotspotHelper FilterScanList callback,
    // which wakes the app and starts VNC service automatically.
    // Works even in Ethernet-only environments (as long as WiFi switch is ON).
    
    @try {
    // Gate: only proceed when the user enabled the "虚拟 WiFi 自启" toggle
    if (![self isPhantomWiFiEnabled]) {
        NSLog(@"[TVNC] Phantom WiFi disabled by user, skipping save");
        return;
    }

    // Check if phantom SSID is already saved (avoid unnecessary prompts)
    NSString *savedKey = @"MatisuXCS_PhantomWiFiSaved";
    NSString *packageVer = [NSString stringWithUTF8String:PACKAGE_VERSION];
    NSString *savedVersion = [[NSUserDefaults standardUserDefaults] stringForKey:savedKey];
    if ([savedVersion isEqualToString:packageVer]) {
        NSLog(@"[TVNC] Phantom WiFi already saved for version %s, skipping", PACKAGE_VERSION);
        return;
    }
    
#ifdef THEBOOTSTRAP
    // Bootstrap build: NEHotspotConfiguration/NEHotspotConfigurationManager APIs are not
    // declared in the iOS 14.5 SDK headers used for bootstrap compilation, even though
    // they ARE available at runtime (iOS 11+). Use objc_msgSend to bypass compile-time
    // method resolution since the actual target device (iOS 14+) has these APIs available.
    Class configClass = NSClassFromString(@"NEHotspotConfiguration");
    Class managerClass = NSClassFromString(@"NEHotspotConfigurationManager");
    if (!configClass || !managerClass) {
        NSLog(@"[TVNC] NEHotspotConfiguration classes not available at runtime, skipping phantom WiFi");
        return;
    }
    
    // Create NEHotspotConfiguration with initWithSSID:passphrase: (WPA2, iOS 11+)
    NEHotspotConfiguration *config = (NEHotspotConfiguration *)[configClass alloc];
    if (@available(iOS 15.0, *)) {
        // Use isWPA3:NO initializer on iOS 15+ for explicit WPA2
        config = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)(config, sel_registerName("initWithSSID:passphrase:isWPA3:"), kPhantomSSID, kPhantomPassword, NO);
    } else {
        config = ((id (*)(id, SEL, id, id))objc_msgSend)(config, sel_registerName("initWithSSID:passphrase:"), kPhantomSSID, kPhantomPassword);
    }
    if (!config) {
        NSLog(@"[TVNC] Failed to create NEHotspotConfiguration, skipping phantom WiFi");
        return;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(config, sel_registerName("setJoinOnce:"), NO);
    
    // Apply configuration via NEHotspotConfigurationManager
    id manager = [managerClass performSelector:NSSelectorFromString(@"sharedManager")];
    if (!manager) {
        NSLog(@"[TVNC] NEHotspotConfigurationManager.sharedManager returned nil, skipping phantom WiFi");
        return;
    }
    SEL applySel = sel_registerName("applyConfiguration:completionHandler:");
    
    // CRITICAL: Copy block to heap before passing via objc_msgSend.
    // Unlike normal ObjC method calls, objc_msgSend does not auto-copy stack blocks.
    // Without this, the async completionHandler would access freed stack memory -> crash.
    void (^completionHandler)(NSError *) = [^(NSError *error) {
#else
    // Non-bootstrap build: SDK headers have full NEHotspotConfiguration declarations
    NEHotspotConfiguration *config;
    if (@available(iOS 15.0, *)) {
        config = [[NEHotspotConfiguration alloc] initWithSSID:kPhantomSSID
                                                     passphrase:kPhantomPassword
                                                      isWPA3:NO];
    } else {
        config = [[NEHotspotConfiguration alloc] initWithSSID:kPhantomSSID
                                                     passphrase:kPhantomPassword];
    }
    config.joinOnce = NO; // Persistent across reboots
    
    [[NEHotspotConfigurationManager sharedManager] applyConfiguration:config completionHandler:^(NSError *error) {
#endif
        if (error) {
            // Error code -7 = already joined, which is fine
            if (error.code == -7) {
                NSLog(@"[TVNC] Phantom WiFi SSID already in system configuration");
                [[NSUserDefaults standardUserDefaults] setObject:packageVer forKey:savedKey];
            } else {
                NSLog(@"[TVNC] Failed to save phantom WiFi: %@", error.localizedDescription);
                // Even if this fails, the existing NEHotspotHelper mechanism still works for WiFi
            }
        } else {
            NSLog(@"[TVNC] Phantom WiFi SSID '%@' saved successfully - iOS will scan for it after reboot", kPhantomSSID);
            [[NSUserDefaults standardUserDefaults] setObject:packageVer forKey:savedKey];
        }
    };
#ifdef THEBOOTSTRAP
    // Pass block as id type to objc_msgSend (blocks are id-compatible in ObjC runtime)
    ((void (*)(id, SEL, id, id))objc_msgSend)(manager, applySel, config, completionHandler);
#endif
    } @catch (NSException *e) {
        NSLog(@"[TVNC] Phantom WiFi save failed with exception: %@", e);
    }
}

- (BOOL)isPhantomWiFiEnabled {
    // Reads the "虚拟 WiFi 自启" toggle. PSSwitchCell writes to the shared
    // preference domain com.82flex.trollvnc (same as all other TrollVNC settings),
    // which differs from this app's own bundle id (com.matisu.xcs).
    // Must read from that suite explicitly, matching TVNCServiceCoordinator.
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];
    return [prefs boolForKey:@"PhantomWiFiEnabled"];
}

- (void)phantomWiFiPreferenceChanged:(NSNotification *)note {
    // React to live toggle changes without requiring an app relaunch
    BOOL current = [self isPhantomWiFiEnabled];
    if (current == _lastPhantomWiFiState) {
        return; // unrelated preference change
    }
    _lastPhantomWiFiState = current;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (current) {
                [self savePhantomWiFiConfiguration];
            } else {
                [self removePhantomWiFiConfiguration];
            }
        } @catch (NSException *e) {
            NSLog(@"[TVNC] Phantom WiFi preference change error: %@", e);
        }
    });
}

- (void)removePhantomWiFiConfiguration {
    // Remove the phantom SSID from the system WiFi configuration.
    // Safe to call anytime; idempotent. Used when the user turns the toggle OFF.
    @try {
        Class managerClass = NSClassFromString(@"NEHotspotConfigurationManager");
        if (!managerClass) {
            NSLog(@"[TVNC] NEHotspotConfigurationManager not available, skipping phantom WiFi removal");
            return;
        }

#ifdef THEBOOTSTRAP
        id manager = [managerClass performSelector:NSSelectorFromString(@"sharedManager")];
        if (!manager) {
            return;
        }
        SEL removeSel = sel_registerName("removeConfigurationForSSID:");
        ((void (*)(id, SEL, id))objc_msgSend)(manager, removeSel, kPhantomSSID);
#else
        [[NEHotspotConfigurationManager sharedManager] removeConfigurationForSSID:kPhantomSSID];
#endif

        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"MatisuXCS_PhantomWiFiSaved"];
        NSLog(@"[TVNC] Removed phantom WiFi SSID '%@' from system configuration", kPhantomSSID);
    } @catch (NSException *e) {
        NSLog(@"[TVNC] Failed to remove phantom WiFi: %@", e);
    }
}

- (void)dealloc {
    if (self.reachability) {
        SCNetworkReachabilitySetCallback(self.reachability, NULL, NULL);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, NULL);
        CFRelease(self.reachability);
        self.reachability = NULL;
    }
}

@end
