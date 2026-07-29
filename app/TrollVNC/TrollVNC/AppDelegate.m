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
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

static NSString *const kTVNCBGTaskIdentifier = @"com.82flex.trollvnc.servicemonitor";

@interface AppDelegate ()
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

    // v4.41: 纯启动器每次 active 都走「确认服务就绪 → 显示提示 → 退出回收 GUI 内存」流程。
    // 关键修复：此处刻意不使用「只退出一次」的跨次 guard（v4.39/4.40 的 tvnc_didAutoCloseUI）。
    // 原因：iOS 在前台 active 阶段调用 exit(0) 偶尔不会干净终止进程（被系统保留为 suspended），
    // 导致下次打开是 resume 同一进程、命中旧 guard 而停留在界面（#2 已知 bug）。
    // 改为每次 active 都重新确认并退出，banner 用固定 tag 去重防止叠加，确保「服务起来后一定退得掉」。
    [self tvnc_startLauncherFlowWithTimeout:10.0];
}

// 后台轮询 kTvAlivePort，确认 daemon 真正监听端口后回到主线程显示提示并退出；
// 超时未就绪则放弃退出（App 留在前台），避免「App 退了服务没起来」的黑屏。
// 每次 applicationDidBecomeActive 都会调用本方法（无跨次 guard），保证 resume 场景也能退出。
- (void)tvnc_startLauncherFlowWithTimeout:(NSTimeInterval)timeoutSec {
    static const NSTimeInterval kPollInterval = 0.5;  // 每 0.5s 探测一次
    static const int kRespawnEveryN = 4;              // 每 2s 重新触发一次 spawn 兜底
    __block NSTimeInterval waited = 0;
    __block int pollCount = 0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (waited < timeoutSec) {
            if ([self tvnc_isAlivePortOpen]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self tvnc_showSuccessBannerThenExit];
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

// 在窗口上显示「XCS 服务启动成功」提示，短暂停留后 exit(0) 回收 App GUI 内存。
// banner 用固定 tag(98765) 去重，避免多次 active 叠加多个提示；多次调用只会安排一次退出。
- (void)tvnc_showSuccessBannerThenExit {
    UIWindow *window = [self tvnc_activeWindow];
    if (!window) {
        // 拿不到窗口（极端情况）也直接退，不卡界面
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(EXIT_SUCCESS); });
        return;
    }

    UILabel *existing = [window viewWithTag:98765];
    if (!existing) {
        UILabel *banner = [[UILabel alloc] init];
        banner.tag = 98765;
        banner.text = @"XCS服务启动成功";
        banner.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        banner.textColor = [UIColor labelColor];
        banner.backgroundColor = [UIColor secondarySystemBackgroundColor];
        banner.textAlignment = NSTextAlignmentCenter;
        banner.layer.cornerRadius = 14;
        banner.layer.masksToBounds = YES;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        [window addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.widthAnchor constraintEqualToConstant:220],
            [banner.heightAnchor constraintEqualToConstant:48],
            [banner.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [banner.centerYAnchor constraintEqualToAnchor:window.centerYAnchor],
        ]];
        banner.alpha = 0;
        [UIView animateWithDuration:0.25 animations:^{ banner.alpha = 1; }];
    }

    // 停留 1.2s 让用户看清提示，然后干净退出回收 GUI 内存
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(EXIT_SUCCESS);
    });
}

// 取当前前台 active 的 window（iOS 13+ 多场景）
- (UIWindow *)tvnc_activeWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                // 最后一个 window 通常是我们的空白窗口（keyWindow）
                return ws.windows.lastObject ?: ws.windows.firstObject;
            }
        }
    }
    return UIApplication.sharedApplication.keyWindow;
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
