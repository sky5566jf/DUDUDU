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

@interface TVNCHotspotManager ()
@property (nonatomic, assign) SCNetworkReachabilityRef reachability;
@property (nonatomic, assign) BOOL lastNetworkState;
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

- (void)dealloc {
    if (self.reachability) {
        SCNetworkReachabilitySetCallback(self.reachability, NULL, NULL);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, NULL);
        CFRelease(self.reachability);
        self.reachability = NULL;
    }
}

@end
