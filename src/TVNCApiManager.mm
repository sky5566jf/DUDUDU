/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#if !__has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag.
#endif

#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

// IOSurface 头文件路径处理
#if __has_include(<IOSurface/IOSurface.h>)
#import <IOSurface/IOSurface.h>
#elif __has_include(<IOSurfaceSPI.h>)
#import "IOSurfaceSPI.h"
#else
// 前向声明 IOSurface 函数
extern "C" {
typedef struct __IOSurface *IOSurfaceRef;
IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
void IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
void IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
size_t IOSurfaceGetAllocSize(IOSurfaceRef surface);
}
#endif

#import "TVNCApiManager.h"
#import "ScreenCapturer.h"
#import "IOSurfaceSPI.h"
#import "Logging.h"

#ifdef __cplusplus
extern "C" {
#endif

void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

#ifdef __cplusplus
}
#endif

@implementation TVNCApiManager

+ (instancetype)sharedManager {
    static TVNCApiManager *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

#pragma mark - 截图 API

- (nullable NSData *)captureScreenshotAsPNG {
    return [self captureScreenshotWithFormat:(__bridge CFStringRef)@"public.png" quality:1.0];
}

- (nullable NSData *)captureScreenshotAsJPEGWithQuality:(CGFloat)quality {
    return [self captureScreenshotWithFormat:(__bridge CFStringRef)@"public.jpeg" quality:quality];
}

- (nullable NSData *)captureScreenshotWithFormat:(CFStringRef)format quality:(CGFloat)quality {
    // 获取屏幕尺寸
    CGSize screenSize = [[UIScreen mainScreen] bounds].size;
    CGFloat scale = [[UIScreen mainScreen] scale];
    int width = (int)(screenSize.width * scale);
    int height = (int)(screenSize.height * scale);
    
    // 创建 IOSurface 属性
    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int bytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * width);
    
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(width),
        (__bridge NSString *)kIOSurfaceHeight : @(height),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(bytesPerRow * height),
    };
    
    // 创建 IOSurface
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) {
        TVLog(@"Failed to create IOSurface for screenshot");
        return nil;
    }
    
    // 渲染屏幕内容到 IOSurface
    CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    
    // 锁定 IOSurface
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nil);
    
    // 创建 CGDataProvider
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL,
                                                               IOSurfaceGetBaseAddress(surface),
                                                               IOSurfaceGetAllocSize(surface),
                                                               NULL);
    
    // 创建 CGImage
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImage = CGImageCreate(width,
                                        height,
                                        8,
                                        32,
                                        bytesPerRow,
                                        colorSpace,
                                        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nil);
    
    if (!cgImage) {
        TVLog(@"Failed to create CGImage from IOSurface");
        CFRelease(surface);
        return nil;
    }
    
    // 转换为 PNG/JPEG 数据
    NSMutableData *imageData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData,
                                                                   format,
                                                                   1,
                                                                   NULL);
    if (!dest) {
        TVLog(@"Failed to create image destination");
        CGImageRelease(cgImage);
        CFRelease(surface);
        return nil;
    }
    
    // 设置压缩质量（仅对 JPEG 有效）
    CFDictionaryRef propertiesRef = NULL;
    if (CFStringCompare(format, (__bridge CFStringRef)@"public.jpeg", 0) == kCFCompareEqualTo) {
        CFStringRef keys[1] = { CFSTR("kCGImageDestinationLossyCompressionQuality") };
        float qualityFloat = (float)quality;
        CFNumberRef values[1] = { CFNumberCreate(NULL, kCFNumberFloatType, &qualityFloat) };
        propertiesRef = CFDictionaryCreate(NULL, (const void **)keys, (const void **)values, 1, 
                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(values[0]);
    }
    
    CGImageDestinationAddImage(dest, cgImage, propertiesRef);
    if (propertiesRef) CFRelease(propertiesRef);
    BOOL success = CGImageDestinationFinalize(dest);
    
    CFRelease(dest);
    CGImageRelease(cgImage);
    CFRelease(surface);
    
    if (!success) {
        TVLog(@"Failed to finalize image destination");
        return nil;
    }
    
    return imageData;
}

