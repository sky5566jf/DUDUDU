// tvnc_inject.m
// 注入到「前台目标 App 进程」内的 dylib。
// 由 trollvncserver（独立守护进程）通过 task_for_pid + thread 注入加载到游戏进程，
// 然后在游戏进程空间内直接调用 UIKit / WebKit 文本输入，绕过输入法与 AX 节点限制
// （即懒人精灵巨魔版「root模式直接输入文字」的等价实现，参考 RootCore inputText 逆向）。
//
// 导出函数 tvnc_inject_text 由守护进程通过 dlopen/dlsym 找到并调用。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 第一响应者获取（sendAction 技巧，跨版本可靠，避免依赖私有属性）

static __weak UIResponder *g_tvnc_fr = nil;

@interface UIResponder (TVNCFirstResponder)
+ (UIResponder *)tvnc_currentFirstResponder;
@end

@implementation UIResponder (TVNCFirstResponder)
+ (UIResponder *)tvnc_currentFirstResponder {
    g_tvnc_fr = nil;
    // sendAction:to:nil 会把动作沿响应者链下发，第一响应者最先收到 -> 标自身
    [[UIApplication sharedApplication] sendAction:@selector(_tvnc_markFirstResponder)
                                               to:nil
                                             from:nil
                                         forEvent:nil];
    return g_tvnc_fr;
}
- (void)_tvnc_markFirstResponder { g_tvnc_fr = self; }
@end

#pragma mark - keyWindow（iOS 13+ 多场景）

static UIWindow *tvnc_keyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return app.keyWindow;
}

#pragma mark - 查找 WKWebView（用 NSClassFromString 避免链接 WebKit）

static void tvnc_collectWebViews(UIView *root, NSMutableArray *out) {
    if (!root) return;
    Class wk = NSClassFromString(@"WKWebView");
    if (wk && [root isKindOfClass:wk]) [out addObject:root];
    for (UIView *sub in root.subviews) tvnc_collectWebViews(sub, out);
}

// 仅声明我们需要的方法，避免引入 WebKit 头文件
@protocol TVNCWKWebView <NSObject>
- (void)evaluateJavaScript:(NSString *)javaScriptString
         completionHandler:(void (^)(id, NSError *))completionHandler;
@end

// 在 web 视图里把文本写入当前活动元素，并派发 input/change 事件
// （React 等受控组件必须靠派发事件才能更新状态，光设 .value 无效）
static BOOL tvnc_webInject(id webView, NSString *text) {
    if (![webView conformsToProtocol:@protocol(TVNCWKWebView)]) return NO;

    // JS 字符串转义
    NSMutableString *esc = [text mutableCopy];
    [esc replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, esc.length)];
    [esc replaceOccurrencesOfString:@"'"  withString:@"\\'"  options:0 range:NSMakeRange(0, esc.length)];
    [esc replaceOccurrencesOfString:@"\r" withString:@"\\r"  options:0 range:NSMakeRange(0, esc.length)];
    [esc replaceOccurrencesOfString:@"\n" withString:@"\\n"  options:0 range:NSMakeRange(0, esc.length)];

    NSString *js = [NSString stringWithFormat:
        @"(function(){"
        @"var el=document.activeElement;"
        @"if(!el)return false;"
        @"var t=el.tagName?el.tagName.toUpperCase():'';"
        @"var ok=(t==='INPUT'||t==='TEXTAREA'||el.isContentEditable);"
        @"if(!ok)return false;"
        @"var proto=(el.value!==undefined)?'value':'textContent';"
        @"var desc=Object.getOwnPropertyDescriptor(el.constructor.prototype,proto);"
        @"if(desc&&desc.set){desc.set.call(el,'%@');}else{el[proto]='%@';}"
        @"el.dispatchEvent(new Event('input',{bubbles:true}));"
        @"el.dispatchEvent(new Event('change',{bubbles:true}));"
        @"return true;"
        @"})()", esc, esc];

    __block BOOL result = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    // evaluateJavaScript 必须在主线程调用，完成回调也在主线程投递
    dispatch_async(dispatch_get_main_queue(), ^{
        [(id<TVNCWKWebView>)webView evaluateJavaScript:js
                                     completionHandler:^(id val, NSError *err) {
            if (!err && [val isKindOfClass:[NSNumber class]]) result = [val boolValue];
            dispatch_semaphore_signal(sem);
        }];
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC));
    return result;
}

#pragma mark - 导出入口

__attribute__((visibility("default")))
BOOL tvnc_inject_text(NSString *text) {
    @autoreleasepool {
        if (!text) text = @"";
        if (text.length == 0) return NO;

        UIWindow *key = tvnc_keyWindow();
        if (!key) return NO;

        // 1) Web 视图：先尝试 JS 注入（覆盖 HTML <input>/<textarea>/contenteditable，
        //    尤其是 React/Vue 受控组件——光 insertText: 不派发事件，框架读不到值）
        NSMutableArray *webViews = [NSMutableArray array];
        tvnc_collectWebViews(key, webViews);
        for (id wv in webViews) {
            if (tvnc_webInject(wv, text)) return YES;
        }

        // 2) 原生第一响应者
        UIResponder *fr = [UIResponder tvnc_currentFirstResponder];
        if (!fr) fr = [key performSelector:NSSelectorFromString(@"firstResponder")];
        if (!fr) return NO;

        // 2a) 若第一响应者本身就是某个 web 内容视图，再补一次 JS（防止上面遍历遗漏）
        if ([webViews containsObject:fr]) {
            if (tvnc_webInject(fr, text)) return YES;
        }

        // 2b) 原生 insertText:（UITextField / UITextView / WKContentView 等）
        //     fr 静态类型是 UIResponder*（未声明 insertText:），用 id 转发调用避免编译报错
        if ([fr respondsToSelector:@selector(insertText:)]) {
            id target = fr;
            [target insertText:text];
            return YES;
        }
        // 2c) UITextInput 协议：替换全选范围（兜底）
        if ([fr conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> ti = (id<UITextInput>)fr;
            UITextRange *all = [ti textRangeFromPosition:ti.beginningOfDocument
                                             toPosition:ti.endOfDocument];
            if (all) { [ti replaceRange:all withText:text]; return YES; }
        }
        // 2d) UIKeyInput 协议：只实现 UIKeyInput 的自定义输入视图（如部分游戏/H5 壳）
        if ([fr conformsToProtocol:@protocol(UIKeyInput)]) {
            [(id<UIKeyInput>)fr insertText:text];
            return YES;
        }
        return NO;
    }
}
