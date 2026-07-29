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

#import "SceneDelegate.h"
#import "AppDelegate.h"

@interface SceneDelegate ()

@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    // 纯启动器模式：不加载任何 UI（Main.storyboard 已不再自动加载）。
    // 仅创建一个空白窗口作为 App 存活所需的表面；服务由 AppDelegate 拉起，
    // 在 applicationDidBecomeActive 确认 kTvAlivePort 就绪后 App 自动 exit(0)。
    // 窗口内容完全空白（无文字/品牌/按钮），符合「App 不显示任何东西」的需求。
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];

    UIViewController *blankViewController = [[UIViewController alloc] init];
    blankViewController.view.backgroundColor = [UIColor systemBackgroundColor];
    blankViewController.view.opaque = YES;

    self.window.rootViewController = blankViewController;
    [self.window makeKeyAndVisible];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see
    // `application:didDiscardSceneSessions` instead).
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    // 纯启动器双保险：scene 进入 active 时也触发一次启动流程。
    // 根因：iOS 在前台 active 阶段调 exit(0) 偶尔不会干净终止进程（挂起为 suspended），
    // 下次打开是 resume 同一进程，仅靠 applicationDidBecomeActive: 在个别机型/时序下可能不触发，
    // 导致「二次打开停留在界面」。这里再补一刀，确保 resume 后一定会重新确认端口并退出。
    AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
    if ([appDelegate respondsToSelector:@selector(tvnc_runLauncherFlow)]) {
        [appDelegate tvnc_runLauncherFlow];
    }
}

- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
}

@end
