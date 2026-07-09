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

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <notify.h>
#import <spawn.h>
#import <stdlib.h>
#import <sys/proc_info.h>
#import <sys/socket.h>
#import <sys/sysctl.h>
#import <unistd.h>

#import "Control.h"
#import "Logging.h"
#import "TRWatchDog.h"
#import "libproc.h"

#define SINGLETON_MARKER_PATH "/var/mobile/Library/Caches/com.82flex.trollvnc.manager.pid"

BOOL tvncLoggingEnabled = YES;
BOOL tvncVerboseLoggingEnabled = NO;

static TRWatchDog *gWatchDog = nil;

// Send signal to all processes with the given name (replacement for killall command)
static void tvncKillAllByName(NSString *processName, int sig) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return;
    }
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid == getpid()) continue;
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        if (pathLength > 0) {
            NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];
            if ([[fullPath lastPathComponent] isEqualToString:processName]) {
                kill(pid, sig);
            }
        }
    }
    free(procs);
}

static void mSignalAction(int signal, struct __siginfo *info, void *context) {
    if (signal == SIGCHLD) {
        int unused;
        waitpid(info->si_pid, &unused, WNOHANG);
    }
}

static void mSignalHandler(int signal) {
    fprintf(stderr, "signal %d received\n", signal);

    /* Terminate itself */
    if (signal == SIGHUP || signal == SIGINT) {
        CFRunLoopStop(CFRunLoopGetMain());
    } else if (signal == SIGTERM) {
        exit((EXIT_FAILURE << 7) | signal);
    }
}

static void monitorSelfAndRestartIfVnodeDeleted(const char *executable) {
    int myHandle = open(executable, O_EVTONLY);
    if (myHandle <= 0) {
        return;
    }

    static unsigned long monitorMask = DISPATCH_VNODE_DELETE;
    static dispatch_source_t monitorSource;
    monitorSource =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, myHandle, monitorMask, dispatch_get_main_queue());

    dispatch_source_set_event_handler(monitorSource, ^{
        unsigned long flags = dispatch_source_get_data(monitorSource);
        if (flags & DISPATCH_VNODE_DELETE) {
            dispatch_source_cancel(monitorSource);
            exit(EXIT_SUCCESS);
        }
    });

    dispatch_resume(monitorSource);
}

// Open a local IPv4 TCP listener on 127.0.0.1:port that accepts and
// immediately closes connections (no response). This lets clients detect
// the service by a successful connect without any protocol exchange.
static void openLocalDummyService(uint16_t port) {
    static int sListenFD = -1;
    static dispatch_source_t sAcceptSource = nil;
    if (sListenFD != -1 || sAcceptSource) {
        return; // already set up
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "[dummy-listener] socket() failed: %s\n", strerror(errno));
        return;
    }

    int yes = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    // Non-blocking for accept loop
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags != -1)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[dummy-listener] bind(127.0.0.1:%u) failed: %s\n", (unsigned)port, strerror(errno));
        close(fd);
        return;
    }

    if (listen(fd, SOMAXCONN) < 0) {
        fprintf(stderr, "[dummy-listener] listen() failed: %s\n", strerror(errno));
        close(fd);
        return;
    }

    sListenFD = fd;
    sAcceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    if (!sAcceptSource) {
        close(fd);
        sListenFD = -1;
        return;
    }

    dispatch_source_set_event_handler(sAcceptSource, ^{
        while (1) {
            struct sockaddr_storage clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int cfd = accept(fd, (struct sockaddr *)&clientAddr, &clientLen);
            if (cfd < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    break;
                }
                // Unexpected error; break to avoid busy loop
                break;
            }
            // Immediately close; no response needed
            close(cfd);
        }
    });

    dispatch_source_set_cancel_handler(sAcceptSource, ^{
        if (sListenFD != -1) {
            close(sListenFD);
            sListenFD = -1;
        }
    });

    dispatch_resume(sAcceptSource);
    fprintf(stderr, "[dummy-listener] listening on 127.0.0.1:%u\n", (unsigned)port);
}

