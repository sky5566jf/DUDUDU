#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Minimal crash logger - single file overwrite at /var/mobile/Media/xcs/MatisuXCS_app_crash_log.txt
static void MatisuXCSWriteCrashLog(int sig) {
    NSString *crashDir = @"/var/mobile/Media/xcs";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:crashDir]) {
        [fm createDirectoryAtPath:crashDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *ts = [fmt stringFromDate:[NSDate date]];

    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"=== MatisuXCS App Crash Log ===\n"];
    [log appendFormat:@"Time: %@\n", ts];
    [log appendFormat:@"Signal: %d\n", sig];

    NSString *path = [crashDir stringByAppendingPathComponent:@"MatisuXCS_app_crash_log.txt"];
    [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void MatisuXCSCrashHandler(int sig) {
    MatisuXCSWriteCrashLog(sig);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void MatisuXCSSetupCrashLogger(void) {
    signal(SIGABRT, MatisuXCSCrashHandler);
    signal(SIGSEGV, MatisuXCSCrashHandler);
    signal(SIGBUS, MatisuXCSCrashHandler);
    signal(SIGILL, MatisuXCSCrashHandler);
    signal(SIGFPE, MatisuXCSCrashHandler);
    signal(SIGPIPE, SIG_IGN);
}

@interface MatisuXCSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MatisuXCSAppDelegate

// Try to open a URL using SpringBoardServices private APIs
// This is needed because UIApplication openURL cannot open prefs: scheme URLs
// in a sandboxed app context on jailbroken iOS
- (BOOL)openURLViaSBS:(NSURL *)url {
    void *sbsHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!sbsHandle) {
        NSLog(@"[MatisuXCS] Failed to load SpringBoardServices");
        return NO;
    }

    // Try SBSOpenSensitiveURLAndUnlockDevice first
    typedef void (*SBSOpenSensitiveURLFunc)(CFURLRef url, int flags);
    SBSOpenSensitiveURLFunc openSensitive = (SBSOpenSensitiveURLFunc)dlsym(sbsHandle, "SBSOpenSensitiveURLAndUnlockDevice");
    if (openSensitive) {
        @try {
            openSensitive((__bridge CFURLRef)url, 1);
            NSLog(@"[MatisuXCS] SBSOpenSensitiveURLAndUnlockDevice success: %@", url);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[MatisuXCS] SBSOpenSensitiveURLAndUnlockDevice exception: %@", e);
        }
    }

    // Fallback: SBSOpenURL
    typedef void (*SBSOpenURLFunc)(CFURLRef url);
    SBSOpenURLFunc openURL = (SBSOpenURLFunc)dlsym(sbsHandle, "SBSOpenURL");
    if (openURL) {
        @try {
            openURL((__bridge CFURLRef)url);
            NSLog(@"[MatisuXCS] SBSOpenURL success: %@", url);
            return YES;
        } @catch (NSException *e) {
            NSLog(@"[MatisuXCS] SBSOpenURL exception: %@", e);
        }
    }

    return NO;
}

// Try to open settings via LSApplicationWorkspace (openApplicationWithBundleID:)
- (BOOL)openSettingsApp {
    void *mlsHandle = dlopen("/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    if (!mlsHandle) {
        mlsHandle = dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    }

    Class LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (!LSAppWorkspace) {
        // Try from FrontBoard
        void *fbHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardService.framework/FrontBoardService", RTLD_LAZY);
        if (!fbHandle) {
            fbHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        }
        LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    }

    if (LSAppWorkspace) {
        // LSApplicationWorkspace defaultWorkspace
        SEL defaultWorkspaceSEL = NSSelectorFromString(@"defaultWorkspace");
        if ([LSAppWorkspace respondsToSelector:defaultWorkspaceSEL]) {
            id workspace = ((id(*)(id, SEL))objc_msgSend)(LSAppWorkspace, defaultWorkspaceSEL);
            if (workspace) {
                // openApplicationWithBundleID:withOptions:error: (iOS 9+)
                // or openApplicationWithBundleID: (older)
                SEL openSEL = NSSelectorFromString(@"openApplicationWithBundleID:withOptions:error:");
                if ([workspace respondsToSelector:openSEL]) {
                    NSDictionary *options = @{};
                    NSError *__autoreleasing error = nil;
                    NSError *errorPtr = error;
                    BOOL success = ((BOOL(*)(id, SEL, id, id, void *))objc_msgSend)(
                        workspace, openSEL,
                        @"com.apple.Preferences",
                        options,
                        &errorPtr
                    );
                    error = errorPtr;
                    NSLog(@"[MatisuXCS] LSApplicationWorkspace openApplicationWithBundleID:options:error: -> %d, error: %@", success, error);
                    if (success) return YES;
                }

                openSEL = NSSelectorFromString(@"openApplicationWithBundleID:");
                if ([workspace respondsToSelector:openSEL]) {
                    BOOL success = ((BOOL(*)(id, SEL, id))objc_msgSend)(workspace, openSEL, @"com.apple.Preferences");
                    NSLog(@"[MatisuXCS] LSApplicationWorkspace openApplicationWithBundleID: -> %d", success);
                    if (success) return YES;
                }
            }
        }
    }

    NSLog(@"[MatisuXCS] LSApplicationWorkspace not available");
    return NO;
}

- (void)openSettingsAndExit {
    NSLog(@"[MatisuXCS] Attempting to open settings...");

    // Try various URL schemes to open settings
    NSArray *urlStrings = @[
        @"prefs:root=TrollVNCPrefs",
        @"App-prefs:root=TrollVNCPrefs",
        @"prefs:root=TrollVNC",
        @"App-prefs:root=TrollVNC",
    ];

    // Method 1: Try SBS private APIs (can open specific PreferenceLoader pane)
    for (NSString *urlStr in urlStrings) {
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) continue;
        if ([self openURLViaSBS:url]) {
            NSLog(@"[MatisuXCS] Success via SBS: %@", urlStr);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                exit(0);
            });
            return;
        }
    }

    NSLog(@"[MatisuXCS] SBS methods failed, trying LSApplicationWorkspace...");

    // Method 2: Open Settings.app via LSApplicationWorkspace
    if ([self openSettingsApp]) {
        NSLog(@"[MatisuXCS] Opened Settings.app via LSApplicationWorkspace");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
        return;
    }

    NSLog(@"[MatisuXCS] LSApplicationWorkspace failed, trying UIApplication openURL...");

    // Method 3: UIApplication openURL (last resort, may only open Settings root)
    UIApplication *app = [UIApplication sharedApplication];
    for (NSString *urlStr in urlStrings) {
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) continue;

        if (@available(iOS 10.0, *)) {
            __block BOOL opened = NO;
            [app openURL:url options:@{} completionHandler:^(BOOL success) {
                opened = success;
                NSLog(@"[MatisuXCS] openURL: %@ -> %d", urlStr, success);
            }];
            // Wait a bit and check
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (opened) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        exit(0);
                    });
                }
            });
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            BOOL success = [app openURL:url];
#pragma clang diagnostic pop
            NSLog(@"[MatisuXCS] openURL(deprecated): %@ -> %d", urlStr, success);
            if (success) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    exit(0);
                });
                return;
            }
        }
    }

    // Method 4: Just open generic Settings
    NSURL *settingsUrl = [NSURL URLWithString:@"prefs:root"];
    if (settingsUrl) {
        if (@available(iOS 10.0, *)) {
            [app openURL:settingsUrl options:@{} completionHandler:^(BOOL success) {
                NSLog(@"[MatisuXCS] openURL prefs:root -> %d", success);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    exit(0);
                });
            }];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [app openURL:settingsUrl];
#pragma clang diagnostic pop
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                exit(0);
            });
        }
        return;
    }

    NSLog(@"[MatisuXCS] All methods failed");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(0);
    });
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    MatisuXCSSetupCrashLogger();

    NSLog(@"[MatisuXCS] App launched, opening settings...");
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];

    // Show a brief loading text
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    label.center = self.window.center;
    label.text = @"MatisuXCS";
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:18];
    [self.window addSubview:label];

    // Small delay to ensure window is visible before jumping
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self openSettingsAndExit];
    });

    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([MatisuXCSAppDelegate class]));
    }
}
