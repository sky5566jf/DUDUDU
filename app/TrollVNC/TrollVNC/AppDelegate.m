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
#import <BackgroundTasks/BackgroundTasks.h>

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

static NSString *const kTVNCBGTaskIdentifier = @"com.82flex.trollvnc.servicemonitor";

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // v3.43: 申请后台执行时间，确保服务有足够时间启动
    // iOS 15 上 NEHotspotHelper 唤醒 app 后，如果没有 background task，
    // 系统可能会在服务启动前就杀死 app（之前 GitHubReleaseUpdater 的网络请求会隐式延长后台时间）
    __block UIBackgroundTaskIdentifier launchBgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:launchBgTask];
        launchBgTask = UIBackgroundTaskInvalid;
    }];

    // Override point for customization after application launch.
    [[TVNCServiceCoordinator sharedCoordinator] registerServiceMonitor];
    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];

    // v3.43: 注册 BGTaskScheduler 作为补充唤醒机制（修复 iOS 15 重启后不自启动）
    [self registerBackgroundTask];

#ifdef THEBOOTSTRAP
    // Initialize Version Checker (manual only, no background check)
    [[TVNCVersionChecker shared] setCurrentVersion:@"3.43"];
#endif

    // 延迟释放 background task，给服务启动留出时间
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
    // 注册 BGAppRefreshTask — 系统会定期唤醒 app
    BOOL registered = [[BGTaskScheduler sharedScheduler]
        registerForTaskWithIdentifier:kTVNCBGTaskIdentifier
                          usingQueue:nil
                           handler:^void(BGTask *task) {
        [self handleBackgroundTask:task];
    }];
    if (registered) {
        [self scheduleNextBackgroundTask];
    }
}

- (void)scheduleNextBackgroundTask {
    BGAppRefreshTaskRequest *request = [[BGAppRefreshTaskRequest alloc] initWithIdentifier:kTVNCBGTaskIdentifier];
    request.earliestBeginDate = [NSDate dateWithTimeIntervalSinceNow:60]; // 最早 1 分钟后
    NSError *error = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&error];
}

- (void)handleBackgroundTask:(BGTask *)task {
    // 安排下一次唤醒
    [self scheduleNextBackgroundTask];

    // 使用 background task 延长执行时间
    UIApplication *app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTaskId];
        bgTaskId = UIBackgroundTaskInvalid;
    }];

    // 检查并启动服务
    [[TVNCServiceCoordinator sharedCoordinator] ensureServiceRunning];

    // 完成任务
    [task setTaskCompletedWithSuccess:YES];

    // 结束 background task
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

@end
