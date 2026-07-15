// TVNCProcessInject.m
// 进程内注入：把 tvnc_inject.dylib 注入前台目标 App 进程并调用其导出函数。
// 仅用 mach API（守护进程无 UIKit）。详细实现见头文件注释。

#import "TVNCProcessInject.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/thread_status.h>
#import <mach/arm/thread_status.h>
#import <sys/types.h>
#import <stdint.h>
#import <sys/sysctl.h>
#import <libproc.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iOS SDK 不提供 <mach/mach_vm.h> 头（符号在 libsystem_kernel 里但无声明），
// 手动 extern 声明我们用到的三个 mach_vm_* 函数，避免隐式声明编译错误。
#ifdef __cplusplus
extern "C" {
#endif
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t dataCnt);
#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif
// AX 私有框架动态解析（取前台 App PID 用）
typedef CFTypeRef AXUIElementRef;
typedef uint32_t AXError;
typedef AXUIElementRef (*TVNC_AXCreateSystemWide)(void);
typedef AXError (*TVNC_AXCopyAttr)(AXUIElementRef, CFStringRef, CFTypeRef *);
typedef AXError (*TVNC_AXGetPid)(AXUIElementRef, pid_t *);
#ifdef __cplusplus
}
#endif

#define TVNC_RTLD_NOW 0x2

#pragma mark - 目标进程内存读写

// 从目标 task 读 len 字节，返回 malloc 缓冲（调用方 free）。失败返回 NULL。
static void *tvnc_read(task_t task, uint64_t addr, size_t len, size_t *outLen) {
    if (len == 0 || addr == 0) return NULL;
    void *buf = malloc(len);
    if (!buf) return NULL;
    mach_vm_size_t out = 0;
    kern_return_t kr = vm_read_overwrite(task, addr, len, (mach_vm_address_t)buf, &out);
    if (kr != KERN_SUCCESS) { free(buf); return NULL; }
    if (outLen) *outLen = (size_t)out;
    return buf;
}

// 在目标 task 分配 size 字节，返回地址；失败返回 0。
static uint64_t tvnc_alloc(task_t task, size_t size) {
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(task, &addr, size, VM_FLAGS_ANYWHERE);
    return (kr == KERN_SUCCESS) ? (uint64_t)addr : 0;
}

// 向目标 task 写入数据（data 为本进程缓冲）。
static BOOL tvnc_write(task_t task, uint64_t addr, const void *data, size_t len) {
    kern_return_t kr = mach_vm_write(task, addr, (vm_offset_t)data, (mach_msg_type_number_t)len);
    return kr == KERN_SUCCESS;
}

// 在目标 task 写入 C 字符串，返回其地址（含结尾 \0）。
static uint64_t tvnc_write_cstr(task_t task, const char *s) {
    size_t len = strlen(s) + 1;
    uint64_t addr = tvnc_alloc(task, len);
    if (!addr) return 0;
    if (!tvnc_write(task, addr, s, len)) return 0;
    return addr;
}

// 在目标 task 释放内存。
static void tvnc_dealloc(task_t task, uint64_t addr, size_t size) {
    if (addr) mach_vm_deallocate(task, addr, size);
}

#pragma mark - 在目标进程内执行一次函数（pc + x0/x1），挂起后回收 x0

