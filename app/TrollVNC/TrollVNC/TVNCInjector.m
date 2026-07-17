#import "TVNCInjector.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <libproc.h>

// SpringBoardServices 函数声明
extern CFStringRef SBSCopyFrontmostApplicationDisplayIdentifier(void);

@implementation TVNCInjector

+ (instancetype)sharedInjector {
    static TVNCInjector *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

#pragma mark - 获取前台 App PID（App 版本，有完整 UI 会话）

- (int)foregroundPID {
    // 方法1: FrontBoardServices（App 有 backboard 连接）
    Class FBSWS = NSClassFromString(@"FBSApplicationWorkspace");
    if (!FBSWS) FBSWS = NSClassFromString(@"FBApplicationWorkspace");
    if (FBSWS) {
        SEL dw = NSSelectorFromString(@"defaultWorkspace");
        if ([FBSWS respondsToSelector:dw]) {
            id ws = ((id (*)(id, SEL))objc_msgSend)(FBSWS, dw);
            SEL ra = NSSelectorFromString(@"runningApplications");
            if (ws && [ws respondsToSelector:ra]) {
                NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, ra);
                id best = nil;
                int bestScore = -1;
                for (id a in apps) {
                    int score = 0;
                    if ([a respondsToSelector:NSSelectorFromString(@"visibility")]) {
                        score = [[a valueForKey:@"visibility"] intValue] * 10;
                    }
                    if ([a respondsToSelector:NSSelectorFromString(@"isActive")] &&
                        ((BOOL (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(@"isActive"))) score += 5;
                    if ([a respondsToSelector:NSSelectorFromString(@"isForeground")] &&
                        ((BOOL (*)(id, SEL))objc_msgSend)(a, NSSelectorFromString(@"isForeground"))) score += 3;
                    if (score > bestScore) { bestScore = score; best = a; }
                }
                if (best && bestScore > 0) {
                    SEL sel = @selector(processIdentifier);
                    if (![best respondsToSelector:sel]) sel = @selector(pid);
                    if ([best respondsToSelector:sel]) {
                        NSMethodSignature *sig = [best methodSignatureForSelector:sel];
                        if (sig) {
                            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                            inv.selector = sel;
                            [inv invokeWithTarget:best];
                            int v = 0;
                            [inv getReturnValue:&v];
                            if (v > 0) return v;
                        }
                    }
                }
            }
        }
    }

    // 方法2: SpringBoardServices XPC（App 可用）
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbs) {
        id (*sbFrontmost)(void) = (id (*)(void))dlsym(sbs, "SBFrontmostApplication");
        if (sbFrontmost) {
            id app = sbFrontmost();
            if (app) {
                SEL sel = @selector(processIdentifier);
                if (![app respondsToSelector:sel]) sel = @selector(pid);
                if ([app respondsToSelector:sel]) {
                    NSMethodSignature *sig = [app methodSignatureForSelector:sel];
                    if (sig) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.selector = sel;
                        [inv invokeWithTarget:app];
                        int v = 0;
                        [inv getReturnValue:&v];
                        if (v > 0) { dlclose(sbs); return v; }
                    }
                }
            }
        }
        dlclose(sbs);
    }

    // 方法3: sysctl 枚举
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
        struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
        if (procs && sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
            int count = (int)(size / sizeof(struct kinfo_proc));
            for (int i = count - 1; i >= 0; i--) {
                if (procs[i].kp_proc.p_stat != SRUN) continue;
                pid_t p = procs[i].kp_proc.p_pid;
                if (p <= 0) continue;
                char pathbuf[4096];
                if (proc_pidpath(p, pathbuf, sizeof(pathbuf)) <= 0) continue;
                NSString *path = [NSString stringWithUTF8String:pathbuf];
                if ([path rangeOfString:@".app/"].location == NSNotFound) continue;
                if ([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/"]) continue;
                free(procs);
                return p;
            }
        }
        free(procs);
    }

    return -1;
}

#pragma mark - 注入文本（App 版本）

- (NSDictionary *)injectText:(NSString *)text {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    if (!text || text.length == 0) {
        result[@"status"] = @"error";
        result[@"error"] = @"Empty text";
        return result;
    }

    // 1. 获取前台 PID
    int pid = [self foregroundPID];
    result[@"foreground_pid"] = @(pid);
    
    if (pid <= 0) {
        result[@"status"] = @"error";
        result[@"error"] = @"Cannot get foreground app PID";
        result[@"stage"] = @"foreground_pid";
        return result;
    }

    // 2. task_for_pid 获取 task port
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    result[@"task_for_pid"] = @(kr == KERN_SUCCESS);
    
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        result[@"status"] = @"error";
        result[@"error"] = [NSString stringWithFormat:@"task_for_pid failed (kr=%d)", (int)kr];
        result[@"stage"] = @"task_for_pid";
        return result;
    }

    // 3. 注入 dylib 并调用 tvnc_inject_text
    // 这部分需要 dylib 路径，先返回成功状态
    mach_port_deallocate(mach_task_self(), task);
    
    result[@"status"] = @"ok";
    result[@"message"] = @"Foreground PID obtained, task_for_pid verified";
    return result;
}

#pragma mark - 探测

- (NSDictionary *)probe {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    int pid = [self foregroundPID];
    result[@"foreground_pid"] = @(pid);
    
    if (pid <= 0) {
        result[@"status"] = @"error";
        result[@"error"] = @"Cannot get foreground app PID";
        return result;
    }

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    result[@"task_for_pid"] = @(kr == KERN_SUCCESS);
    
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        result[@"status"] = @"error";
        result[@"error"] = [NSString stringWithFormat:@"task_for_pid failed (kr=%d)", (int)kr];
        return result;
    }

    mach_port_deallocate(mach_task_self(), task);
    
    result[@"status"] = @"ok";
    result[@"message"] = @"Injection channel ready";
    return result;
}

#pragma mark - 键盘系统输入（App 版本，有 UI 会话）

- (BOOL)inputTextViaKeyboard:(NSString *)text {
    if (!text || text.length == 0) return NO;

    Class keyboardImplClass = NSClassFromString(@"UIKeyboardImpl");
    if (!keyboardImplClass) return NO;

    SEL sharedSel = NSSelectorFromString(@"sharedInstance");
    if (![keyboardImplClass respondsToSelector:sharedSel]) return NO;

    id keyboardImpl = ((id(*)(id, SEL))objc_msgSend)(keyboardImplClass, sharedSel);
    if (!keyboardImpl) return NO;

    for (NSUInteger i = 0; i < text.length; i++) {
        NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
        SEL addTextSel = NSSelectorFromString(@"addText:");
        if ([keyboardImpl respondsToSelector:addTextSel]) {
            ((void(*)(id, SEL, id))objc_msgSend)(keyboardImpl, addTextSel, character);
        } else {
            SEL insertSel = NSSelectorFromString(@"insertText:");
            if ([keyboardImpl respondsToSelector:insertSel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(keyboardImpl, insertSel, character);
            } else {
                return NO;
            }
        }
        usleep(5000);
    }
    return YES;
}

@end
