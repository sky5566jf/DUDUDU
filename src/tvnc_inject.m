// tvnc_inject.m
// 注入到「前台目标 App 进程」内的 dylib。
// 由 trollvncserver（独立守护进程）通过 task_for_pid + thread 注入加载到游戏进程，
// 然后在游戏进程空间内直接调用 UIKit 的 insertText:，绕过输入法与 AX 节点限制
// （即懒人精灵巨魔版「root模式直接输入文字」的等价实现）。
//
// 导出函数 tvnc_inject_text 由守护进程通过 dlopen/dlsym 找到并调用。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 显式导出，供注入方 dlsym 查找。
__attribute__((visibility("default")))
BOOL tvnc_inject_text(NSString *text) {
    @autoreleasepool {
        if (!text || text.length == 0) return NO;

        UIWindow *key = nil;

        // iOS 13+ 用 connectedScenes 取 keyWindow（旧 keyWindow 可能为空）
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *ws = (UIWindowScene *)scene;
                    for (UIWindow *w in ws.windows) {
                        if (w.isKeyWindow) { key = w; break; }
                    }
                    if (!key) key = ws.windows.firstObject;
                    if (key) break;
                }
            }
        }
        if (!key) {
            key = UIApplication.sharedApplication.keyWindow;
        }
        if (!key) return NO;

        UIResponder *fr = key.firstResponder;
        if (!fr) return NO;

        // 方式一：直接 insertText:（UITextField / UITextView 等）
        if ([fr respondsToSelector:@selector(insertText:)]) {
            [fr insertText:text];
            return YES;
        }

        // 方式二：UITextInput 协议，替换全选范围（兜底）
        if ([fr conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> ti = (id<UITextInput>)fr;
            UITextRange *all = [ti textRangeFromPosition:ti.beginningOfDocument
                                              toPosition:ti.endOfDocument];
            if (all) {
                [ti replaceRange:all withText:text];
                return YES;
            }
        }
        return NO;
    }
}