#pragma mark - 文件操作 API

- (BOOL)writeContent:(id)content toFilePath:(NSString *)filePath append:(BOOL)append error:(NSError **)error {
    if (!content || !filePath || filePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1001
                                    userInfo:@{NSLocalizedDescriptionKey : @"Invalid content or file path"}];
        }
        return NO;
    }
    
    NSData *data = nil;
    if ([content isKindOfClass:[NSString class]]) {
        // 使用 UTF-8 编码处理中文
        data = [(NSString *)content dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([content isKindOfClass:[NSData class]]) {
        data = content;
    } else {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1002
                                    userInfo:@{NSLocalizedDescriptionKey : @"Content must be NSString or NSData"}];
        }
        return NO;
    }
    
    if (!data) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1003
                                    userInfo:@{NSLocalizedDescriptionKey : @"Failed to convert content to data"}];
        }
        return NO;
    }
    
    // 使用 POSIX API 进行文件操作，绕过 iOS 沙盒限制
    const char *path = [filePath UTF8String];
    
    // 确保目录存在
    NSString *directory = [filePath stringByDeletingLastPathComponent];
    const char *dirPath = [directory UTF8String];
    
    // 递归创建目录
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", dirPath);
    size_t len = strlen(tmp);
    
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
    
    // 检查目录是否创建成功
    struct stat st;
    if (stat(dirPath, &st) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1005
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to create directory: %s", strerror(errno)]}];
        }
        return NO;
    }
    
    // 打开文件
    int flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC);
    int fd = open(path, flags, 0644);
    
    if (fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1006
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to open file: %s", strerror(errno)]}];
        }
        return NO;
    }
    
    // 写入数据
    ssize_t written = write(fd, data.bytes, data.length);
    close(fd);
    
    if (written < 0 || (size_t)written != data.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1007
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to write file: %s", strerror(errno)]}];
        }
        return NO;
    }
    
    return YES;
}

#pragma mark - 剪贴板 API

- (BOOL)setClipboardText:(NSString *)text {
    if (!text) {
        return NO;
    }
    
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    
    // 使用 string 属性设置，确保 UTF-8 编码支持中文
    pasteboard.string = text;
    
    // 验证设置是否成功
    return [pasteboard.string isEqualToString:text];
}

- (nullable NSString *)getClipboardText {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    return pasteboard.string;
}

#pragma mark - 键盘输入 API

- (BOOL)inputText:(NSString *)text {
    if (!text || text.length == 0) {
        return NO;
    }
    
    // 在主线程执行
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self inputText:text];
        });
        return result;
    }
    
    // 查找当前第一响应者
    UIView *firstResponder = [self findFirstResponder];
    if (!firstResponder) {
        TVLog(@"No first responder found for text input");
        return NO;
    }
    
    TVLog(@"Found first responder: %@", NSStringFromClass([firstResponder class]));
    
    // 处理不同类型的输入框
    if ([firstResponder isKindOfClass:[UITextField class]]) {
        UITextField *textField = (UITextField *)firstResponder;
        
        // 使用 UITextInput 协议的方法获取/设置选中范围
        UITextRange *selectedTextRange = textField.selectedTextRange;
        if (!selectedTextRange) {
            selectedTextRange = [textField textRangeFromPosition:textField.endOfDocument 
                                                      toPosition:textField.endOfDocument];
        }
        
        // 替换选中的文本
        [textField replaceRange:selectedTextRange withText:text];
        
        // 发送编辑事件
        [textField sendActionsForControlEvents:UIControlEventEditingChanged];
        
        return YES;
        
    } else if ([firstResponder isKindOfClass:[UITextView class]]) {
        UITextView *textView = (UITextView *)firstResponder;
        NSRange selectedRange = textView.selectedRange;
        
        // 在光标位置插入文本
        NSMutableString *newText = [textView.text mutableCopy] ?: [NSMutableString string];
        [newText replaceCharactersInRange:selectedRange withString:text];
        textView.text = newText;
        
        // 更新光标位置
        textView.selectedRange = NSMakeRange(selectedRange.location + text.length, 0);
        
        // 通知代理
        if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [textView.delegate textViewDidChange:textView];
        }
        
        return YES;
        
    } else if ([firstResponder conformsToProtocol:@protocol(UITextInput)]) {
        // 通用 UITextInput 协议支持
        id<UITextInput> textInput = (id<UITextInput>)firstResponder;
        
        // 获取当前选中的文本范围
        UITextRange *selectedRange = textInput.selectedTextRange;
        if (!selectedRange) {
            // 如果没有选中范围，使用文档末尾
            selectedRange = [textInput textRangeFromPosition:textInput.endOfDocument 
                                                  toPosition:textInput.endOfDocument];
        }
        
        // 替换选中的文本
        [textInput replaceRange:selectedRange withText:text];
        
        return YES;
    }
    
    TVLog(@"First responder does not support text input: %@", NSStringFromClass([firstResponder class]));
    return NO;
}

