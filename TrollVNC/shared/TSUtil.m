#import <Foundation/Foundation.h>
#import <spawn.h>

#ifdef __cplusplus
extern "C" {
#endif

// 手动声明 persona API（iOS 私有 API，SDK 不含）
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict attr, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict attr, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict attr, gid_t gid);

#ifndef POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
#endif

// MARK: - spawnRoot
// 以 root 身份执行命令

// 直接使用 posix_spawn 执行命令（不使用 shell/popen）
static int runCommandDirect(const char *path, char *const argv[], int *statusOut) {
    pid_t pid;
    posix_spawnattr_t attr;
    int err = posix_spawnattr_init(&attr);
    if (err != 0) return err;

    // 设置 persona 为 root (99 = root persona)
    err = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (err != 0) { posix_spawnattr_destroy(&attr); return err; }

    // 设置 UID = 0 (root)
    err = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (err != 0) { posix_spawnattr_destroy(&attr); return err; }

    // 设置 GID = 0 (wheel)
    err = posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (err != 0) { posix_spawnattr_destroy(&attr); return err; }

    // 直接 posix_spawn，不走 shell
    err = posix_spawn(&pid, path, NULL, &attr, argv, NULL);
    posix_spawnattr_destroy(&attr);

    if (err != 0) return err;

    // 等待进程
    waitpid(pid, statusOut, 0);
    return 0;
}

int spawnRoot(NSString* path, NSArray* _Nullable args) {
    if (!path) return -1;

    // 构建参数数组（带 NULL 终止符）
    NSMutableArray *fullArgv = [NSMutableArray arrayWithObject:path];
    if (args) [fullArgv addObjectsFromArray:args];

    char **argv = malloc((fullArgv.count + 1) * sizeof(char*));
    for (NSUInteger i = 0; i < fullArgv.count; i++) {
        argv[i] = (char *)[fullArgv[i] UTF8String];
    }
    argv[fullArgv.count] = NULL;

    int status = 0;
    int err = runCommandDirect([path UTF8String], argv, &status);
    free(argv);

    return (err == 0) ? WEXITSTATUS(status) : err;
}



#ifdef __cplusplus
}
#endif
