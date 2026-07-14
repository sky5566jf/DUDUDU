// TVNCProcessInject.h
// 进程内注入管理器：把 tvnc_inject.dylib 注入「前台游戏/目标 App 进程」，
// 在其进程空间内直接调用 UIKit insertText:，彻底解决游戏自绘框文本输入问题。
//
// 仅依赖 mach API（守护进程 trollvncserver 为命令行 TOOL，无 UIKit）。
// 实际 UIKit 调用在 tvnc_inject.dylib（运行于目标 App 进程内）完成。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVNCProcessInject : NSObject

// 注入文本到前台 App 的当前聚焦输入框。
// 返回详细字典，每步带 status，便于设备上定位失败环节。
+ (NSDictionary *)injectText:(NSString *)text;

// 仅探测：返回前台 App 的 PID 与能否取得 task port（不实际注入）。
// 用于验证 task_for_pid-allow entitlement 在设备上是否生效。
+ (NSDictionary *)probe;

@end

NS_ASSUME_NONNULL_END
