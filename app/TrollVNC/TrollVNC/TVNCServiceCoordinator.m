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

#import "TVNCServiceCoordinator.h"
#import "TrollVNC-Swift.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MobileCoreServices/LSApplicationProxy.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>

#import "Control.h"

NSNotificationName const TVNCServiceStatusDidChangeNotification = @"TVNCServiceStatusDidChangeNotification";

FOUNDATION_EXPORT NSString *const SBSApplicationLaunchOptionUnlockDeviceKey;
FOUNDATION_EXPORT
int SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(CFStringRef bundleIdentifier, CFURLRef url,
                                                             CFDictionaryRef appOptions, CFDictionaryRef launchOptions,
                                                             BOOL suspended);

@interface TVNCServiceCoordinator ()
@property(nonatomic, strong) NSTimer *checkTimer;
@property(nonatomic, strong) NSUserDefaults *userDefaults;
@end

@implementation TVNCServiceCoordinator

+ (instancetype)sharedCoordinator {
    static TVNCServiceCoordinator *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (NSDictionary *)sharedTaskEnvironment {
    static NSDictionary *sharedEnvironment = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary *env =
            [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
        NSString *languageCode = [[NSLocale preferredLanguages] firstObject];
        if (languageCode) {
            env[@"TVNC_LANGUAGE_CODE"] = languageCode;
        }
#if TARGET_IPHONE_SIMULATOR
        [env addEntriesFromDictionary:[[NSProcessInfo processInfo] environment]];
#endif
        sharedEnvironment = [env copy];
    });
    return sharedEnvironment;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _checkTimer = nil;
    _serviceRunning = NO;
    _userDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.82flex.trollvnc"];

    NSBundle *prefsBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                     ofType:@"bundle"]];

    NSString *presetPath = [prefsBundle pathForResource:@"Managed" ofType:@"plist"];
    if (presetPath) {
        NSDictionary *presetDefaults = [NSDictionary dictionaryWithContentsOfFile:presetPath];
        if (presetDefaults) {
            [_userDefaults registerDefaults:presetDefaults];
        }
    }

    // v4.34: Register for foreground transition to immediately restart daemon
    // On iOS 16, when user switches to another App (e.g. a heavy game), the App gets
    // suspended, the 3s checkTimer stops, and if jetsam kills the daemon while the App
    // is suspended, the daemon stays dead until the App regains foreground or BGTask fires.
    // This observer ensures an immediate restart check when the App becomes active again.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

#pragma mark - Public Methods

- (void)registerServiceMonitor {
    [_checkTimer invalidate];
    [self checkTimerFired:nil];
    _checkTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                   target:self
                                                 selector:@selector(checkTimerFired:)
                                                 userInfo:nil
                                                  repeats:YES];
}

- (BOOL)isServiceRunning {
    return _serviceRunning;
}

#pragma mark - Private Methods

- (void)checkTimerFired:(NSTimer *_Nullable)timer {
    [self ensureServiceRunning];
}

// v4.34: Called when App returns to foreground (via UIApplicationDidBecomeActiveNotification).
// Immediately checks and restarts the daemon if it was killed by jetsam while the App was suspended.
- (void)applicationDidBecomeActive {
    [self ensureServiceRunning];
}

// v4.34: Aggressive recovery using a background task.
// When daemon death is detected, acquire a ~30s background execution window and retry
// spawning the manager+daemon every 5s. This handles the iOS 16 scenario where:
// 1) App is suspended → 3s timer stops → can't detect daemon death
// 2) BGTask fires but single spawn attempt may fail if the system is still under pressure
// 3) Multiple retries within a background task window significantly improve recovery odds
- (void)aggressiveRecoveryWithBackgroundTask {
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        if (bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    }];

    if (bgTask == UIBackgroundTaskInvalid) {
        // No background time available — just spawn once and hope for the best
        [self spawnService];
        return;
    }

    // Retry spawn in a background queue for up to 5 attempts (~25s total).
    // Each attempt: spawn manager → wait 5s → check if daemon came up.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int attempt = 0; attempt < 5; attempt++) {
            if ([self _isServiceRunning]) {
                break;
            }
            [self spawnService];
            [NSThread sleepForTimeInterval:5.0];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (bgTask != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
        });
    });
}