int main(int argc, const char *argv[]) {
    if (!argv || !argv[0] || argv[0][0] != '/') {
        fprintf(stderr, "This program must be run from an absolute path\n");
        return EXIT_FAILURE;
    }

    /* Singleton */
    monitorSelfAndRestartIfVnodeDeleted(argv[0]);

    NSString *markerPath = @SINGLETON_MARKER_PATH;
    const char *cMarkerPath = [markerPath fileSystemRepresentation];

    // Open file for read/write, create if doesn't exist
    static int lockFD = open(cMarkerPath, O_RDWR | O_CREAT, 0644);
    if (lockFD == -1) {
        fprintf(stderr, "Failed to open lock file: %s\n", strerror(errno));
        return EXIT_FAILURE;
    }

    // Try to acquire an exclusive lock
    struct flock fl;
    fl.l_type = F_WRLCK;
    fl.l_whence = SEEK_SET;
    fl.l_start = 0;
    fl.l_len = 0; // Lock entire file

    if (fcntl(lockFD, F_SETLK, &fl) == -1) {
        // Lock already held by another process
        fprintf(stderr, "Another instance is already running\n");
        close(lockFD);
        return EXIT_FAILURE;
    }

    // Truncate the file to clear any previous content
    if (ftruncate(lockFD, 0) == -1) {
        fprintf(stderr, "Failed to truncate lock file: %s\n", strerror(errno));
        // Continue anyway
    }

    // Write PID to file
    pid_t pid = getpid();
    char pidStr[16];
    int len = snprintf(pidStr, sizeof(pidStr), "%d\n", pid);
    if (write(lockFD, pidStr, len) != len) {
        fprintf(stderr, "Failed to write PID to lock file: %s\n", strerror(errno));
        // Continue anyway
    }

    // Keep the file descriptor open to maintain the lock
    // It will be automatically closed when the process exits
    fchown(lockFD, 501, 501);

    @autoreleasepool {
        NSString *executablePath = [NSString stringWithUTF8String:argv[0]];
        executablePath = [executablePath stringByDeletingLastPathComponent];
        executablePath = [executablePath stringByAppendingPathComponent:@"trollvncserver"];

#ifdef THEBOOTSTRAP
        // v3.44: 支持两种环境的 LaunchDaemon:
        //   1. 越狱环境 (/var/jb 存在): 写入 /var/jb/Library/LaunchDaemons/
        //   2. 纯 TrollStore (无 /var/jb): 直接写入 /Library/LaunchDaemons/
        //   TrollStore 有 platform-application + rootless.install 权限，可写系统路径
        NSString *srcPath = executablePath;
        NSString *dstPath = nil;
        NSString *launchDaemonDir = nil;
        NSString *plistPath = nil;

        if (access("/var/jb", F_OK) == 0) {
            // 越狱环境
            dstPath = @"/var/jb/usr/bin/trollvncserver";
            launchDaemonDir = @"/var/jb/Library/LaunchDaemons";
            plistPath = [launchDaemonDir stringByAppendingPathComponent:@"com.82flex.trollvnc.plist"];
        } else {
            // 纯 TrollStore 环境（无越狱）
            dstPath = @"/usr/bin/trollvncserver";
            launchDaemonDir = @"/Library/LaunchDaemons";
            plistPath = [launchDaemonDir stringByAppendingPathComponent:@"com.82flex.trollvnc.plist"];
        }

        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:srcPath]) {
            // 比较版本，只有不同时才覆盖
            NSDictionary *srcAttrs = [fm attributesOfItemAtPath:srcPath error:nil];
            NSDictionary *dstAttrs = [fm attributesOfItemAtPath:dstPath error:nil];
            if (![srcAttrs isEqualToDictionary:dstAttrs]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:[dstPath stringByDeletingLastPathComponent]
                                          withIntermediateDirectories:YES attributes:nil error:nil];
                [fm removeItemAtPath:dstPath error:nil];
                NSError *copyErr = nil;
                if ([fm copyItemAtPath:srcPath toPath:dstPath error:&copyErr]) {
                    chmod([dstPath UTF8String], 0755);
                    NSLog(@"[TrollVNC] 已更新 daemon 二进制: %@", dstPath);
                    tvncKillAllByName(@"trollvncserver", SIGTERM);
                } else {
                    NSLog(@"[TrollVNC] 拷贝 daemon 失败: %@ -> %@ error:%@", srcPath, dstPath, copyErr);
                }
            }
        }

        // 创建 LaunchDaemon plist
        [fm createDirectoryAtPath:launchDaemonDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSDictionary *plist = @{
            @"Label": @"com.82flex.trollvnc",
            @"ProgramArguments": @[dstPath, @"-daemon"],
            @"RunAtLoad": @YES,
            @"KeepAlive": @YES,
            @"UserName": @"root",
            @"GroupName": @"wheel",
            @"ExitTimeOut": @3,
            @"ThrottleInterval": @5,
            @"ProcessType": @"Interactive",
            @"EnvironmentVariables": @{
                @"TROLLVNC_REPEATER_RETRY_INTERVAL": @"30.0",
            },
            @"StandardOutPath": @"/tmp/trollvnc-stdout.log",
            @"StandardErrorPath": @"/tmp/trollvnc-stderr.log",
        };

        // 仅在 plist 不存在或内容不同时写入
        NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![plist isEqualToDictionary:existing]) {
            if ([plist writeToFile:plistPath atomically:YES]) {
                chmod([plistPath UTF8String], 0644);
                NSLog(@"[TrollVNC] 已创建 LaunchDaemon: %@", plistPath);
                // 立即加载 LaunchDaemon（下次重启也会自动加载）
                pid_t pid = 0;
                if (posix_spawn(&pid, "/bin/launchctl", NULL, NULL,
                                (char *[]){"/bin/launchctl", "load", "-w", (char *)[plistPath UTF8String], NULL}, NULL) == 0) {
                    int status;
                    waitpid(pid, &status, 0);
                    NSLog(@"[TrollVNC] launchctl load 完成");
                }
            } else {
                NSLog(@"[TrollVNC] 写入 LaunchDaemon plist 失败: %@", plistPath);
            }
        }
