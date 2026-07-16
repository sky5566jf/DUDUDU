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
#import <BackgroundTasks/BackgroundTasks.h>

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

static NSString *const kTVNCBGTaskIdentifier = @"com.82flex.trollvnc.servicemonitor";

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

    // 启动本地 HTTP 服务器（端口 8183）用于文本输入转发
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

@end