// 于目标 task 创建一个线程，pc 指向目标内函数，x0/x1 为参数，lr 指向死循环蹦床。
// 运行一小段后挂起线程，读出 x0（返回值），再终止线程。
// 为提升稳定性，x18（平台指针）从目标已有线程拷贝，避免 dlopen 内部依赖 x18 时崩溃。
static kern_return_t tvnc_call_in_task(task_t task,
                                       uint64_t pc, uint64_t x0, uint64_t x1,
                                       uint64_t sp, uint64_t lr,
                                       uint64_t *out_x0) {
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    state.__pc = (uint64_t)pc;
    state.__x[0] = (uint64_t)x0;
    state.__x[1] = (uint64_t)x1;
    state.__x[29] = (uint64_t)sp;   // fp
    state.__sp = (uint64_t)sp;
    state.__lr = (uint64_t)lr;

    // 从目标已有线程拷贝 x18（平台指针），让注入线程看起来像正常线程
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t tcnt = 0;
    if (task_threads(task, &threads, &tcnt) == KERN_SUCCESS && tcnt > 0) {
        arm_thread_state64_t seed;
        mach_msg_type_number_t scnt = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(threads[0], ARM_THREAD_STATE64, (thread_state_t)&seed, &scnt) == KERN_SUCCESS) {
            state.__x[18] = seed.__x[18];
        }
        for (mach_msg_type_number_t i = 0; i < tcnt; i++) mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads, tcnt * sizeof(thread_act_t));
    }

    thread_act_t thr = MACH_PORT_NULL;
    kern_return_t kr = thread_create_running(task, ARM_THREAD_STATE64,
                                             (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thr);
    if (kr != KERN_SUCCESS) return kr;

    // 等待函数执行完毕（pc 回到蹦床 lr 即表示已返回），最多重试若干次
    uint64_t retval = 0;
    BOOL settled = NO;
    for (int attempt = 0; attempt < 50 && !settled; attempt++) {
        usleep(20000);
        thread_suspend(thr);
        arm_thread_state64_t out;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        thread_get_state(thr, ARM_THREAD_STATE64, (thread_state_t)&out, &cnt);
        retval = out.__x[0];
        if (out.__pc == lr) settled = YES;  // 已返回到蹦床
        else thread_resume(thr);
    }
    if (out_x0) *out_x0 = retval;
    thread_terminate(thr);
    return KERN_SUCCESS;
}

#pragma mark - 前台 App PID

// 从 SBApplication 取进程号（兼容 processIdentifier / pid 两种属性名）。
// 用 NSInvocation 运行时调用，避免直接 [app processIdentifier] 与 SDK 中同名方法产生编译期歧义。
static pid_t tvnc_pid_from_sbapp(id app) {
    if (!app) return -1;
    SEL sel = @selector(processIdentifier);
    if (![app respondsToSelector:sel]) {
        sel = @selector(pid);
        if (![app respondsToSelector:sel]) return -1;
    }
    NSMethodSignature *sig = [app methodSignatureForSelector:sel];
    if (!sig || sig.methodReturnLength == 0) return -1;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv invokeWithTarget:app];
    int val = 0;
    [inv getReturnValue:&val]; // processIdentifier/pid 均返回 32 位整数
    return (pid_t)val;
}

// 通过 sysctl 枚举进程 + 读 .app Info.plist，将 bundle id 映射到 pid
static int tvnc_pid_for_bundle(NSString *bundleId) {
    if (!bundleId.length) return -1;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) { free(procs); return -1; }
    int count = (int)(size / sizeof(struct kinfo_proc));
    int found = -1;
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0) continue;
        int ret = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
        if (ret <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:pathbuf];
        NSRange r = [path rangeOfString:@".app/"];
        if (r.location == NSNotFound) continue;
        NSString *appDir = [path substringToIndex:r.location + r.length - 1];
        NSString *plist = [appDir stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
        if (info && [bundleId isEqualToString:info[@"CFBundleIdentifier"]]) {
            found = (int)pid;
            break;
        }
    }
    free(procs);
    return found;
}

// 通过 SpringBoardServices 取前台 App PID（无需辅助功能授权，daemon 可用）
// 返回 >0 成功；<=0 失败。
static int tvnc_foreground_pid_springboard(void) {
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!sbs) return -1;
    int pid = -1;

    // 1) SBFrontmostApplication() -> SBApplication -> processIdentifier
    id (*sbFrontmost)(void) = (id (*)(void))dlsym(sbs, "SBFrontmostApplication");
    if (sbFrontmost) {
        pid = (int)tvnc_pid_from_sbapp(sbFrontmost());
        if (pid > 0) { dlclose(sbs); return pid; }
    }

    // 2) SBFrontmostApplicationBundleIdentifier() -> 反查进程
    NSString *(*sbFrontBid)(void) = (NSString *(*)(void))dlsym(sbs, "SBFrontmostApplicationBundleIdentifier");
    NSString *bid = sbFrontBid ? sbFrontBid() : nil;
    if (bid.length) {
        pid = tvnc_pid_for_bundle(bid);
        if (pid > 0) { dlclose(sbs); return pid; }
    }

    dlclose(sbs);
    return pid;
}

