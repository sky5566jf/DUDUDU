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
    [self tvnc_runLauncherFlow];
}

// 公开入口：纯启动器流程。被 applicationDidBecomeActive: 与 sceneDidBecomeActive: 双调用。
// 刻意不设置「只跑一次」的持久 guard —— 因为 iOS 在前台 active 阶段调 exit(0) 偶尔不会干净
// 终止进程（被挂起为 suspended），下次打开是 resume 同一进程；若无 guard 则 resume 会重新
// 进入本流程再次确认端口并退出，从而根治「二次打开停留在界面」的 bug。
- (void)tvnc_runLauncherFlow {
    [self tvnc_startLauncherFlowWithTimeout:10.0];
}

// 后台轮询 kTvAlivePort，确认 daemon 真正监听端口后回到主线程显示提示并退出；
// 超时未就绪则放弃退出（App 留在前台），避免「App 退了服务没起来」的黑屏。
// 每次 active 都会重新调用本方法（无跨次 guard），保证 resume 场景也能退出。
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

// 在窗口上显示醒目的「XCS服务启动成功」提示，短暂停留后 exit(0) 回收 App GUI 内存。
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
        banner.font = [UIFont boldSystemFontOfSize:19];
        banner.textColor = [UIColor whiteColor];
        // 醒目蓝色胶囊，主屏深色背景下清晰可见
        banner.backgroundColor = [UIColor colorWithRed:0.0 green:0.47 blue:1.0 alpha:1.0];
        banner.textAlignment = NSTextAlignmentCenter;
        banner.layer.cornerRadius = 16;
        banner.layer.masksToBounds = YES;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        [window addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.widthAnchor constraintEqualToConstant:260],
            [banner.heightAnchor constraintEqualToConstant:56],
            [banner.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [banner.centerYAnchor constraintEqualToAnchor:window.centerYAnchor],
        ]];
        banner.alpha = 0;
        banner.transform = CGAffineTransformMakeScale(0.92, 0.92);
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            banner.alpha = 1;
            banner.transform = CGAffineTransformIdentity;
        } completion:nil];
    }

    // 停留 1.5s 让用户看清提示，然后干净退出回收 GUI 内存
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        exit(EXIT_SUCCESS);
    });
}

// 取当前前台 active 的 window（iOS 13+ 多场景）。
// 优先用 windowScene.keyWindow —— 旧实现用 ws.windows.lastObject 经常取到系统窗口
// （状态栏等），导致 banner 加在不可见窗口上而从没显示出来。
- (UIWindow *)tvnc_activeWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                UIWindow *kw = ws.keyWindow;
                if (kw) return kw;
                // 回退：找带 rootViewController 的窗口
                for (UIWindow *w in ws.windows) {
                    if (w.rootViewController) return w;
                }
                return ws.windows.lastObject ?: ws.windows.firstObject;
            }
        }
    }
    UIWindow *kw = UIApplication.sharedApplication.keyWindow;
    return kw ?: UIApplication.sharedApplication.windows.lastObject;
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