- (BOOL)sendKeyCode:(NSInteger)keyCode {
    // 在主线程执行
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self sendKeyCode:keyCode];
        });
        return result;
    }
    
    UIView *firstResponder = [self findFirstResponder];
    if (!firstResponder) {
        return NO;
    }
    
    // 处理特殊按键
    switch (keyCode) {
        case 13: // 回车键
        case 0x24: // 回车 (Mac)
            if ([firstResponder isKindOfClass:[UITextField class]]) {
                UITextField *textField = (UITextField *)firstResponder;
                [textField sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
                return YES;
            }
            // 插入换行
            return [self inputText:@"\n"];
            
        case 8:  // 退格键
        case 0x33: // 退格 (Mac)
        case 127: // Delete
            return [self deleteBackward:firstResponder];
            
        case 9:  // Tab
        case 0x30: // Tab (Mac)
            return [self inputText:@"\t"];
            
        case 27: // ESC
            [firstResponder resignFirstResponder];
            return YES;
            
        default:
            // 尝试转换为字符
            NSString *charStr = [self stringForKeyCode:keyCode];
            if (charStr.length > 0) {
                return [self inputText:charStr];
            }
            return NO;
    }
}

- (BOOL)sendKeyCombination:(NSArray<NSNumber *> *)keyCodes {
    if (!keyCodes || keyCodes.count == 0) {
        return NO;
    }
    
    // 在主线程执行
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self sendKeyCombination:keyCodes];
        });
        return result;
    }
    
    // 解析组合键
    BOOL hasCommand = NO;
    BOOL hasControl = NO;
    BOOL hasOption = NO;
    BOOL hasShift = NO;
    NSInteger mainKey = -1;
    
    for (NSNumber *keyCode in keyCodes) {
        NSInteger code = [keyCode integerValue];
        
        // 检查修饰键
        if (code == 0x100000 || code == 55) { // Command
            hasCommand = YES;
        } else if (code == 0x200000 || code == 59 || code == 62) { // Shift
            hasShift = YES;
        } else if (code == 0x400000 || code == 58 || code == 61) { // Option/Alt
            hasOption = YES;
        } else if (code == 0x800000 || code == 60) { // Control
            hasControl = YES;
        } else {
            mainKey = code;
        }
    }
    
    // 处理常见的组合键
    if (hasCommand && mainKey == 0x56) { // Cmd+V (粘贴)
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        NSString *text = pasteboard.string;
        if (text) {
            return [self inputText:text];
        }
        return NO;
        
    } else if (hasCommand && mainKey == 0x43) { // Cmd+C (复制)
        // 复制当前选中的文本到剪贴板
        UIView *firstResponder = [self findFirstResponder];
        if ([firstResponder isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)firstResponder;
            [UIPasteboard generalPasteboard].string = textField.text ?: @"";
            return YES;
        } else if ([firstResponder isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)firstResponder;
            [UIPasteboard generalPasteboard].string = textView.text ?: @"";
            return YES;
        }
        return NO;
        
    } else if (hasCommand && mainKey == 0x41) { // Cmd+A (全选)
        UIView *firstResponder = [self findFirstResponder];
        if ([firstResponder conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> textInput = (id<UITextInput>)firstResponder;
            UITextRange *allRange = [textInput textRangeFromPosition:textInput.beginningOfDocument 
                                                          toPosition:textInput.endOfDocument];
            textInput.selectedTextRange = allRange;
            return YES;
        }
        return NO;
        
    } else if ((hasCommand || hasControl) && mainKey == 0x58) { // Cmd+X / Ctrl+X (剪切)
        UIView *firstResponder = [self findFirstResponder];
        if ([firstResponder isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)firstResponder;
            [UIPasteboard generalPasteboard].string = textField.text ?: @"";
            textField.text = @"";
            return YES;
        } else if ([firstResponder isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)firstResponder;
            [UIPasteboard generalPasteboard].string = textView.text ?: @"";
            textView.text = @"";
            return YES;
        }
        return NO;
    }
    
    return NO;
}