// AX 兜底（仅桌面 / 已授权辅助功能的环境可用）
static int tvnc_foreground_pid_ax(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/Frameworks/Accessibility.framework/Accessibility", RTLD_LAZY);
    if (!h) return -1;
    TVNC_AXCreateSystemWide createSystemWide = (TVNC_AXCreateSystemWide)dlsym(h, "AXUIElementCreateSystemWide");
    TVNC_AXCopyAttr copyAttr = (TVNC_AXCopyAttr)dlsym(h, "AXUIElementCopyAttributeValue");
    TVNC_AXGetPid getPid = (TVNC_AXGetPid)dlsym(h, "AXUIElementGetPid");
    if (!createSystemWide || !copyAttr || !getPid) { dlclose(h); return -1; }

    AXUIElementRef sys = createSystemWide();
    if (!sys) { dlclose(h); return -1; }
    CFTypeRef appRef = NULL;
    AXError e = copyAttr(sys, CFSTR("AXFocusedApplication"), &appRef);
    int pid = -1;
    if (e == 0 && appRef) {
        pid_t p = -1;
        getPid((AXUIElementRef)appRef, &p);
        pid = (int)p;
        CFRelease(appRef);
    }
    CFRelease(sys);
    dlclose(h);
    return pid;
}

// 通过 FrontBoardServices 取前台 App PID（走 backboardd XPC，daemon 下比 SpringBoard XPC 更可靠）
// 返回 >0 成功；<=0 失败。
static int tvnc_foreground_pid_fbs(void) {
    Class FBSWS = NSClassFromString(@"FBSApplicationWorkspace");
    if (!FBSWS) FBSWS = NSClassFromString(@"FBApplicationWorkspace");
    if (!FBSWS) FBSWS = NSClassFromString(@"SBApplicationWorkspace");
    if (!FBSWS) return -1;
    SEL dw = NSSelectorFromString(@"defaultWorkspace");
    if (![FBSWS respondsToSelector:dw]) return -1;
    id ws = ((id (*)(id, SEL))objc_msgSend)(FBSWS, dw);
    SEL ra = NSSelectorFromString(@"runningApplications");
    if (!ws || ![ws respondsToSelector:ra]) return -1;
    NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, ra);
    if (!apps.count) return -1;

    id best = nil;
    int bestScore = -1;
    BOOL (*msgB)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
    for (id a in apps) {
        int score = 0;
        if ([a respondsToSelector:NSSelectorFromString(@"visibility")]) {
            score = [[a valueForKey:@"visibility"] intValue] * 10;
        }
        if ([a respondsToSelector:NSSelectorFromString(@"isActive")] &&
            msgB(a, NSSelectorFromString(@"isActive"))) score += 5;
        if ([a respondsToSelector:NSSelectorFromString(@"isForeground")] &&
            msgB(a, NSSelectorFromString(@"isForeground"))) score += 3;
        if (score > bestScore) { bestScore = score; best = a; }
    }
    if (!best || bestScore <= 0) return -1;

    // 取 PID（兼容 processIdentifier / pid）
    SEL sel = @selector(processIdentifier);
    if (![best respondsToSelector:sel]) sel = @selector(pid);
    if (![best respondsToSelector:sel]) return -1;
    NSMethodSignature *sig = [best methodSignatureForSelector:sel];
    if (!sig) return -1;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv invokeWithTarget:best];
    int v = 0;
    [inv getReturnValue:&v];
    return v > 0 ? v : -1;
}

// 综合取前台 PID：FrontBoard 优先（daemon 可用且最稳），其次 SpringBoard XPC，AX 兜底
static int tvnc_foreground_pid(void) {
    int pid = tvnc_foreground_pid_fbs();
    if (pid > 0) return pid;
    pid = tvnc_foreground_pid_springboard();
    if (pid > 0) return pid;
    return tvnc_foreground_pid_ax();
}

#pragma mark - 目标进程符号解析

// dyld_all_image_infos（64 位布局，字段偏移按版本递增）
struct tvnc_dyld_all_image_infos {
    uint32_t version;
    uint32_t infoArrayCount;
    uint64_t infoArray;
    uint64_t notification;
    uint64_t processDetachedFromSharedRegion;
    uint64_t libSystemInitialized;
    uint64_t dyldImageLoadAddress;
    uint64_t sharedCacheBaseAddress; // version >= 13 存在
};

