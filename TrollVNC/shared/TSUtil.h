#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// 以 root 身份执行程序（使用 posix_spawn + persona 提权）
/// @param path 可执行文件路径
/// @param args 参数数组（不含程序名本身）
/// @return 退出码，0 表示成功
int spawnRoot(NSString* path, NSArray* _Nullable args);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