#pragma mark - 私有方法

- (UIView *)findFirstResponder {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        UIView *firstResponder = [self findFirstResponderInView:window];
        if (firstResponder) {
            return firstResponder;
        }
    }
    return nil;
}

- (UIView *)findFirstResponderInView:(UIView *)view {
    if (view.isFirstResponder) {
        return view;
    }
    
    for (UIView *subview in view.subviews) {
        UIView *firstResponder = [self findFirstResponderInView:subview];
        if (firstResponder) {
            return firstResponder;
        }
    }
    
    return nil;
}

- (BOOL)deleteBackward:(UIView *)firstResponder {
    if ([firstResponder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> textInput = (id<UITextInput>)firstResponder;
        
        // 获取当前选中的范围
        UITextRange *selectedRange = textInput.selectedTextRange;
        
        if (selectedRange && !selectedRange.isEmpty) {
            // 有选中的文本，直接删除
            [textInput replaceRange:selectedRange withText:@""];
        } else {
            // 没有选中的文本，删除光标前一个字符
            [textInput deleteBackward];
        }
        
        // 发送编辑事件（如果是 UITextField）
        if ([firstResponder isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)firstResponder;
            [textField sendActionsForControlEvents:UIControlEventEditingChanged];
        } else if ([firstResponder isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)firstResponder;
            if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [textView.delegate textViewDidChange:textView];
            }
        }
        
        return YES;
    }
    
    return NO;
}

- (NSString *)stringForKeyCode:(NSInteger)keyCode {
    // 简单的键码到字符映射
    static NSDictionary *keyMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keyMap = @{
            @(0x00): @"a", @(0x01): @"s", @(0x02): @"d", @(0x03): @"f",
            @(0x04): @"h", @(0x05): @"g", @(0x06): @"z", @(0x07): @"x",
            @(0x08): @"c", @(0x09): @"v", @(0x0B): @"b", @(0x0C): @"q",
            @(0x0D): @"w", @(0x0E): @"e", @(0x0F): @"r",
            @(0x10): @"y", @(0x11): @"t", @(0x12): @"1", @(0x13): @"2",
            @(0x14): @"3", @(0x15): @"4", @(0x16): @"6", @(0x17): @"5",
            @(0x18): @"=", @(0x19): @"9", @(0x1A): @"7", @(0x1B): @"-",
            @(0x1C): @"8", @(0x1D): @"0", @(0x1E): @"]", @(0x1F): @"o",
            @(0x20): @"u", @(0x21): @"[", @(0x22): @"i", @(0x23): @"p",
            @(0x24): @"\n", @(0x25): @"l", @(0x26): @"j", @(0x27): @"'",
            @(0x28): @"k", @(0x29): @";", @(0x2A): @"\\", @(0x2B): @",",
            @(0x2C): @"/", @(0x2D): @"n", @(0x2E): @"m", @(0x2F): @".",
            @(0x30): @"\t", @(0x31): @" ", @(0x32): @"`", @(0x33): @"\b",
            @(0x35): @"ESC", @(0x37): @"CMD", @(0x38): @"SHIFT",
            @(0x3A): @"OPTION", @(0x3B): @"CONTROL",
        };
    });
    
    return keyMap[@(keyCode)] ?: @"";
}

@end