struct tvnc_dyld_image_info {
    uint64_t imageLoadAddress;
    uint64_t imageFilePath;
    uint64_t imageFileModDate;
};

struct tvnc_nlist_64 {
    uint32_t n_strx;
    uint8_t  n_type;
    uint8_t  n_sect;
    uint16_t n_desc;
    uint64_t n_value;
};

// 在目标某镜像（imageLoadAddress，其符号位于共享缓存，基址 cacheBase）中查找符号 symname，
// 返回绝对地址；找不到返回 0。
static uint64_t tvnc_resolve_symbol(task_t task, uint64_t cacheBase,
                                     uint64_t imageLoadAddress, const char *symname) {
    // 读 mach_header_64
    struct mach_header_64 {
        uint32_t magic;
        uint32_t cputype;
        uint32_t cpusubtype;
        uint32_t filetype;
        uint32_t ncmds;
        uint32_t sizeofcmds;
        uint32_t flags;
        uint32_t reserved;
    } hdr;
    size_t got = 0;
    void *hdrBuf = tvnc_read(task, imageLoadAddress, sizeof(hdr), &got);
    if (!hdrBuf) return 0;
    memcpy(&hdr, hdrBuf, sizeof(hdr));
    free(hdrBuf);
    if (hdr.magic != 0xcffaedfe && hdr.magic != 0xcafebabe) {
        // 尝试字节序翻转（小端的 0xfeedfacf）
        if (hdr.magic != 0xfeedfacf) return 0;
    }

    // 遍历 load commands
    uint64_t lcOff = imageLoadAddress + sizeof(hdr);
    uint32_t lc_cmd = 0, lc_cmdsize = 0;
    uint64_t symoff = 0, stroff = 0;
    uint32_t nsyms = 0;
    BOOL found = NO;
    for (uint32_t i = 0; i < hdr.ncmds; i++) {
        void *lc = tvnc_read(task, lcOff, 8, NULL);
        if (!lc) break;
        memcpy(&lc_cmd, lc, 4);
        memcpy(&lc_cmdsize, (uint8_t*)lc + 4, 4);
        free(lc);
        if (lc_cmd == 0x2) { // LC_SYMTAB
            void *sc = tvnc_read(task, lcOff, 24, NULL);
            if (!sc) break;
            // LC_SYMTAB: cmd(4) cmdsize(4) symoff(4) nsyms(4) stroff(4) strsize(4)
            uint32_t *p = (uint32_t*)sc;
            symoff = p[2];
            nsyms   = p[3];
            stroff  = p[4];
            free(sc);
            found = YES;
            break;
        }
        lcOff += lc_cmdsize;
    }
    if (!found || nsyms == 0) return 0;

    size_t symSize = (size_t)nsyms * sizeof(struct tvnc_nlist_64);
    void *syms = tvnc_read(task, imageLoadAddress + symoff, symSize, NULL);
    if (!syms) return 0;
    void *strs = tvnc_read(task, imageLoadAddress + stroff, 1 << 20, NULL); // 字符串表上限 1MB
    if (!strs) { free(syms); return 0; }

    uint64_t result = 0;
    struct tvnc_nlist_64 *nl = (struct tvnc_nlist_64 *)syms;
    for (uint32_t i = 0; i < nsyms; i++) {
        if ((nl[i].n_type & 0x0e) == 0x0e) continue; // STAB
        if (nl[i].n_strx == 0) continue;
        const char *name = (const char*)strs + nl[i].n_strx;
        if (strcmp(name, symname) == 0) {
            // 共享缓存内符号的 n_value 相对缓存基址
            result = cacheBase + nl[i].n_value;
            break;
        }
    }
    free(syms);
    free(strs);
    return result;
}

