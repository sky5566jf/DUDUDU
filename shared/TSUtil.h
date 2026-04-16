#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 以 root 身份执行程序
/// @param path 可执行文件路径
/// @param args 参数数组
/// @param stdOut 标准输出（可选）
/// @param stdErr 标准错误（可选）
/// @return 退出码，0 表示成功
extern int spawnRoot(NSString* path, NSArray* _Nullable args, NSString** _Nullable stdOut, NSString** _Nullable stdErr);

/// 以 root 身份执行 shell 命令
/// @param command shell 命令
/// @param stdOut 标准输出（可选）
/// @param stdErr 标准错误（可选）
/// @return 退出码，0 表示成功
extern int runCommandAsRoot(NSString* command, NSString** _Nullable stdOut, NSString** _Nullable stdErr);

NS_ASSUME_NONNULL_END