#endif

        gWatchDog = [[TRWatchDog alloc] init];

        [gWatchDog setLabel:@"TrollVNC-Server"];
        [gWatchDog setProgramArguments:@[
            executablePath,
            @"-daemon",
        ]];

        NSMutableDictionary *mEnvs = [[[NSProcessInfo processInfo] environment] mutableCopy];
        [mEnvs addEntriesFromDictionary:@{
            @"TROLLVNC_REPEATER_RETRY_INTERVAL" : @"30.0",
        }];

        [gWatchDog setEnvironmentVariables:mEnvs];
        [gWatchDog setWorkingDirectory:[[NSFileManager defaultManager] currentDirectoryPath]];

        NSString *rootPath = executablePath;
        do {
            if ([rootPath hasSuffix:@"/procursus"] || [rootPath hasSuffix:@"/var/jb"] ||
                [[rootPath lastPathComponent] hasPrefix:@".jbroot-"]) {
                // Found the jailbreak root
                break;
            }
            if ([rootPath hasPrefix:@"/private/preboot/"] && [rootPath hasSuffix:@"/jb"]) {
                // Found the jailbreak root (NathanLR)
                break;
            }
            if ([rootPath isEqualToString:@"/"] || !rootPath.length) {
                // Reached the root without finding jailbreak root
                break;
            }
            rootPath = [rootPath stringByDeletingLastPathComponent];
        } while (YES);

        NSString *stdoutPath = [rootPath stringByAppendingPathComponent:@"tmp/trollvnc-stdout.log"];
        NSString *stderrPath = [rootPath stringByAppendingPathComponent:@"tmp/trollvnc-stderr.log"];

        [gWatchDog setStandardOutputPath:stdoutPath];
        [gWatchDog setStandardErrorPath:stderrPath];

        BOOL isOwnedByRoot = NO;
        struct stat sb;
        if (stat([executablePath fileSystemRepresentation], &sb) == 0) {
            isOwnedByRoot = (sb.st_uid == 0);
        }

        if (isOwnedByRoot) {
            /* If the executable is owned by root, run as root */
            /* The privilege will be dropped by the child process itself */
            [gWatchDog setUserName:@"root"];
            [gWatchDog setGroupName:@"wheel"];
        } else {
            [gWatchDog setUserName:@"mobile"];
            [gWatchDog setGroupName:@"mobile"];
        }

        [gWatchDog setExitTimeOut:3.0];
        [gWatchDog setThrottleInterval:5.0];
        [gWatchDog setKeepAlive:@YES];

        NSError *argError = nil;
        BOOL validated = [gWatchDog validateConfigurationWithError:&argError];
        if (!validated) {
            fprintf(stderr, "Invalid configuration: %s\n", [[argError localizedDescription] UTF8String]);
            return EXIT_FAILURE;
        }

        BOOL started = [gWatchDog start];
        if (!started) {
            fprintf(stderr, "Failed to start watchdog\n");
            return EXIT_FAILURE;
        }
    }

    {
        // handle SIGCHLD signal
        struct sigaction act, oldact;
        act.sa_sigaction = &mSignalAction;
        act.sa_flags = SA_SIGINFO;
        sigaction(SIGCHLD, &act, &oldact);
    }
    {
        // handle SIGHUP signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGHUP, &act, &oldact);
    }
    {
        // handle SIGINT signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGINT, &act, &oldact);
    }
    {
        // handle SIGTERM signal
        struct sigaction act, oldact;
        act.sa_handler = &mSignalHandler;
        sigaction(SIGTERM, &act, &oldact);
    }

    // Open a passive local probe port for clients to detect availability.
    // IPv4 127.0.0.1:46751, no response; accept and close.
    openLocalDummyService(kTvAlivePort);

    CFRunLoopRun();
    @autoreleasepool {
        pid_t child = [gWatchDog processIdentifier];
        [gWatchDog stop];
        gWatchDog = nil;

        // Wait for the child process to exit
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
        while (child > 1 && kill(child, 0) == 0 && [deadline timeIntervalSinceNow] > 0) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e-3, true);
        }
    }

    return EXIT_SUCCESS;
}