// 遍历目标所有镜像，找到 libSystem，解析出 dlopen / dlsym 地址。
static BOOL tvnc_find_libsystem_symbols(task_t task, uint64_t *out_dlopen, uint64_t *out_dlsym) {
    // 取 dyld info
    struct task_dyld_info dyld_info;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &cnt) != KERN_SUCCESS) return NO;
    uint64_t infoAddr = (uint64_t)dyld_info.all_image_info_addr;
    if (infoAddr == 0) return NO;

    struct tvnc_dyld_all_image_infos infos;
    size_t igot = 0;
    void *ib = tvnc_read(task, infoAddr, sizeof(infos), &igot);
    if (!ib) return NO;
    memcpy(&infos, ib, sizeof(infos));
    free(ib);
    if (infos.infoArrayCount == 0 || infos.infoArray == 0) return NO;

    uint64_t cacheBase = infos.sharedCacheBaseAddress;
    // 老版本无 sharedCacheBaseAddress 字段时，用首个镜像基址近似（缓存符号需真实缓存基址）
    if (cacheBase == 0 && infos.version >= 13) return NO;

    size_t arrSize = (size_t)infos.infoArrayCount * sizeof(struct tvnc_dyld_image_info);
    void *arr = tvnc_read(task, infos.infoArray, arrSize, NULL);
    if (!arr) return NO;

    struct tvnc_dyld_image_info *images = (struct tvnc_dyld_image_info *)arr;
    BOOL ok = NO;
    for (uint32_t i = 0; i < infos.infoArrayCount; i++) {
        uint64_t pathPtr = images[i].imageFilePath;
        if (!pathPtr) continue;
        char path[256];
        memset(path, 0, sizeof(path));
        void *pb = tvnc_read(task, pathPtr, sizeof(path) - 1, NULL);
        if (!pb) continue;
        memcpy(path, pb, sizeof(path) - 1);
        free(pb);
        // 匹配 libSystem / libsystem（dlopen/dlsym 所在）
        if (strstr(path, "libSystem") || strstr(path, "libsystem")) {
            uint64_t dlopen = tvnc_resolve_symbol(task, cacheBase, images[i].imageLoadAddress, "dlopen");
            uint64_t dlsym  = tvnc_resolve_symbol(task, cacheBase, images[i].imageLoadAddress, "dlsym");
            if (dlopen && dlsym) {
                *out_dlopen = dlopen;
                *out_dlsym = dlsym;
                ok = YES;
                break;
            }
        }
    }
    free(arr);
    return ok;
}

#pragma mark - dylib 路径

static NSString *tvnc_dylib_path(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 基础路径候选：覆盖 jailbreak(/usr/lib)、TrollStore rootless(/var/jb/usr/lib)、
    // 应用自身(.app 内，rootless 系统卷不可写 /usr/lib 时的最可靠落点)。
    NSArray *bases = @[
        @"/usr/lib",
        @"/var/jb/usr/lib",
        @"/Applications/MatisuXCS.app",
        @"/var/jb/Applications/MatisuXCS.app",
        @"/Applications/TrollVNC.app",
        @"/var/jb/Applications/TrollVNC.app",
    ];
    // theos library.mk 产物名可能带 lib 前缀，两种都试
    NSArray *names = @[ @"tvnc_inject.dylib", @"libtvnc_inject.dylib" ];
    for (NSString *base in bases) {
        for (NSString *name in names) {
            NSString *p = [base stringByAppendingPathComponent:name];
            if ([fm fileExistsAtPath:p]) return p;
        }
    }
    // 最后：daemon 自身的 mainBundle（.tipa 方案 daemon 就位于 .app 内，最稳）
    for (NSString *name in names) {
        NSString *b = [[NSBundle mainBundle] pathForResource:[name stringByDeletingPathExtension]
                                                       ofType:[name pathExtension]];
        if (b && [fm fileExistsAtPath:b]) return b;
    }
    return nil;
}

#pragma mark - 候选 App 枚举（不依赖前台检测）

