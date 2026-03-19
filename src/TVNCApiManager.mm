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

@end