- (void)ensureServiceRunning {
    BOOL running = [self _isServiceRunning];
    if (!running) {
        [self checkPrebootDependencies];
        // v4.34: Use aggressive recovery with background task instead of single spawn.
        // This retries multiple times within a ~30s background window, significantly
        // improving recovery odds on iOS 16 where jetsam may kill the daemon while
        // the App is suspended and the 3s checkTimer is stopped.
        [self aggressiveRecoveryWithBackgroundTask];
    }
    if (_serviceRunning != running) {
        _serviceRunning = running;
        [[NSNotificationCenter defaultCenter] postNotificationName:TVNCServiceStatusDidChangeNotification object:self];
    }
}

- (BOOL)_isServiceRunning {
#if TARGET_IPHONE_SIMULATOR
    return YES;
#else
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        return NO;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvAlivePort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
    close(sockfd);

    return result == 0;
#endif
}

- (void)spawnService {
    static TRTask *serviceTask = nil;
    serviceTask = [[TRTask alloc] init];

    NSString *executablePath = [[NSBundle mainBundle] pathForResource:@"trollvncmanager" ofType:@""];
    if (!executablePath) {
        return;
    }

    [serviceTask setExecutableURL:[NSURL fileURLWithPath:executablePath]];

#if !TARGET_IPHONE_SIMULATOR
    [serviceTask setUserIdentifier:0];
    [serviceTask setGroupIdentifier:0];
#endif

    [serviceTask setArguments:[NSArray array]];
    [serviceTask setEnvironment:[TVNCServiceCoordinator sharedTaskEnvironment]];

    NSError *error = nil;
    BOOL launched = [serviceTask launchAndReturnError:&error];
    if (!launched) {
#if DEBUG
        NSLog(@"[TVNC] Failed to launch service: %@", error);
#endif
        return;
    }

    int unused;
    waitpid(serviceTask.processIdentifier, &unused, WNOHANG);
}

- (void)checkPrebootDependencies {
#if !TARGET_IPHONE_SIMULATOR
    id configVal = [_userDefaults objectForKey:@"LaunchAtLogin"];

    NSString *appId = nil;
    if ([configVal isKindOfClass:[NSNumber class]]) {
        BOOL launchAtLogin = [(NSNumber *)configVal boolValue];
        if (launchAtLogin) {
            appId = [[NSBundle mainBundle] bundleIdentifier];
        }
    } else if ([configVal isKindOfClass:[NSString class]]) {
        appId = (NSString *)configVal;
    } else if ([configVal isKindOfClass:[NSArray class]]) {
        NSArray *appIds = (NSArray *)configVal;
        for (NSString *candidateAppId in appIds) {
            LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:candidateAppId];
            if (![appProxy isInstalled]) {
                continue;
            }
            appId = candidateAppId;
        }
    }

    if (!appId) {
        return;
    }

    NSDate *lastLaunch = [_userDefaults objectForKey:@"LastPrebootLaunch"];
    if (lastLaunch) {
        // Compare with device uptime
        NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
        NSDate *bootTime = [NSDate dateWithTimeIntervalSinceNow:-uptime];
        if ([lastLaunch compare:bootTime] == NSOrderedDescending) {
            // Already launched since last boot
            return;
        }
    }

    UInt32 result;
    result = SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        (__bridge CFStringRef)appId, NULL, NULL,
        (__bridge CFDictionaryRef) @{SBSApplicationLaunchOptionUnlockDeviceKey : @YES}, NO);

    if (result == 0) {
        NSDate *now = [NSDate date];
        [_userDefaults setObject:now forKey:@"LastPrebootLaunch"];
        [_userDefaults synchronize];
    }
#endif
}

@end