// 枚举所有“用户 App”进程 PID（不含守护进程自身、同 .app 的 manager、SpringBoard、系统守护）。
// 用于不依赖前台检测即可实施注入：对全部候选 App 注入，仅前台 App 的 tvnc_inject_text 会真正生效。
static void tvnc_enumerate_user_apps(NSMutableArray *outPids) {
    NSString *selfBundle = [[NSBundle mainBundle] bundlePath]; // .../MatisuXCS.app
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0) return;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    if (sysctl(mib, 3, procs, &size, NULL, 0) != 0) { free(procs); return; }
    int count = (int)(size / sizeof(struct kinfo_proc));
    pid_t selfPid = getpid();
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0 || pid == selfPid) continue;
        int ret = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
        if (ret <= 0) continue;
        NSString *path = [NSString stringWithUTF8String:pathbuf];
        // 仅保留 .app 内可执行（用户/系统 App），排除 /System、/usr、/sbin 下的系统守护
        NSRange ar = [path rangeOfString:@".app/"];
        if (ar.location == NSNotFound) continue;
        if ([path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/"] ||
            [path hasPrefix:@"/sbin/"] || [path hasPrefix:@"/private/var/db/"]) continue;
        if ([path containsString:@"/CoreServices/SpringBoard.app/"]) continue;
        // 排除守护进程自身及同 .app 的 manager
        NSString *appDir = [path substringToIndex:ar.location + ar.length - 1];
        if ([appDir isEqualToString:selfBundle]) continue;
        [outPids addObject:@(pid)];
    }
    free(procs);
}

// 对单个目标进程执行完整注入（task_for_pid + 进程内 dlopen/dlsym/tvnc_inject_text）。
// 返回 tvnc_inject_text 的 BOOL 结果（YES=成功写入文本）。diag 记录该 pid 的诊断。
static BOOL tvnc_inject_into_pid(pid_t pid, NSString *dylibPath, NSString *text, NSMutableDictionary *diag) {
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        diag[@"task_for_pid"] = [NSString stringWithFormat:@"kr=%d", (int)kr];
        return NO;
    }
    uint64_t dlopenAddr = 0, dlsymAddr = 0;
    if (!tvnc_find_libsystem_symbols(task, &dlopenAddr, &dlsymAddr)) {
        diag[@"symbol_resolve"] = @"fail";
        mach_port_deallocate(mach_task_self(), task);
        return NO;
    }
    uint64_t pathAddr = tvnc_write_cstr(task, [dylibPath UTF8String]);
    uint64_t fnNameAddr = tvnc_write_cstr(task, "tvnc_inject_text");
    uint64_t textAddr = tvnc_write_cstr(task, [text UTF8String]);
    uint64_t tramp = tvnc_alloc(task, 16);
    if (tramp) { uint32_t trap = 0x14000000; tvnc_write(task, tramp, &trap, 4); }
    uint64_t stack = tvnc_alloc(task, 0x4000);
    uint64_t sp = stack ? (stack + 0x4000 - 16) : 0;
    BOOL ok = NO;
    if (!pathAddr || !fnNameAddr || !textAddr || !tramp || !stack) {
        diag[@"alloc"] = @"fail";
        goto cleanup_inject;
    }
    uint64_t handle = 0;
    kr = tvnc_call_in_task(task, dlopenAddr, pathAddr, TVNC_RTLD_NOW, sp, tramp, &handle);
    if (kr != KERN_SUCCESS || handle == 0) { diag[@"dlopen"] = [NSString stringWithFormat:@"kr=%d,handle=%llu",(int)kr,handle]; goto cleanup_inject; }
    uint64_t fn = 0;
    kr = tvnc_call_in_task(task, dlsymAddr, handle, fnNameAddr, sp, tramp, &fn);
    if (kr != KERN_SUCCESS || fn == 0) { diag[@"dlsym"] = [NSString stringWithFormat:@"kr=%d,fn=%llu",(int)kr,fn]; goto cleanup_inject; }
    uint64_t ret = 0;
    kr = tvnc_call_in_task(task, fn, textAddr, 0, sp, tramp, &ret);
    if (kr != KERN_SUCCESS) { diag[@"inject_call"] = [NSString stringWithFormat:@"kr=%d",(int)kr]; goto cleanup_inject; }
    ok = (ret != 0);
    diag[@"injected"] = ok ? @"yes" : @"no";

cleanup_inject:
    if (pathAddr) tvnc_dealloc(task, pathAddr, strlen([dylibPath UTF8String])+1);
    if (fnNameAddr) tvnc_dealloc(task, fnNameAddr, strlen("tvnc_inject_text")+1);
    if (textAddr) tvnc_dealloc(task, textAddr, strlen([text UTF8String])+1);
    if (tramp) tvnc_dealloc(task, tramp, 16);
    if (stack) tvnc_dealloc(task, stack, 0x4000);
    mach_port_deallocate(mach_task_self(), task);
    return ok;
}

