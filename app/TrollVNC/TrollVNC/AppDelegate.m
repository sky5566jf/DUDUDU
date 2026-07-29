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

#import "AppDelegate.h"
#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"
#import "TVNCAppInputServer.h"
#import "Control.h"
#import <BackgroundTasks/BackgroundTasks.h>
#import <stdlib.h>

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

static NSString *const kTVNCBGTaskIdentifier = @"com.82flex.trollvnc.servicemonitor";

@interface AppDelegate ()
@property (nonatomic, assign) BOOL tvnc_didAutoCloseUI;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // v3.43: 申请后台执行时间，确保服务有足够时间启动
    __block UIBackgroundTaskIdentifier launchBgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:launchBgTask];
        launchBgTask = UIBackgroundTaskInvalid;
    }];

    // Override point for customization after application launch.
    [[TVNCServiceCoordinator sharedCoordinator] registerServiceMonitor];
    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];

    // 启动本地 HTTP 服务器（端口 8184）用于文本输入转发
    [[TVNCAppInputServer sharedServer] startServer];

    // v3.43: 注册 BGTaskScheduler
    [self registerBackgroundTask];

#ifdef THEBOOTSTRAP
    [[TVNCVersionChecker shared] setCurrentVersion:@"3.43"];
#endif

    // 延迟释放 background task
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (launchBgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:launchBgTask];
            launchBgTask = UIBackgroundTaskInvalid;
        }
    });

    return YES;
}

#pragma mark - Background Task Scheduler (v3.43)

- (void)registerBackgroundTask {
    BOOL registered = [[BGTaskScheduler sharedScheduler]
        registerForTaskWithIdentifier:kTVNCBGTaskIdentifier
                          usingQueue:nil
                       launchHandler:^void(BGTask *task) {
        [self handleBackgroundTask:task];
    }];
    if (registered) {
        [self scheduleNextBackgroundTask];
    }
}

- (void)scheduleNextBackgroundTask {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kTVNCBGTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:60];
    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
}

- (void)handleBackgroundTask:(BGTask *)task {
    [self scheduleNextBackgroundTask];
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];
    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
    [task setTaskCompletedWithSuccess:YES];
    if (bgTaskId != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }
}

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after
    // application:didFinishLaunchingWithOptions. Use this method to release any resources that were specific to the
    // discarded scenes, as they will not return.
}

// v4.34: Immediate daemon restart check when App becomes active.
// On iOS 16, when user switches to a heavy App (e.g. Unity game), the App gets suspended
// and jetsam may kill the daemon. When the user returns, we immediately check and restart.
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];

    // C方案 (v4.39): App 作为纯启动器——确认服务真正就绪后再彻底退出（而非挂起）。
    // 之所以能安全退出：trollvncmanager 在 THEBOOTSTRAP(.tipa) 下已 setsid() 脱离 App 进程组
    // 并吞掉 SIGHUP/SIGINT/SIGTERM，由 TRWatchDog(KeepAlive=YES) 常驻看管 trollvncserver，
    // 故 App 进程退出后 8182/5901/WebDAV 服务继续存活。重启用 TVNCHotspotManager 的
    // NEHotspotHelper(WiFi 关联唤醒本 App) 重新 spawn manager —— 已实机验证。
    // /api/input 走 daemon 内 剪贴板+Cmd+V 通道(TVNCApiManager.inputText:，中文可靠)，
    // 不依赖 App 内 8184(TVNCAppInputServer 为死代码，daemon 调 AX 会崩)，故退出不影响输入。
    // 关键：必须先确认 kTvAlivePort(46751) 端口可连（daemon 已监听）才退出，
    // 否则出现「App 退了但服务没起来」的黑屏。超时(默认10s)未就绪则放弃退出，App 留前台兜底。
    if (self.tvnc_didAutoCloseUI) return;
    self.tvnc_didAutoCloseUI = YES;

    [self tvnc_waitThenExitWhenServiceReadyWithTimeout:10.0];
}

// 后台轮询 kTvAlivePort，确认 daemon 真正监听端口后再干净退出；
// 超时未就绪则放弃退出（App 留在前台），避免「App 退了服务没起来」的黑屏。
- (void)tvnc_waitThenExitWhenServiceReadyWithTimeout:(NSTimeInterval)timeoutSec {
    static const NSTimeInterval kPollInterval = 0.5;  // 每 0.5s 探测一次
    static const int kRespawnEveryN = 4;              // 每 2s 重新触发一次 spawn 兜底
    __block NSTimeInterval waited = 0;
    __block int pollCount = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (waited < timeoutSec) {
            if ([self tvnc_isAlivePortOpen]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    exit(EXIT_SUCCESS);
                });
                return;
            }
            // 周期性重新触发 spawn，防止首次 spawn 被系统拒绝/延迟
            if ((++pollCount % kRespawnEveryN) == 0) {
                [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
            }
            [NSThread sleepForTimeInterval:kPollInterval];
            waited += kPollInterval;
        }
        // 超时未就绪：放弃退出，App 留在前台，用户可手动排查（而非黑屏退出）
    });
}

// 探测 daemon 存活端口 kTvAlivePort(46751) 是否可连（端口已监听 = 服务就绪）。
- (BOOL)tvnc_isAlivePortOpen {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTvAlivePort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
    close(sockfd);
    return result == 0;
}

// v4.34: When App is about to go to background, start a background task to keep monitoring
// the daemon for a short window. This bridges the gap between App suspension and BGTask fire.
- (void)applicationWillResignActive:(UIApplication *)application {
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    if (bgTask == UIBackgroundTaskInvalid) return;

    // Check daemon health every 5s for the duration of the background task (~30s on iOS 16)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 5; i++) {
            if (bgTask == UIBackgroundTaskInvalid) return;
            [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];
            [NSThread sleepForTimeInterval:5.0];
        }
        if (bgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
    });
}

@end
