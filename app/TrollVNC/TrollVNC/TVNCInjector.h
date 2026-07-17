/*
 为前台 App 提供文本注入能力。
 TrollVNC.app 有完整的 UIKit 会话，可以使用：
 - SpringBoard XPC（获取前台 App PID）
 - UIKeyboardImpl（键盘系统输入）
 - Accessibility（AX 通道）
 
 而 daemon (trollvncserver) 没有 UI 会话，无法使用这些 API。
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVNCInjector : NSObject

+ (instancetype)sharedInjector;

/**
 注入文本到当前前台 App
 使用 SpringBoard XPC 获取前台 PID，然后通过进程内注入调用 UIKit insertText:
 
 @param text 要输入的文本
 @return 操作结果字典
 */
- (NSDictionary *)injectText:(NSString *)text;

/**
 探测注入通道
 验证是否可以获取前台 PID 和 task_for_pid
 
 @return 探测结果字典
 */
- (NSDictionary *)probe;

/**
 通过键盘系统输入文本（不需要进程注入）
 使用 UIKeyboardImpl 私有 API 直接输入
 
 @param text 要输入的文本
 @return 是否成功
 */
- (BOOL)inputTextViaKeyboard:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