#pragma mark - 公开接口

@implementation TVNCProcessInject

+ (NSDictionary *)probe {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    NSMutableArray *cands = [NSMutableArray array];
    tvnc_enumerate_user_apps(cands);
    r[@"candidate_apps"] = @(cands.count);
    // 仍尝试一次精确前台检测，作为诊断参考（失败时不影响通道可用性）
    int fg = tvnc_foreground_pid();
    if (fg > 0) r[@"foreground_pid_guess"] = @(fg);
    if (cands.count == 0) {
        r[@"status"] = @"error";
        r[@"stage"] = @"enumerate";
        r[@"error"] = @"未枚举到任何用户 App 进程（确认有 App 处于前台/后台运行，且守护进程有 task_for_pid 权限）";
        return r;
    }
    // 取第一个候选验证 task_for_pid 通道
    pid_t pid = [cands.firstObject intValue];
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        r[@"status"] = @"error";
        r[@"stage"] = @"task_for_pid";
        r[@"tried_pid"] = @(pid);
        r[@"error"] = [NSString stringWithFormat:@"task_for_pid 失败 (kr=%d)。确认 entitlements 含 task_for_pid-allow，且目标与守护进程同为 mobile 用户", (int)kr];
        return r;
    }
    r[@"status"] = @"ok";
    r[@"stage"] = @"task_for_pid";
    r[@"task_acquired"] = @YES;
    r[@"verified_pid"] = @(pid);
    r[@"message"] = @"task_for_pid 通道已打通；注入将对全部候选 App 尝试，仅前台 App 会真正写入文本（不再依赖前台 PID 检测）";
    mach_port_deallocate(mach_task_self(), task);
    return r;
}

+ (NSDictionary *)injectText:(NSString *)text {
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    if (!text || text.length == 0) {
        r[@"status"] = @"error";
        r[@"error"] = @"Empty text";
        return r;
    }
    NSString *dylibPath = tvnc_dylib_path();
    if (!dylibPath) {
        r[@"status"] = @"error";
        r[@"stage"] = @"dylib_path";
        r[@"error"] = @"找不到 tvnc_inject.dylib（打包未包含或路径不符）";
        return r;
    }
    r[@"dylib"] = dylibPath;

    // 候选 PID：先尝试精确前台检测（FBS/SBS/AX），再把全部用户 App 纳入兜底。
    // 核心：不依赖前台检测也能工作——对全部候选注入，仅前台 App 的 tvnc_inject_text 生效。
    NSMutableArray *pids = [NSMutableArray array];
    int fg = tvnc_foreground_pid();
    if (fg > 0) [pids addObject:@(fg)];
    NSMutableArray *cands = [NSMutableArray array];
    tvnc_enumerate_user_apps(cands);
    for (NSNumber *p in cands) {
        if (![pids containsObject:p]) [pids addObject:p];
    }
    r[@"candidate_count"] = @(pids.count);
    if (pids.count == 0) {
        r[@"status"] = @"error";
        r[@"stage"] = @"enumerate";
        r[@"error"] = @"未枚举到任何用户 App 进程（确认有 App 运行）";
        return r;
    }

    NSMutableArray *details = [NSMutableArray array];
    BOOL anyInjected = NO;
    for (NSNumber *p in pids) {
        pid_t pid = [p intValue];
        NSMutableDictionary *diag = [NSMutableDictionary dictionary];
        diag[@"pid"] = p;
        BOOL ok = tvnc_inject_into_pid(pid, dylibPath, text, diag);
        diag[@"result"] = ok ? @"injected" : @"skip";
        if (ok) anyInjected = YES;
        [details addObject:diag];
        if (anyInjected) break; // 已成功写入，无需再试
    }
    r[@"details"] = details;
    if (anyInjected) {
        r[@"status"] = @"ok";
        r[@"injected"] = @YES;
    } else {
        r[@"status"] = @"fail";
        r[@"injected"] = @NO;
        r[@"error"] = @"所有候选 App 注入后 tvnc_inject_text 均返回 NO（前台 App 当前无焦点输入框，或该 App 完全未接系统文本输入）";
    }
    return r;
}

@end
