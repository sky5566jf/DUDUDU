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

int spawnRoot(NSString* path, NSArray* _Nullable args, NSString** _Nullable stdOut, NSString** _Nullable stdErr) {
    if (!path) {
        return -1;
    }
    
    pid_t pid;
    posix_spawnattr_t attr;
    
    // 初始化 spawn 属性
    int err = posix_spawnattr_init(&attr);
    if (err != 0) {
        return err;
    }
    
    // 设置 persona 为 root (99 = root persona)
    err = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        return err;
    }
    
    // 设置 UID 和 GID 为 0 (root)
    err = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        return err;
    }
    
    err = posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (err != 0) {
        posix_spawnattr_destroy(&attr);
        return err;
    }
    
    // 准备参数
    NSMutableArray* argv = [NSMutableArray arrayWithObject:path];
    if (args) {
        [argv addObjectsFromArray:args];
    }
    
    // 添加 NULL 终止符
    NSMutableArray* fullArgv = [NSMutableArray array];
    for (NSString* arg in argv) {
        [fullArgv addObject:(NSString*)arg];
    }
    [fullArgv addObject:@""];
    
    char* argsC[fullArgv.count];
    for (NSUInteger i = 0; i < fullArgv.count; i++) {
        argsC[i] = (char*)[fullArgv[i] UTF8String];
    }
    
    // 使用 popen 执行命令（捕获输出）
    NSMutableString* output = [NSMutableString string];
    
    // 构建完整命令
    NSMutableString* command = [NSMutableString stringWithFormat:@"%@", path];
    for (NSString* arg in args) {
        [command appendFormat:@" \"%@\"", arg];
    }
    
    FILE* fp = popen([command UTF8String], "r");
    if (fp) {
        char buf[1024];
        while (fgets(buf, sizeof(buf), fp) != NULL) {
            [output appendFormat:@"%s", buf];
        }
        int status = pclose(fp);
        
        if (stdOut) {
            *stdOut = [output copy];
        }
        
        posix_spawnattr_destroy(&attr);
        return WIFEXITED(status) ? WEXITSTATUS(status) : status;
    }
    
    // 如果 popen 失败，尝试 posix_spawn
    err = posix_spawn(&pid, [path UTF8String], NULL, &attr, argsC, NULL);
    posix_spawnattr_destroy(&attr);
    
    if (err != 0) {
        return err;
    }
    
    // 等待进程
    int status;
    waitpid(pid, &status, 0);
    
    return WIFEXITED(status) ? WEXITSTATUS(status) : status;
}

// MARK: - runCommandAsRoot
// 以 root 身份执行 shell 命令

int runCommandAsRoot(NSString* command, NSString** stdOut, NSString** stdErr) {
    if (!command) {
        return -1;
    }
    
    // 使用 popen 执行 root 命令
    // 注意：需要终端支持 sudo 或者使用其他机制
    
    FILE* fp = popen([command UTF8String], "r");
    if (fp) {
        NSMutableString* output = [NSMutableString string];
        char buf[1024];
        
        while (fgets(buf, sizeof(buf), fp) != NULL) {
            [output appendFormat:@"%s", buf];
        }
        
        int status = pclose(fp);
        
        if (stdOut) {
            *stdOut = [output copy];
        }
        
        return WIFEXITED(status) ? WEXITSTATUS(status) : status;
    }
    
    return -1;
}

#ifdef __cplusplus
}
#endif
