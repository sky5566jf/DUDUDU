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
#import <Accelerate/Accelerate.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dirent.h>
#import <pwd.h>
#import <grp.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>   // KERN_PROC / kinfo_proc（Tier4 前台进程枚举兜底）
#import <libproc.h>      // proc_pidpath（Tier4 取进程路径兜底）

// HID Page 常量
#ifndef kHIDPage_KeyboardOrKeypad
#define kHIDPage_KeyboardOrKeypad 0x07
#endif
#import <stdlib.h>  // 用于 system()
#import <notify.h>  // 用于 notify_post 系统通知
#import <spawn.h>   // 用于 posix_spawn
#import <sys/sysctl.h>  // 用于 sysctl 枚举进程
#import <libproc.h>     // 用于 proc_pidpath
#import <dlfcn.h>        // 用于 dlopen/dlsym 动态加载 AX 私有框架
#ifdef HAS_ROOT_SUPPORT
#import "TSUtil.h"  // 用于 spawnRoot
#endif

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
#import "STHIDEventGenerator.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <mach/mach.h>

#ifdef __cplusplus
extern "C" {
#endif

void CARenderServerRenderDisplay(kern_return_t a, CFStringRef b, IOSurfaceRef surface, int x, int y);

// SpringBoardServices 函数声明
extern CFStringRef SBSCopyFrontmostApplicationDisplayIdentifier(void);

// SBLockScreenManager 私有 API 声明 (用于自动解锁)
extern Class _SBLockScreenManager(void);

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

- (nullable NSData *)captureScreenshotWithFormat:(NSString *)format quality:(CGFloat)quality rotation:(NSInteger)rotation {
    // 规范化旋转角度为 0, 90, 180, 270
    NSInteger rot = rotation % 360;
    if (rot < 0) rot += 360;
    NSInteger rotQ = (rot / 90) % 4; // 0=0°, 1=90°, 2=180°, 3=270°

    // 确定格式
    CFStringRef formatRef = (__bridge CFStringRef)@[@"public.png", @"public.jpeg"][[@"jpeg" isEqualToString:format.lowercaseString] ? 1 : 0];

    // 获取屏幕尺寸
    CGSize screenSize = [[UIScreen mainScreen] bounds].size;
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    int srcWidth = (int)(screenSize.width * screenScale);
    int srcHeight = (int)(screenSize.height * screenScale);

    // 根据旋转角度计算输出尺寸
    int dstWidth = (rotQ % 2 == 0) ? srcWidth : srcHeight;
    int dstHeight = (rotQ % 2 == 0) ? srcHeight : srcWidth;

    // 创建 IOSurface 属性
    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int srcBytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * srcWidth);

    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(srcBytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(srcWidth),
        (__bridge NSString *)kIOSurfaceHeight : @(srcHeight),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(srcBytesPerRow * srcHeight),
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

    // 获取源图像数据
    void *srcData = IOSurfaceGetBaseAddress(surface);
    size_t srcDataSize = IOSurfaceGetAllocSize(surface);

    // 创建 CGImage
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, srcData, srcDataSize, NULL);
    CGImageRef cgImage = CGImageCreate(srcWidth, srcHeight, 8, 32, srcBytesPerRow, colorSpace,
                                        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                        provider, NULL, false, kCGRenderingIntentDefault);

    CGDataProviderRelease(provider);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nil);

    if (!cgImage) {
        TVLog(@"Failed to create CGImage from IOSurface");
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    CGImageRef finalImage = cgImage;
    CGImageRef rotatedImage = NULL;

    // 如果需要旋转，执行旋转操作
    if (rotQ != 0) {
        // 使用 vImage 进行旋转
        vImage_Buffer srcBuf = {
            .data = srcData,
            .height = (vImagePixelCount)srcHeight,
            .width = (vImagePixelCount)srcWidth,
            .rowBytes = (size_t)srcBytesPerRow
        };

        // 分配旋转后的缓冲区
        size_t dstBytesPerRow = dstWidth * 4;
        void *dstData = malloc(dstBytesPerRow * dstHeight);
        if (!dstData) {
            TVLog(@"Failed to allocate rotation buffer");
            CGImageRelease(cgImage);
            CFRelease(surface);
            CGColorSpaceRelease(colorSpace);
            return nil;
        }

        vImage_Buffer dstBuf = {
            .data = dstData,
            .height = (vImagePixelCount)dstHeight,
            .width = (vImagePixelCount)dstWidth,
            .rowBytes = dstBytesPerRow
        };

        // 确定旋转常量
        // rotation 参数含义：Home 键在哪个方向
        //   0°   → Home 在下面（不旋转，原始竖屏）
        //   90°  → Home 在右侧 → 图像需要逆时针旋转 90°（即 vImage 顺时针 270°）
        //   180° → Home 在上面 → 图像旋转 180°
        //   270° → Home 在左侧 → 图像需要顺时针旋转 90°
        uint8_t rotConst;
        switch (rotQ) {
            case 1: rotConst = kRotate270DegreesClockwise; break;  // Home在右 → 逆时针90°
            case 2: rotConst = kRotate180DegreesClockwise; break;  // Home在上
            case 3: rotConst = kRotate90DegreesClockwise; break;   // Home在左 → 顺时针90°
            default: rotConst = kRotate0DegreesClockwise; break;
        }

        uint8_t bg[4] = {0, 0, 0, 0};
        vImage_Error err = vImageRotate90_ARGB8888(&srcBuf, &dstBuf, rotConst, bg, kvImageNoFlags);

        if (err != kvImageNoError) {
            TVLog(@"vImageRotate90_ARGB8888 failed: %ld", (long)err);
            free(dstData);
            CGImageRelease(cgImage);
            CFRelease(surface);
            CGColorSpaceRelease(colorSpace);
            return nil;
        }

        // 从旋转后的缓冲区创建 CGImage
        CGDataProviderRef rotProvider = CGDataProviderCreateWithData(NULL, dstData, dstBytesPerRow * dstHeight, NULL);
        rotatedImage = CGImageCreate(dstWidth, dstHeight, 8, 32, dstBytesPerRow, colorSpace,
                                      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                      rotProvider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(rotProvider);

        if (rotatedImage) {
            finalImage = rotatedImage;
        } else {
            free(dstData);
        }
    }

    // 转换为 PNG/JPEG 数据
    NSMutableData *imageData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData,
                                                                   formatRef, 1, NULL);
    if (!dest) {
        TVLog(@"Failed to create image destination");
        if (rotatedImage) {
            CGImageRelease(rotatedImage);
            free((void *)CGImageGetDataProvider(rotatedImage));
        }
        CGImageRelease(cgImage);
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    // 设置压缩质量（仅对 JPEG 有效）
    CFDictionaryRef propertiesRef = NULL;
    if (CFStringCompare(formatRef, (__bridge CFStringRef)@"public.jpeg", 0) == kCFCompareEqualTo) {
        CFStringRef keys[1] = { CFSTR("kCGImageDestinationLossyCompressionQuality") };
        float qualityFloat = (float)quality;
        CFNumberRef values[1] = { CFNumberCreate(NULL, kCFNumberFloatType, &qualityFloat) };
        propertiesRef = CFDictionaryCreate(NULL, (const void **)keys, (const void **)values, 1,
                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(values[0]);
    }

    CGImageDestinationAddImage(dest, finalImage, propertiesRef);
    if (propertiesRef) CFRelease(propertiesRef);
    BOOL success = CGImageDestinationFinalize(dest);

    CFRelease(dest);

    // 释放旋转后的图像
    if (rotatedImage) {
        CGImageRelease(rotatedImage);
    }

    CGImageRelease(cgImage);
    CFRelease(surface);
    CGColorSpaceRelease(colorSpace);

    if (!success) {
        TVLog(@"Failed to finalize image destination");
        return nil;
    }

    return imageData;
}

- (nullable NSData *)captureScreenshotWithFormat:(NSString *)format quality:(CGFloat)quality rotation:(NSInteger)rotation scale:(CGFloat)scale {
    // 限制 scale 范围
    if (scale <= 0.0) scale = 1.0;
    if (scale > 1.0) scale = 1.0;

    // 如果 scale == 1.0，直接走不带缩放的逻辑
    if (scale >= 1.0) {
        return [self captureScreenshotWithFormat:format quality:quality rotation:rotation];
    }

    // 规范化旋转角度
    NSInteger rot = rotation % 360;
    if (rot < 0) rot += 360;
    NSInteger rotQ = (rot / 90) % 4;

    // 确定格式
    CFStringRef formatRef = (__bridge CFStringRef)@[@"public.png", @"public.jpeg"][[@"jpeg" isEqualToString:format.lowercaseString] ? 1 : 0];

    // 获取屏幕尺寸
    CGSize screenSize = [[UIScreen mainScreen] bounds].size;
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    int srcWidth = (int)(screenSize.width * screenScale);
    int srcHeight = (int)(screenSize.height * screenScale);

    // 旋转后的尺寸
    int rotWidth = (rotQ % 2 == 0) ? srcWidth : srcHeight;
    int rotHeight = (rotQ % 2 == 0) ? srcHeight : srcWidth;

    // 缩放后的最终尺寸
    int dstWidth = MAX(1, (int)(rotWidth * scale));
    int dstHeight = MAX(1, (int)(rotHeight * scale));

    // 创建 IOSurface
    unsigned pixelFormat = 0x42475241; // 'ARGB'
    int bytesPerComponent = sizeof(uint8_t);
    int bytesPerElement = bytesPerComponent * 4;
    int srcBytesPerRow = (int)IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, bytesPerElement * srcWidth);

    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceBytesPerElement : @(bytesPerElement),
        (__bridge NSString *)kIOSurfaceBytesPerRow : @(srcBytesPerRow),
        (__bridge NSString *)kIOSurfaceWidth : @(srcWidth),
        (__bridge NSString *)kIOSurfaceHeight : @(srcHeight),
        (__bridge NSString *)kIOSurfacePixelFormat : @(pixelFormat),
        (__bridge NSString *)kIOSurfaceAllocSize : @(srcBytesPerRow * srcHeight),
    };

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) {
        TVLog(@"Failed to create IOSurface for screenshot");
        return nil;
    }

    CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nil);

    void *srcData = IOSurfaceGetBaseAddress(surface);
    size_t srcDataSize = IOSurfaceGetAllocSize(surface);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, srcData, srcDataSize, NULL);
    CGImageRef cgImage = CGImageCreate(srcWidth, srcHeight, 8, 32, srcBytesPerRow, colorSpace,
                                        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nil);

    if (!cgImage) {
        TVLog(@"Failed to create CGImage from IOSurface");
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    // 步骤1: 如果需要旋转，先旋转
    void *rotatedData = NULL;
    size_t rotatedDataSize = 0;
    int rotatedBytesPerRow = 0;
    int imgWidth = srcWidth;
    int imgHeight = srcHeight;
    CGImageRef workImage = cgImage;

    if (rotQ != 0) {
        rotatedBytesPerRow = rotWidth * 4;
        rotatedDataSize = (size_t)(rotatedBytesPerRow * rotHeight);
        rotatedData = malloc(rotatedDataSize);
        if (!rotatedData) {
            TVLog(@"Failed to allocate rotation buffer");
            CGImageRelease(cgImage);
            CFRelease(surface);
            CGColorSpaceRelease(colorSpace);
            return nil;
        }

        vImage_Buffer srcBuf = {
            .data = srcData,
            .height = (vImagePixelCount)srcHeight,
            .width = (vImagePixelCount)srcWidth,
            .rowBytes = (size_t)srcBytesPerRow
        };
        vImage_Buffer rotBuf = {
            .data = rotatedData,
            .height = (vImagePixelCount)rotHeight,
            .width = (vImagePixelCount)rotWidth,
            .rowBytes = (size_t)rotatedBytesPerRow
        };

        uint8_t rotConst;
        switch (rotQ) {
            case 1: rotConst = kRotate270DegreesClockwise; break;
            case 2: rotConst = kRotate180DegreesClockwise; break;
            case 3: rotConst = kRotate90DegreesClockwise; break;
            default: rotConst = kRotate0DegreesClockwise; break;
        }

        uint8_t bg[4] = {0, 0, 0, 0};
        vImage_Error err = vImageRotate90_ARGB8888(&srcBuf, &rotBuf, rotConst, bg, kvImageNoFlags);
        if (err != kvImageNoError) {
            TVLog(@"vImageRotate90_ARGB8888 failed: %ld", (long)err);
            free(rotatedData);
            CGImageRelease(cgImage);
            CFRelease(surface);
            CGColorSpaceRelease(colorSpace);
            return nil;
        }

        CGDataProviderRef rotProvider = CGDataProviderCreateWithData(NULL, rotatedData, rotatedDataSize, NULL);
        CGImageRef rotatedImage = CGImageCreate(rotWidth, rotHeight, 8, 32, rotatedBytesPerRow, colorSpace,
                                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                                rotProvider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(rotProvider);

        if (rotatedImage) {
            workImage = rotatedImage;
            imgWidth = rotWidth;
            imgHeight = rotHeight;
        } else {
            free(rotatedData);
            rotatedData = NULL;
        }
    }

    // 步骤2: 缩放（使用 vImageScale_ARGB8888）
    // 获取旋转后图像的原始像素数据作为缩放源
    void *scaleSrcData = rotatedData ? rotatedData : srcData;
    int scaleSrcBytesPerRow = rotatedData ? rotatedBytesPerRow : srcBytesPerRow;
    // 注意: rotatedData 已经解锁了 IOSurface，但 srcData 在 surface 还活着时仍然有效（surface 未释放）

    int dstBytesPerRow = dstWidth * 4;
    size_t dstDataSize = (size_t)(dstBytesPerRow * dstHeight);
    void *dstData = malloc(dstDataSize);
    if (!dstData) {
        TVLog(@"Failed to allocate scale buffer");
        if (rotatedData) free(rotatedData);
        if (workImage != cgImage) CGImageRelease(workImage);
        CGImageRelease(cgImage);
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    vImage_Buffer scaleSrcBuf = {
        .data = scaleSrcData,
        .height = (vImagePixelCount)imgHeight,
        .width = (vImagePixelCount)imgWidth,
        .rowBytes = (size_t)scaleSrcBytesPerRow
    };
    vImage_Buffer scaleDstBuf = {
        .data = dstData,
        .height = (vImagePixelCount)dstHeight,
        .width = (vImagePixelCount)dstWidth,
        .rowBytes = (size_t)dstBytesPerRow
    };

    // 获取 vImage 缩放所需的临时缓冲区大小
    vImage_Error tempErr = vImageScale_ARGB8888(&scaleSrcBuf, &scaleDstBuf, NULL, kvImageHighQualityResampling | kvImageGetTempBufferSize);
    void *tempBuf = NULL;
    if (tempErr > 0) {
        tempBuf = malloc((size_t)tempErr);
    }

    vImage_Error scaleErr = vImageScale_ARGB8888(&scaleSrcBuf, &scaleDstBuf, tempBuf, kvImageHighQualityResampling);
    if (tempBuf) free(tempBuf);

    if (scaleErr != kvImageNoError) {
        TVLog(@"vImageScale_ARGB8888 failed: %ld", (long)scaleErr);
        free(dstData);
        if (rotatedData) free(rotatedData);
        if (workImage != cgImage) CGImageRelease(workImage);
        CGImageRelease(cgImage);
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    // 从缩放后的缓冲区创建最终 CGImage
    CGDataProviderRef dstProvider = CGDataProviderCreateWithData(NULL, dstData, dstDataSize, NULL);
    CGImageRef finalImage = CGImageCreate(dstWidth, dstHeight, 8, 32, dstBytesPerRow, colorSpace,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                           dstProvider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dstProvider);

    // 转换为图片数据
    NSMutableData *imageData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData,
                                                                   formatRef, 1, NULL);
    if (!dest || !finalImage) {
        TVLog(@"Failed to create image destination or final image");
        if (dest) CFRelease(dest);
        if (finalImage) CGImageRelease(finalImage);
        free(dstData);
        if (rotatedData) free(rotatedData);
        CGImageRelease(cgImage);
        CFRelease(surface);
        CGColorSpaceRelease(colorSpace);
        return nil;
    }

    CFDictionaryRef propertiesRef = NULL;
    if (CFStringCompare(formatRef, (__bridge CFStringRef)@"public.jpeg", 0) == kCFCompareEqualTo) {
        CFStringRef keys[1] = { CFSTR("kCGImageDestinationLossyCompressionQuality") };
        float qualityFloat = (float)quality;
        CFNumberRef values[1] = { CFNumberCreate(NULL, kCFNumberFloatType, &qualityFloat) };
        propertiesRef = CFDictionaryCreate(NULL, (const void **)keys, (const void **)values, 1,
                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(values[0]);
    }

    CGImageDestinationAddImage(dest, finalImage, propertiesRef);
    if (propertiesRef) CFRelease(propertiesRef);
    BOOL success = CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CGImageRelease(finalImage);
    free(dstData);
    if (rotatedData) free(rotatedData);
    if (workImage != cgImage) CGImageRelease(workImage);
    CGImageRelease(cgImage);
    CFRelease(surface);
    CGColorSpaceRelease(colorSpace);

    if (!success) {
        TVLog(@"Failed to finalize image destination");
        return nil;
    }

    TVLog(@"Screenshot: %dx%d -> %dx%d (scale=%.2f, rotation=%ld)", srcWidth, srcHeight, dstWidth, dstHeight, scale, (long)rotation);

    return imageData;
}

#pragma mark - VNC 帧缓存快速截图 API

// VNC 帧缓存访问函数（由 trollvncserver.mm 提供，避免 static 变量可见性问题）
// C 函数指针 callback for CGDataProviderCreateWithData (不能用 block)
static void tvncDataProviderReleaseCallback(void *info, const void *data, size_t size) {
    free((void *)data);
}

extern "C" {
void *tvncGetFrontBuffer(void);
int tvncGetFBWidth(void);
int tvncGetFBHeight(void);
int tvncGetFBBytesPerPixel(void);
}

- (BOOL)isFramebufferAvailable {
    void *fb = tvncGetFrontBuffer();
    return (fb != NULL && tvncGetFBWidth() > 0 && tvncGetFBHeight() > 0);
}

- (nullable NSData *)captureScreenshotFromFramebufferWithFormat:(NSString *)format
                                                        quality:(CGFloat)quality
                                                          scale:(CGFloat)scale
                                                           maxW:(int)maxW
                                                           maxH:(int)maxH {
    // 获取当前帧缓存信息
    void *gFrontBuffer = tvncGetFrontBuffer();
    int gWidth = tvncGetFBWidth();
    int gHeight = tvncGetFBHeight();
    int gBytesPerPixel = tvncGetFBBytesPerPixel();

    // 检查帧缓存是否可用
    if (gFrontBuffer == NULL || gWidth <= 0 || gHeight <= 0) {
        return nil;
    }

    // 限制参数范围
    if (quality < 0.0) quality = 0.0;
    if (quality > 1.0) quality = 1.0;
    if (scale <= 0.0) scale = 1.0;
    if (scale > 1.0) scale = 1.0;

    // 确定格式
    BOOL isJPEG = [[format lowercaseString] isEqualToString:@"jpeg"] ||
                  [[format lowercaseString] isEqualToString:@"jpg"];
    CFStringRef formatRef = isJPEG ? CFSTR("public.jpeg") : CFSTR("public.png");

    // 源尺寸（帧缓存当前尺寸）
    int srcW = gWidth;
    int srcH = gHeight;
    int srcBPR = srcW * gBytesPerPixel; // 每行字节数（tightly packed）

    // 计算目标尺寸（scale + maxW/maxH 约束）
    int dstW = (scale < 1.0) ? MAX(1, (int)(srcW * scale)) : srcW;
    int dstH = (scale < 1.0) ? MAX(1, (int)(srcH * scale)) : srcH;

    // 应用 maxW/maxH 约束（保持宽高比）
    if (maxW > 0 && dstW > maxW) {
        double ratio = (double)maxW / dstW;
        dstW = maxW;
        dstH = MAX(1, (int)(dstH * ratio));
    }
    if (maxH > 0 && dstH > maxH) {
        double ratio = (double)maxH / dstH;
        dstH = maxH;
        dstW = MAX(1, (int)(dstW * ratio));
    }

    // 如果不需要缩放，直接从帧缓存创建 CGImage 编码
    if (dstW == srcW && dstH == srcH) {
        // 直接从 gFrontBuffer 创建 CGImage
        // 注意：gFrontBuffer 使用 BGRA 格式（redShift=16, greenShift=8, blueShift=0）
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

        // 创建数据拷贝（避免编码时帧缓存被 swap 修改）
        size_t bufSize = (size_t)srcW * (size_t)srcH * (size_t)gBytesPerPixel;
        void *bufCopy = malloc(bufSize);
        if (!bufCopy) {
            CGColorSpaceRelease(colorSpace);
            return nil;
        }
        memcpy(bufCopy, gFrontBuffer, bufSize);

        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bufCopy, bufSize, tvncDataProviderReleaseCallback);
        CGImageRef cgImage = CGImageCreate(srcW, srcH, 8, 32, srcBPR, colorSpace,
                                           kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                           provider, NULL, false, kCGRenderingIntentDefault);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(colorSpace);

        if (!cgImage) {
            return nil;
        }

        NSMutableData *imageData = [NSMutableData data];
        CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData, formatRef, 1, NULL);
        if (!dest) {
            CGImageRelease(cgImage);
            return nil;
        }

        NSDictionary *props = nil;
        if (isJPEG) {
            props = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality) };
        }
        CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);
        BOOL success = CGImageDestinationFinalize(dest);

        CFRelease(dest);
        CGImageRelease(cgImage);

        return success ? imageData : nil;
    }

    // 需要缩放：使用 vImageScale_ARGB8888
    // 先拷贝源数据
    size_t srcBufSize = (size_t)srcW * (size_t)srcH * (size_t)gBytesPerPixel;
    void *srcCopy = malloc(srcBufSize);
    if (!srcCopy) return nil;
    memcpy(srcCopy, gFrontBuffer, srcBufSize);

    // 分配目标缓冲区
    int dstBPR = dstW * gBytesPerPixel;
    size_t dstBufSize = (size_t)dstBPR * (size_t)dstH;
    void *dstBuf = malloc(dstBufSize);
    if (!dstBuf) {
        free(srcCopy);
        return nil;
    }

    vImage_Buffer src = {
        .data = srcCopy,
        .height = (vImagePixelCount)srcH,
        .width = (vImagePixelCount)srcW,
        .rowBytes = (size_t)srcBPR
    };
    vImage_Buffer dst = {
        .data = dstBuf,
        .height = (vImagePixelCount)dstH,
        .width = (vImagePixelCount)dstW,
        .rowBytes = (size_t)dstBPR
    };

    // 获取临时缓冲区
    vImage_Error tempSize = vImageScale_ARGB8888(&src, &dst, NULL, kvImageHighQualityResampling | kvImageGetTempBufferSize);
    void *tempBuf = (tempSize > 0) ? malloc((size_t)tempSize) : NULL;

    vImage_Error err = vImageScale_ARGB8888(&src, &dst, tempBuf, kvImageHighQualityResampling);
    if (tempBuf) free(tempBuf);
    free(srcCopy);

    if (err != kvImageNoError) {
        TVLog(@"[FastShot] vImageScale_ARGB8888 failed: %ld", (long)err);
        free(dstBuf);
        return nil;
    }

    // 从缩放后数据创建 CGImage
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef dstProvider = CGDataProviderCreateWithData(NULL, dstBuf, dstBufSize, tvncDataProviderReleaseCallback);
    CGImageRef finalImage = CGImageCreate(dstW, dstH, 8, 32, dstBPR, colorSpace,
                                          kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                          dstProvider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dstProvider);
    CGColorSpaceRelease(colorSpace);

    if (!finalImage) {
        return nil;
    }

    NSMutableData *imageData = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageData, formatRef, 1, NULL);
    if (!dest) {
        CGImageRelease(finalImage);
        return nil;
    }

    NSDictionary *props = nil;
    if (isJPEG) {
        props = @{ (__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @(quality) };
    }
    CGImageDestinationAddImage(dest, finalImage, (__bridge CFDictionaryRef)props);
    BOOL success = CGImageDestinationFinalize(dest);

    CFRelease(dest);
    CGImageRelease(finalImage);

    TVLog(@"[FastShot] FB %dx%d -> %dx%d (scale=%.2f, maxW=%d, maxH=%d)", srcW, srcH, dstW, dstH, scale, maxW, maxH);
    return success ? imageData : nil;
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
    
    TVLog(@"WriteFile: target path: %@, directory: %@", filePath, directory);
    
    // 递归创建目录（使用 0777 权限，确保可写）
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", dirPath);
    size_t len = strlen(tmp);
    
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            int ret = mkdir(tmp, 0777);
            if (ret == 0) {
                // 新创建的目录，尝试设置权限
                chmod(tmp, 0777);
            } else if (errno != EEXIST) {
                TVLog(@"WriteFile: mkdir failed for '%s': %s", tmp, strerror(errno));
            }
            *p = '/';
        }
    }
    int finalRet = mkdir(tmp, 0777);
    if (finalRet == 0) {
        // 新创建的目录，设置权限
        chmod(tmp, 0777);
    } else if (errno != EEXIST) {
        TVLog(@"WriteFile: final mkdir failed for '%s': %s", tmp, strerror(errno));
    }
    
    // 检查目录是否创建成功
    struct stat st;
    if (stat(dirPath, &st) != 0) {
        TVLog(@"WriteFile: stat failed for directory '%s': %s", dirPath, strerror(errno));
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1005
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to create directory '%@': %s", directory, strerror(errno)]}];
        }
        return NO;
    }
    
    TVLog(@"WriteFile: directory exists, mode: %o, uid: %d, gid: %d", st.st_mode, st.st_uid, st.st_gid);
    
    // 检查目录是否是目录
    if (!S_ISDIR(st.st_mode)) {
        TVLog(@"WriteFile: path exists but is not a directory: %@", directory);
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1008
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Path exists but is not a directory: %@", directory]}];
        }
        return NO;
    }
    
    // 尝试设置目录权限为可写（针对 Media 目录的特殊处理）
    chmod(dirPath, 0777);
    
    // 检查目录是否可写
    if (access(dirPath, W_OK) != 0) {
        TVLog(@"WriteFile: directory not writable '%s', trying alternative method...", dirPath);
        
        // 尝试使用 root 权限创建文件（TrollStore 应用通常有 root 权限）
        // 跳过 access 检查，直接尝试写入
        TVLog(@"WriteFile: will attempt to write anyway (TrollStore may have elevated permissions)");
    }
    
    // 打开文件
    int flags = O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC);
    int fd = open(path, flags, 0644);
    
    if (fd < 0) {
        TVLog(@"WriteFile: open failed for '%s': %s", path, strerror(errno));
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1006
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to open file '%@': %s", filePath, strerror(errno)]}];
        }
        return NO;
    }
    
    // 写入数据
    ssize_t written = write(fd, data.bytes, data.length);
    close(fd);
    
    if (written < 0 || (size_t)written != data.length) {
        TVLog(@"WriteFile: write failed: %s", strerror(errno));
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:1007
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to write file: %s", strerror(errno)]}];
        }
        return NO;
    }
    
    TVLog(@"WriteFile: success, wrote %lu bytes to %@", (unsigned long)data.length, filePath);
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
    
    // 方法1: 尝试直接操作第一响应者
    UIView *firstResponder = [self findFirstResponder];
    if (firstResponder) {
        TVLog(@"Found first responder: %@", NSStringFromClass([firstResponder class]));
        
        // 尝试直接插入文本
        if ([firstResponder isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)firstResponder;
            UITextRange *selectedTextRange = textField.selectedTextRange;
            if (!selectedTextRange) {
                selectedTextRange = [textField textRangeFromPosition:textField.endOfDocument 
                                                          toPosition:textField.endOfDocument];
            }
            [textField replaceRange:selectedTextRange withText:text];
            [textField sendActionsForControlEvents:UIControlEventEditingChanged];
            return YES;
            
        } else if ([firstResponder isKindOfClass:[UITextView class]]) {
            UITextView *textView = (UITextView *)firstResponder;
            NSRange selectedRange = textView.selectedRange;
            NSMutableString *newText = [textView.text mutableCopy] ?: [NSMutableString string];
            [newText replaceCharactersInRange:selectedRange withString:text];
            textView.text = newText;
            textView.selectedRange = NSMakeRange(selectedRange.location + text.length, 0);
            if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                [textView.delegate textViewDidChange:textView];
            }
            return YES;
            
        } else if ([firstResponder conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> textInput = (id<UITextInput>)firstResponder;
            UITextRange *selectedRange = textInput.selectedTextRange;
            if (!selectedRange) {
                selectedRange = [textInput textRangeFromPosition:textInput.endOfDocument 
                                                      toPosition:textInput.endOfDocument];
            }
            [textInput replaceRange:selectedRange withText:text];
            return YES;
        }
    }
    
    // 方法2: 使用 HID 事件直接发送键盘输入
    TVLog(@"No accessible first responder, using HID event method");
    return [self inputTextViaHID:text];
}

// 通过 HID 事件输入文本（使用 STHIDEventGenerator）
- (BOOL)inputTextViaHID:(NSString *)text {
    if (!text || text.length == 0) {
        return NO;
    }
    
    // 检查是否包含非 ASCII 字符
    BOOL hasNonASCII = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c > 127) {
            hasNonASCII = YES;
            break;
        }
    }
    
    // 如果包含中文等非 ASCII 字符，使用剪贴板方式
    if (hasNonASCII) {
        TVLog(@"Text contains non-ASCII characters, using clipboard method");
        return [self inputTextViaClipboard:text];
    }
    
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 逐个字符发送
        for (NSUInteger i = 0; i < text.length; i++) {
            NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
            [generator keyPress:character];
        }
        
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"HID input failed: %@", exception.reason);
        return NO;
    }
}

// 通过剪贴板输入文本
- (BOOL)inputTextViaClipboard:(NSString *)text {
    // 保存原始剪贴板内容
    NSString *originalText = [UIPasteboard generalPasteboard].string;
    
    // 设置要输入的文本到剪贴板
    [UIPasteboard generalPasteboard].string = text;
    
    // 使用 HID 事件发送 Command+V 粘贴
    BOOL success = [self sendPasteKeyCombination];
    
    // 延迟恢复原始剪贴板内容
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (originalText) {
            [UIPasteboard generalPasteboard].string = originalText;
        }
    });
    
    return success;
}

// MARK: - 无障碍(AX) 输入
// 系统无障碍(Accessibility) 私有 API 动态加载。
// iOS 上 AXUIElement 系列函数在私有 Accessibility 框架中，且不同 iOS 版本路径不同
// （iOS16 在 PrivateFrameworks，iOS17+ 在 Frameworks）。用 dlopen/dlsym 动态解析，
// 避免编译期/链接期依赖 SDK 中框架路径，CI 不会因框架定位失败。
typedef CFTypeRef AXUIElementRef;
typedef uint32_t AXError;
typedef AXUIElementRef (*TVNC_AXCreateSystemWide)(void);
typedef AXError (*TVNC_AXCopyAttr)(AXUIElementRef, CFStringRef, CFTypeRef *);
typedef AXError (*TVNC_AXSetAttr)(AXUIElementRef, CFStringRef, CFTypeRef);
typedef CFTypeID (*TVNC_AXGetTypeID)(void);

static struct {
    void *handle;
    TVNC_AXCreateSystemWide createSystemWide;
    TVNC_AXCopyAttr copyAttr;
    TVNC_AXSetAttr setAttr;
    TVNC_AXGetTypeID getTypeID;
    BOOL tried;
} gTVNCAX = {0};

static BOOL TVNCLoadAX(void) {
    if (gTVNCAX.tried) return gTVNCAX.handle != NULL;
    gTVNCAX.tried = YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        gTVNCAX.handle = dlopen(paths[i], RTLD_LAZY);
        if (gTVNCAX.handle) break;
    }
    if (!gTVNCAX.handle) {
        TVLog(@"AX: dlopen Accessibility failed");
        return NO;
    }
    gTVNCAX.createSystemWide = (TVNC_AXCreateSystemWide)dlsym(gTVNCAX.handle, "AXUIElementCreateSystemWide");
    gTVNCAX.copyAttr        = (TVNC_AXCopyAttr)dlsym(gTVNCAX.handle, "AXUIElementCopyAttributeValue");
    gTVNCAX.setAttr         = (TVNC_AXSetAttr)dlsym(gTVNCAX.handle, "AXUIElementSetAttributeValue");
    gTVNCAX.getTypeID       = (TVNC_AXGetTypeID)dlsym(gTVNCAX.handle, "AXUIElementGetTypeID");
    BOOL ok = gTVNCAX.createSystemWide && gTVNCAX.copyAttr && gTVNCAX.setAttr && gTVNCAX.getTypeID;
    if (!ok) TVLog(@"AX: dlsym missing symbol");
    return ok;
}

// 通过系统无障碍(AX)通道注入文本：直接对"当前聚焦的 UI 元素"写入文本值。
// 与 inputText（firstResponder）、inputTextViaHID（HID/剪贴板）互补，专门解决
// 游戏 / 引擎自绘 / WebView 等"任何字符都进不去"的输入框（懒人精灵巨魔版同款通道）。
// 全程不碰剪贴板，不会触发 iOS 16 "允许粘贴" 弹窗。
// 前置：设备需开启辅助功能访问（TrollStore 环境通常已授权），且当前光标停在目标文本区。
- (BOOL)inputTextViaAX:(NSString *)text {
    if (!text || text.length == 0) {
        return NO;
    }
    if (!TVNCLoadAX()) {
        return NO;
    }
    // 在独立工作线程跑 AX（AX XPC 需要 runloop；避免在主线程 dispatch_sync 死锁），
    // 通过 NSCondition 回收结果。无论调用方处于哪个线程都不会死锁。
    __block BOOL result = NO;
    NSCondition *cond = [[NSCondition alloc] init];
    __block BOOL done = NO;
    NSThread *worker = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            result = [self _axInputSync:text];
            [cond lock];
            done = YES;
            [cond signal];
            [cond unlock];
        }
    }];
    [worker start];
    [cond lock];
    while (!done) [cond wait];
    [cond unlock];
    return result;
}

// AX 实际写入逻辑（运行于独立工作线程）。
- (BOOL)_axInputSync:(NSString *)text {
    AXUIElementRef systemWide = gTVNCAX.createSystemWide();
    if (!systemWide) {
        TVLog(@"AX: createSystemWide failed");
        return NO;
    }

    CFTypeRef focusedRaw = NULL;
    AXError err = gTVNCAX.copyAttr(systemWide, CFSTR("AXFocusedUIElement"), &focusedRaw);
    if (err != 0 || !focusedRaw || CFGetTypeID(focusedRaw) != gTVNCAX.getTypeID()) {
        TVLog(@"AX: no focused element (err=%u)", (unsigned)err);
        if (focusedRaw) CFRelease(focusedRaw);
        CFRelease(systemWide);
        return NO;
    }
    AXUIElementRef focused = (AXUIElementRef)focusedRaw;

    // 优先：直接设置 AXValue（覆盖/填入文本框值）
    AXError setErr = gTVNCAX.setAttr(focused, CFSTR("AXValue"), (__bridge CFTypeRef)text);
    BOOL ok = (setErr == 0);

    // 兜底：若目标不支持 AXValue，则写 AXSelectedText（替换选区 = 在光标处插入）
    if (!ok) {
        setErr = gTVNCAX.setAttr(focused, CFSTR("AXSelectedText"), (__bridge CFTypeRef)text);
        ok = (setErr == 0);
        TVLog(@"AX: AXValue failed (err=%u), fallback AXSelectedText ok=%d", (unsigned)setErr, ok);
    }

    CFRelease(focused);
    CFRelease(systemWide);
    return ok;
}

// 发送粘贴组合键 Command+V
- (BOOL)sendPasteKeyCombination {
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 发送 Command 键按下
        [generator keyDown:@"COMMAND"];
        
        struct timespec pressDelay = {0, (long)(0.05 * 1e9)};
        nanosleep(&pressDelay, 0);
        
        // 发送 V 键
        [generator keyPress:@"v"];
        
        nanosleep(&pressDelay, 0);
        
        // 发送 Command 键释放
        [generator keyUp:@"COMMAND"];
        
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Paste key combination failed: %@", exception.reason);
        
        // 备用方案：尝试发送 v 键
        @try {
            STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
            [generator keyPress:@"v"];
            return YES;
        } @catch (NSException *e) {
            TVLog(@"Fallback paste failed: %@", e.reason);
            return NO;
        }
    }
}

#pragma mark - 键盘系统输入（UIKeyboardImpl 私有 API）

// 实际执行（必须在主线程）
- (BOOL)_keyboardInputSync:(NSString *)text {
    Class keyboardImplClass = NSClassFromString(@"UIKeyboardImpl");
    if (!keyboardImplClass) {
        TVLog(@"Keyboard: UIKeyboardImpl class not found (UIKit not linked?)");
        return NO;
    }
    SEL sharedImplSel = NSSelectorFromString(@"sharedInstance");
    if (![keyboardImplClass respondsToSelector:sharedImplSel]) {
        TVLog(@"Keyboard: sharedInstance not available");
        return NO;
    }
    id keyboardImpl = ((id(*)(id, SEL))[keyboardImplClass methodForSelector:sharedImplSel])(keyboardImplClass, sharedImplSel);
    if (!keyboardImpl) {
        TVLog(@"Keyboard: Failed to get UIKeyboardImpl instance");
        return NO;
    }
    @try {
        for (NSUInteger i = 0; i < text.length; i++) {
            NSString *ch = [text substringWithRange:NSMakeRange(i, 1)];
            SEL addTextSel = NSSelectorFromString(@"addText:");
            if ([keyboardImpl respondsToSelector:addTextSel]) {
                ((void(*)(id, SEL, id))[keyboardImpl methodForSelector:addTextSel])(keyboardImpl, addTextSel, ch);
            } else {
                SEL insSel = NSSelectorFromString(@"insertText:");
                if ([keyboardImpl respondsToSelector:insSel]) {
                    ((void(*)(id, SEL, id))[keyboardImpl methodForSelector:insSel])(keyboardImpl, insSel, ch);
                }
            }
            usleep(10000); // 10ms，确保输入被处理
        }
        TVLog(@"Keyboard: inputted %lu chars via UIKeyboardImpl", (unsigned long)text.length);
        return YES;
    } @catch (NSException *e) {
        TVLog(@"Keyboard input failed: %@", e.reason);
        return NO;
    }
}

// 通过 iOS 键盘系统直接输入文本（使用 UIKeyboardImpl 私有 API）
// 绕过第一响应者限制，不依赖剪贴板，不会触发 iOS 16 "允许粘贴"弹窗。
// 适用：游戏/引擎自绘/标准输入框；对完全不接系统键盘的自绘框可能无效（需进程内注入 input_inject）。
// 主线程安全：HTTP 处理线程若非主线程，dispatch_async 回主线程 + semaphore 等待，避免 dispatch_sync 死锁。
- (BOOL)inputTextViaKeyboard:(NSString *)text {
    if (!text || text.length == 0) return NO;
    if ([NSThread isMainThread]) {
        return [self _keyboardInputSync:text];
    }
    __block BOOL result = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [self _keyboardInputSync:text];
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return result;
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
    
    STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
    
    // 特殊按键映射到 HID usage codes
    // 使用 kHIDPage_KeyboardOrKeypad (0x07)
    static NSDictionary<NSNumber *, NSNumber *> *keyToHIDMap = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // USB HID Keyboard/Keypad Usage Codes (0x07)
        // 参考: https://www.usb.org/sites/default/files/documents/hut1_12v2.pdf
        keyToHIDMap = @{
            // ===== 功能键 =====
            @(27): @0x29,   // ESC
            @(13): @0x28,   // Return/Enter
            @(8): @0x2A,    // Delete/Backspace
            @(9): @0x2B,    // Tab
            @(32): @0x2C,   // Space
            
            // ===== 方向键 (macOS 键码) =====
            @(126): @0x52,  // Up Arrow
            @(125): @0x51,  // Down Arrow
            @(123): @0x50,  // Left Arrow
            @(124): @0x4F,  // Right Arrow
            
            // ===== 导航键 (macOS 键码) =====
            @(115): @0x4A,  // Home
            @(119): @0x4D,  // End
            @(116): @0x4B,  // Page Up
            @(121): @0x4E,  // Page Down
            @(117): @0x4C,  // Forward Delete (Delete/Insert)
            
            
            // ===== 功能键 F1-F12 =====
            @(122): @0x3A,  // F1
            @(120): @0x3B,  // F2
            @(99): @0x3C,   // F3
            @(118): @0x3D,  // F4
            @(96): @0x3E,   // F5
            @(97): @0x3F,   // F6
            @(98): @0x40,   // F7
            @(100): @0x41,  // F8
            @(101): @0x42,  // F9
            @(109): @0x43,  // F10
            @(103): @0x44,  // F11
            @(111): @0x45,  // F12
            
            // ===== macOS 功能键码 =====
            @(0xF704): @0x3A, // F1
            @(0xF705): @0x3B, // F2
            @(0xF706): @0x3C, // F3
            @(0xF707): @0x3D, // F4
            @(0xF708): @0x3E, // F5
            @(0xF709): @0x3F, // F6
            @(0xF70A): @0x40, // F7
            @(0xF70B): @0x41, // F8
            @(0xF70C): @0x42, // F9
            @(0xF70D): @0x43, // F10
            @(0xF70E): @0x44, // F11
            @(0xF70F): @0x45, // F12
            
            // ===== 小键盘 (macOS keycode) =====
            @(82): @0x62,   // Keypad 0
            @(83): @0x63,   // Keypad 1
            @(84): @0x64,   // Keypad 2
            @(85): @0x65,   // Keypad 3
            @(86): @0x66,  // Keypad 4
            @(87): @0x67,  // Keypad 5
            @(88): @0x68,  // Keypad 6
            @(89): @0x69,  // Keypad 7
            @(91): @0x6A,  // Keypad 8
            @(92): @0x6B,  // Keypad 9
            @(67): @0x6C,   // Keypad *
            @(69): @0x6D,   // Keypad +
            @(65): @0x6E,   // Keypad .
            @(78): @0x6F,   // Keypad -
            @(75): @0x7C,  // Keypad /
            @(81): @0x59,   // Keypad =
            @(71): @0x54,   // Keypad Clear
            
            // ===== 修饰键 (单独按下) =====
            @(54): @0xE3,   // Right Command
            @(55): @0xE3,   // Left Command (also 0xE7 for Windows key)
            @(56): @0xE1,   // Left Shift
            @(57): @0xE5,   // Caps Lock
            @(58): @0xE0,   // Left Option
            @(59): @0xE2,   // Left Control
            @(60): @0xE1,   // Right Shift
            @(61): @0xE0,   // Right Option
            @(62): @0xE4,   // Right Control
            
            // ===== 其他特殊键 =====
            @(127): @0x2A,  // Forward Delete
            @(50): @0x64,   // International1 (非英文键盘)
            @(104): @0x65,  // International2
            @(105): @0x66,  // International3
            @(106): @0x67,  // International4
            @(107): @0x68,  // International5
            @(10): @0x2D,   // Insert (= + on some keyboards)
        };
    });
    
    NSNumber *hidUsage = keyToHIDMap[@(keyCode)];
    if (hidUsage) {
        // 使用 HID 事件发送特殊按键
        [generator otherPage:kHIDPage_KeyboardOrKeypad usagePress:hidUsage.unsignedIntValue];
        return YES;
    }
    
    // 尝试转换为字符并发送
    NSString *charStr = [self stringForKeyCode:keyCode];
    if (charStr.length > 0 && ![charStr isEqualToString:@"ESC"] && ![charStr isEqualToString:@"CMD"] && ![charStr isEqualToString:@"SHIFT"] && ![charStr isEqualToString:@"OPTION"] && ![charStr isEqualToString:@"CONTROL"]) {
        @try {
            [generator keyPress:charStr];
            return YES;
        } @catch (NSException *e) {
            TVLog(@"keyPress failed: %@", e.reason);
        }
    }
    
    return NO;
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

#pragma mark - 系统控制 API

// 设置音量
- (BOOL)setVolume:(CGFloat)volume {
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;
    
    @try {
        // 使用 HID 事件模拟音量键来调整音量
        [self setSystemVolume:volume];
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Set volume failed: %@", exception.reason);
        return NO;
    }
}

// 获取当前音量
- (CGFloat)getCurrentVolume {
    @try {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error = nil;
        [session setActive:YES error:&error];
        return session.outputVolume;
    } @catch (NSException *exception) {
        TVLog(@"Get volume failed: %@", exception.reason);
        return -1;
    }
}

// 设置亮度
- (BOOL)setBrightness:(CGFloat)brightness {
    if (brightness < 0.0) brightness = 0.0;
    if (brightness > 1.0) brightness = 1.0;
    
    @try {
        // 方法1: 使用 UIScreen（在主线程执行）
        if ([NSThread isMainThread]) {
            [[UIScreen mainScreen] setBrightness:brightness];
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [[UIScreen mainScreen] setBrightness:brightness];
            });
        }
        
        // 方法2: 使用 HID 事件模拟亮度按键作为备选
        [self setBrightnessViaHID:brightness];
        
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Set brightness failed: %@", exception.reason);
        return NO;
    }
}

// 获取当前亮度
- (CGFloat)getCurrentBrightness {
    @try {
        return [UIScreen mainScreen].brightness;
    } @catch (NSException *exception) {
        TVLog(@"Get brightness failed: %@", exception.reason);
        return -1;
    }
}

// 使用 HID 事件调整亮度
- (void)setBrightnessViaHID:(CGFloat)brightness {
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 获取当前亮度
        CGFloat currentBrightness = [self getCurrentBrightness];
        if (currentBrightness < 0) currentBrightness = 0.5;
        
        // 计算需要按多少次亮度键（假设16级亮度）
        NSInteger steps = (NSInteger)(fabs(brightness - currentBrightness) * 16);
        BOOL increase = brightness > currentBrightness;
        
        for (NSInteger i = 0; i < steps && i < 20; i++) {
            if (increase) {
                [generator displayBrightnessIncrementPress];
            } else {
                [generator displayBrightnessDecrementPress];
            }
            struct timespec ts = {0, 50000000}; // 50ms
            nanosleep(&ts, NULL);
        }
    } @catch (NSException *exception) {
        TVLog(@"Set brightness via HID failed: %@", exception.reason);
    }
}

// 使用 HID 事件设置系统音量
- (void)setSystemVolume:(CGFloat)volume {
    // 通过发送音量键事件来调整
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 获取当前音量
        CGFloat currentVolume = [self getCurrentVolume];
        if (currentVolume < 0) currentVolume = 0.5; // 默认假设50%
        
        // 计算需要按多少次音量键（假设16级音量）
        NSInteger steps = (NSInteger)(fabs(volume - currentVolume) * 16);
        BOOL increase = volume > currentVolume;
        
        for (NSInteger i = 0; i < steps && i < 20; i++) { // 最多按20次
            if (increase) {
                [generator volumeIncrementPress];
            } else {
                [generator volumeDecrementPress];
            }
            struct timespec ts = {0, 50000000}; // 50ms
            nanosleep(&ts, NULL);
        }
    } @catch (NSException *exception) {
        TVLog(@"Set system volume via HID failed: %@", exception.reason);
    }
}

#pragma mark - 应用管理 API (TrollStore)

// TrollStore 帮助程序路径
#define TROLLSTORE_HELPER_PATH @"/var/containers/Bundle/Application/com.opa334.TrollStore/trollstorehelper"
#define TROLLSTORE_HELPER_PATH_ALT @"/var/mobile/trollstorehelper"

// 获取 TrollStore 帮助程序路径
- (NSString *)trollStoreHelperPath {
    // 检查常见路径（按优先级排序）
    NSArray *possiblePaths = @[
        @"/var/containers/Bundle/Application/com.opa334.TrollStore/trollstorehelper",
        @"/var/mobile/trollstorehelper",
        @"/usr/bin/trollstorehelper",
        @"/usr/local/bin/trollstorehelper",
        @"/var/jb/usr/bin/trollstorehelper",
        @"/var/jb/bin/trollstorehelper"
    ];
    
    for (NSString *path in possiblePaths) {
        if (access([path UTF8String], X_OK) == 0) {
            TVLog(@"Found TrollStore helper at: %@", path);
            return path;
        }
    }
    
    // 尝试动态查找 TrollStore 安装路径
    NSString *tsPath = [self findTrollStoreHelper];
    if (tsPath) {
        return tsPath;
    }
    
    TVLog(@"TrollStore helper not found in any known location");
    return nil;
}

// 动态查找 TrollStore helper
- (NSString *)findTrollStoreHelper {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 搜索路径列表
    NSArray *searchPaths = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application"
    ];
    
    for (NSString *bundlePath in searchPaths) {
        if (![fm fileExistsAtPath:bundlePath]) {
            continue;
        }
        
        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath error:&error];
        
        for (NSString *item in contents) {
            NSString *fullPath = [bundlePath stringByAppendingPathComponent:item];
            
            // 检查是否是 TrollStore 相关目录
            if ([item rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [item rangeOfString:@"opa334" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                
                // 直接检查目录下的 trollstorehelper
                NSString *tsHelper = [fullPath stringByAppendingPathComponent:@"trollstorehelper"];
                if (access([tsHelper UTF8String], X_OK) == 0) {
                    TVLog(@"Found TrollStore helper at: %@", tsHelper);
                    return tsHelper;
                }
                
                // 检查子目录（.app 包内）
                NSArray *subContents = [fm contentsOfDirectoryAtPath:fullPath error:nil];
                for (NSString *subItem in subContents) {
                    if ([subItem hasSuffix:@".app"]) {
                        NSString *appPath = [fullPath stringByAppendingPathComponent:subItem];
                        NSString *helperPath = [appPath stringByAppendingPathComponent:@"trollstorehelper"];
                        if (access([helperPath UTF8String], X_OK) == 0) {
                            TVLog(@"Found TrollStore helper at: %@", helperPath);
                            return helperPath;
                        }
                    }
                }
            }
        }
    }
    
    return nil;
}

// 检查 TrollStore 是否可用
- (BOOL)isTrollStoreAvailable {
    // 方法1：检查 helper 路径（向后兼容 TrollStore 1.x）
    if ([self trollStoreHelperPath] != nil) {
        return YES;
    }

    // 方法2：检查 trollstore 二进制（TrollStore 2.x）
    const char *trollstorePaths[] = {
        "/var/jb/usr/bin/trollstore",
        "/usr/bin/trollstore",
        NULL
    };
    for (int i = 0; trollstorePaths[i] != NULL; i++) {
        if (access(trollstorePaths[i], X_OK) == 0) {
            TVLog(@"TrollStore available: found trollstore at %s", trollstorePaths[i]);
            return YES;
        }
    }

    // 方法3：检查 TrollStore.app 是否存在
    NSArray *appPaths = @[
        @"/Applications/TrollStore.app",
        @"/var/jb/Applications/TrollStore.app",
        @"/var/containers/Bundle/Application/com.opa334.TrollStore/TrollStore.app"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in appPaths) {
        if ([fm fileExistsAtPath:path]) {
            TVLog(@"TrollStore available: found %@", path);
            return YES;
        }
    }

    // 方法4：canOpenURL: 兜底（需要 Info.plist 声明 LSApplicationQueriesSchemes）
    __block BOOL canOpen = NO;
    void (^checkBlock)(void) = ^{
        canOpen = [[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:@"trollstore://"]];
    };

    if ([NSThread isMainThread]) {
        checkBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), checkBlock);
    }

    if (canOpen) {
        TVLog(@"TrollStore available via trollstore:// URL scheme");
    }

    return canOpen;
}

// 获取 TrollStore 诊断信息
- (NSDictionary *)getTrollStoreDiagnostics {
    NSMutableDictionary *diagnostics = [NSMutableDictionary dictionary];
    
    // 检查各个可能的路径
    NSArray *possiblePaths = @[
        @"/var/containers/Bundle/Application/com.opa334.TrollStore/trollstorehelper",
        @"/var/mobile/trollstorehelper",
        @"/usr/bin/trollstorehelper",
        @"/usr/local/bin/trollstorehelper",
        @"/var/jb/usr/bin/trollstorehelper",
        @"/var/jb/bin/trollstorehelper"
    ];
    
    NSMutableArray *pathChecks = [NSMutableArray array];
    for (NSString *path in possiblePaths) {
        BOOL exists = (access([path UTF8String], F_OK) == 0);
        BOOL executable = (access([path UTF8String], X_OK) == 0);
        [pathChecks addObject:@{
            @"path": path,
            @"exists": @(exists),
            @"executable": @(executable)
        }];
    }
    diagnostics[@"pathChecks"] = pathChecks;
    
    // 找到的实际 helper 路径
    NSString *helperPath = [self trollStoreHelperPath];
    diagnostics[@"foundHelperPath"] = helperPath ?: @"Not found";
    diagnostics[@"isAvailable"] = @(helperPath != nil);
    
    // 尝试执行 helper 获取版本信息
    if (helperPath) {
        NSString *command = [NSString stringWithFormat:@"\"%@\" --version 2>&1 || echo \"No version flag\"", helperPath];
        FILE *fp = popen([command UTF8String], "r");
        if (fp) {
            char buffer[1024];
            NSMutableString *output = [NSMutableString string];
            while (fgets(buffer, sizeof(buffer), fp) != NULL) {
                [output appendString:[NSString stringWithUTF8String:buffer]];
            }
            pclose(fp);
            diagnostics[@"helperVersion"] = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    
    return diagnostics;
}

// 通过 TrollStore 安装 IPA
- (BOOL)installAppWithIPAPath:(NSString *)ipaPath error:(NSError **)error {
    if (!ipaPath || ipaPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2001
                                    userInfo:@{NSLocalizedDescriptionKey : @"IPA path is empty"}];
        }
        return NO;
    }
    
    // 检查 IPA 文件是否存在
    if (access([ipaPath UTF8String], F_OK) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2002
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"IPA file not found: %@", ipaPath]}];
        }
        return NO;
    }
    
    // 检查文件是否可读
    if (access([ipaPath UTF8String], R_OK) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2002
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"IPA file not readable: %@", ipaPath]}];
        }
        return NO;
    }
    
    // 获取 TrollStore 帮助程序路径
    NSString *helperPath = [self trollStoreHelperPath];
    if (!helperPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2003
                                    userInfo:@{NSLocalizedDescriptionKey : @"TrollStore helper not found. Is TrollStore installed?"}];
        }
        return NO;
    }
    
    TVLog(@"Installing IPA using TrollStore: %@", ipaPath);
    TVLog(@"TrollStore helper: %@", helperPath);
    
    // 使用 system() 函数执行命令，更兼容 iOS
    // trollstorehelper 的参数格式: install <ipa_path>
    NSString *command = [NSString stringWithFormat:@"\"%@\" install \"%@\" 2>&1", helperPath, ipaPath];
    TVLog(@"Executing command: %@", command);
    
    // 使用 popen 执行命令并获取输出
    FILE *fp = popen([command UTF8String], "r");
    if (fp == NULL) {
        TVLog(@"Failed to execute install command: %s", strerror(errno));
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2004
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Failed to execute install command: %s", strerror(errno)]}];
        }
        return NO;
    }
    
    // 读取输出
    char buffer[4096];
    NSMutableString *output = [NSMutableString string];
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        [output appendString:[NSString stringWithUTF8String:buffer]];
    }
    
    int status = pclose(fp);
    int exitCode = WEXITSTATUS(status);
    
    TVLog(@"TrollStore install output: %@", output);
    TVLog(@"TrollStore install exit code: %d", exitCode);
    
    if (exitCode == 0) {
        TVLog(@"IPA installed successfully: %@", ipaPath);
        return YES;
    } else {
        NSString *errMsg = output.length > 0 ? output : @"Installation failed";
        TVLog(@"Installation failed: %@", errMsg);
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2004
                                    userInfo:@{NSLocalizedDescriptionKey : errMsg}];
        }
        return NO;
    }
}

// 通过 TrollStore 卸载应用
- (BOOL)uninstallAppWithBundleId:(NSString *)bundleId error:(NSError **)error {
    if (!bundleId || bundleId.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2006
                                    userInfo:@{NSLocalizedDescriptionKey : @"Bundle ID is empty"}];
        }
        return NO;
    }
    
    // 获取 TrollStore 帮助程序路径
    NSString *helperPath = [self trollStoreHelperPath];
    if (!helperPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2003
                                    userInfo:@{NSLocalizedDescriptionKey : @"TrollStore helper not found. Is TrollStore installed?"}];
        }
        return NO;
    }
    
    TVLog(@"Uninstalling app using TrollStore: %@", bundleId);
    
    // 构建命令: trollstorehelper uninstall <bundle_id>
    // 使用 POSIX popen 执行命令（iOS 不支持 NSTask）
    NSString *command = [NSString stringWithFormat:@"\"%@\" uninstall \"%@\" 2>&1", helperPath, bundleId];
    TVLog(@"Executing command: %@", command);
    
    @try {
        FILE *fp = popen([command UTF8String], "r");
        if (fp == NULL) {
            TVLog(@"Failed to execute uninstall command");
            if (error) {
                *error = [NSError errorWithDomain:@"TVNCApiManager"
                                            code:2007
                                        userInfo:@{NSLocalizedDescriptionKey : @"Failed to execute uninstall command"}];
            }
            return NO;
        }
        
        // 读取输出
        char buffer[1024];
        NSMutableString *output = [NSMutableString string];
        while (fgets(buffer, sizeof(buffer), fp) != NULL) {
            [output appendString:[NSString stringWithUTF8String:buffer]];
        }
        
        int status = pclose(fp);
        int exitCode = WEXITSTATUS(status);
        
        TVLog(@"TrollStore uninstall output: %@", output);
        TVLog(@"TrollStore uninstall exit code: %d", exitCode);
        
        if (exitCode == 0) {
            TVLog(@"App uninstalled successfully: %@", bundleId);
            return YES;
        } else {
            if (error) {
                NSString *errMsg = output.length > 0 ? output : @"Uninstallation failed";
                *error = [NSError errorWithDomain:@"TVNCApiManager"
                                            code:2007
                                        userInfo:@{NSLocalizedDescriptionKey : errMsg}];
            }
            return NO;
        }
    } @catch (NSException *exception) {
        TVLog(@"Failed to uninstall app: %@", exception.reason);
        if (error) {
            *error = [NSError errorWithDomain:@"TVNCApiManager"
                                        code:2008
                                    userInfo:@{NSLocalizedDescriptionKey : 
                                        [NSString stringWithFormat:@"Exception: %@", exception.reason]}];
        }
        return NO;
    }
}

#pragma mark - 系统重启/注销 API

// 重启设备
- (BOOL)rebootDevice {
    @try {
        TVLog(@"Attempting to reboot device...");

#ifdef HAS_ROOT_SUPPORT
        // 方法1（首选）：用 spawnRoot 以 root persona 执行 /sbin/reboot
        // 这是巨魔安装应用能真正重启设备的正确方式（参考 RebootTools 项目）
        TVLog(@"Trying spawnRoot(\"/sbin/reboot\")...");
        int exitCode = spawnRoot(@"/sbin/reboot", nil);
        TVLog(@"spawnRoot(reboot) exitCode: %d", exitCode);
        if (exitCode == 0) {
            return YES;
        }

        // 方法2（备选）：/usr/sbin/reboot
        TVLog(@"Trying spawnRoot(\"/usr/sbin/reboot\")...");
        exitCode = spawnRoot(@"/usr/sbin/reboot", nil);
        TVLog(@"spawnRoot(/usr/sbin/reboot) exitCode: %d", exitCode);
        if (exitCode == 0) {
            return YES;
        }
#endif

        // 方法3（fallback）：notify_post
        int ret = notify_post("com.apple.shutdown.reboot");
        TVLog(@"notify_post(com.apple.shutdown.reboot) returned: %d", ret);
        if (ret == NOTIFY_STATUS_OK) {
            return YES;
        }

        // 方法4（最后兜底）：杀 SpringBoard（只会 respring，不是真重启）
        TVLog(@"Fallback: killing SpringBoard (respring only)...");
        [self killall:@"SpringBoard"];
        return YES;

    } @catch (NSException *exception) {
        TVLog(@"Reboot failed: %@", exception.reason);
        return NO;
    }
}

// 使用 sysctl 枚举进程并发送信号
- (void)killall:(NSString *)processName {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return;
    
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return;
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return;
    }
    
    size_t count = size / sizeof(struct kinfo_proc);
    
    for (size_t i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        pid_t pid = p->kp_proc.p_pid;
        
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
        int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        if (pathLength > 0) {
            NSString *fullPath = [NSString stringWithUTF8String:pathBuffer];
            NSString *procName = [fullPath lastPathComponent];
            
            if ([procName isEqualToString:processName]) {
                TVLog(@"Killing %@ (pid: %d)", procName, pid);
                kill(pid, SIGTERM);
            }
        }
    }
    
    free(procs);
}

// 注销设备（Respring）
- (BOOL)respringDevice {
    @try {
        TVLog(@"Attempting to respring device...");
        
        // 杀死核心系统进程
        [self killall:@"SpringBoard"];   // 主屏幕进程
        [self killall:@"FrontBoard"];   // 前台应用管理进程
        [self killall:@"BackBoard"];    // 后台管理进程
        
        // 如果 killall 都没生效，触发崩溃兜底
        // 检查进程是否还在
        BOOL sbExists = [self processExists:@"SpringBoard"];
        BOOL fbExists = [self processExists:@"FrontBoard"];
        BOOL bbExists = [self processExists:@"BackBoard"];
        
        if (sbExists && fbExists && bbExists) {
            TVLog(@"All processes still alive, triggering crash fallback...");
            // 使用 dispatch_after 延迟 5 秒后退出，避免死循环白白耗 CPU
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                TVLog(@"Crash fallback timeout, exiting...");
                exit(1);
            });
            return YES;
        }
        
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Respring failed: %@", exception.reason);
        return NO;
    }
}

// 检查进程是否存在
- (BOOL)processExists:(NSString *)processName {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return NO;
    }
    
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) {
        return NO;
    }
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return NO;
    }
    
    int count = size / sizeof(struct kinfo_proc);
    BOOL exists = NO;
    
    for (int i = 0; i < count; i++) {
        NSString *procName = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
        if ([procName isEqualToString:processName]) {
            exists = YES;
            break;
        }
    }
    
    free(procs);
    return exists;
}

// 锁定屏幕（锁屏）
- (BOOL)lockDeviceScreen {
    @try {
        TVLog(@"Locking device screen...");

        // 在主线程执行 HID 事件
        if (![NSThread isMainThread]) {
            __block BOOL result = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                result = [self lockDeviceScreen];
            });
            return result;
        }

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        // 使用按电源键方式锁屏（比 hardwareLock 更可靠）
        [generator powerPress];
        TVLog(@"Device screen locked via power press");
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Lock screen failed: %@", exception.reason);
        return NO;
    }
}

// 返回桌面（按一次 Home 键）
- (BOOL)goToHome {
    @try {
        TVLog(@"Going to home screen...");

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        [generator menuPress];
        TVLog(@"Home press sent - going to home screen");
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Go to home failed: %@", exception.reason);
        return NO;
    }
}

// 打开任务管理器（双击 Home 键）
- (BOOL)openTaskManager {
    @try {
        TVLog(@"Opening task manager...");

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        [generator menuDoublePress];
        TVLog(@"Home double press sent - opening task manager");
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Open task manager failed: %@", exception.reason);
        return NO;
    }
}

// 解锁屏幕（按 Home 键唤醒/解锁）
- (BOOL)unlockDeviceScreen {
    @try {
        TVLog(@"Unlocking device screen...");

        // 在主线程执行解锁操作
        if (![NSThread isMainThread]) {
            __block BOOL result = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                result = [self unlockDeviceScreen];
            });
            return result;
        }

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 方法: 按一下 Home 唤醒屏幕，等待 1.5 秒，再按一次 Home 解锁
        [generator menuPress];
        TVLog(@"Home press sent (wake up)");
        
        // 等待 1.5 秒
        struct timespec ts = {1, 500000000}; // 1.5s
        nanosleep(&ts, NULL);
        
        // 再按一次 Home
        [generator menuPress];
        TVLog(@"Home press sent again (unlock)");

        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Unlock screen failed: %@", exception.reason);
        return NO;
    }
}

#pragma mark - 智能清理后台应用

// 运行时取 SBApplication 的 bundleIdentifier（编译期无声明，用 NSInvocation 避免与 SDK 同名方法歧义）
- (NSString *)tvnc_sbsBundleId:(id)app {
    if (!app) return nil;
    SEL sel = @selector(bundleIdentifier);
    if (![app respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [app methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = app;
    inv.selector = sel;
    [inv invoke];
    __unsafe_unretained id ret = nil;
    [inv getReturnValue:&ret];
    return ret;
}

// 诊断版：取前台 App 信息，并记录命中的检测通道（便于真机排障）。
// 返回字典：{ method: NSString, bundleID: NSString|NSNull, pid: NSNumber }。
//
// 重要：trollvncserver 是 daemon（无 UIKit / backboard 应用连接）。
// SpringBoardServices 的 XPC（SBFrontmostApplication*）在我们的 daemon 上下文里经常返回 nil
// （即便加了 com.apple.springboard.appcontrol 也调不通——真机实测 stage:foreground_pid 失败），
// 因此第一优先改用 FrontBoardServices：
//   FBSApplicationWorkspace.defaultWorkspace.runningApplications
// 它走 backboardd 的 FBSSystemService XPC，对 daemon 更可靠，能直接拿到每个前台 App 的
// bundleIdentifier 与 processIdentifier（用 visibility/isActive/isForeground 判断真正的前台）。
- (NSDictionary *)frontmostAppInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"method"] = @"none";
    info[@"bundleID"] = [NSNull null];
    info[@"pid"] = @(-1);

    // ===== Tier 1：FrontBoardServices（走 backboardd XPC，daemon 下最可靠）=====
    Class FBSWS = NSClassFromString(@"FBSApplicationWorkspace");
    if (!FBSWS) FBSWS = NSClassFromString(@"FBApplicationWorkspace");
    if (!FBSWS) FBSWS = NSClassFromString(@"SBApplicationWorkspace");
    if (FBSWS) {
        SEL dw = NSSelectorFromString(@"defaultWorkspace");
        if ([FBSWS respondsToSelector:dw]) {
            id ws = ((id (*)(id, SEL))objc_msgSend)(FBSWS, dw);
            SEL ra = NSSelectorFromString(@"runningApplications");
            if (ws && [ws respondsToSelector:ra]) {
                NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, ra);
                id best = nil;
                int bestScore = -1;
                BOOL (*msgB)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
                for (id a in apps) {
                    int score = 0;
                    if ([a respondsToSelector:NSSelectorFromString(@"visibility")]) {
                        score = [[a valueForKey:@"visibility"] intValue] * 10;
                    }
                    if ([a respondsToSelector:NSSelectorFromString(@"isActive")] &&
                        msgB(a, NSSelectorFromString(@"isActive"))) score += 5;
                    if ([a respondsToSelector:NSSelectorFromString(@"isForeground")] &&
                        msgB(a, NSSelectorFromString(@"isForeground"))) score += 3;
                    if (score > bestScore) { bestScore = score; best = a; }
                }
                if (best && bestScore > 0) {
                    NSString *bid = [best respondsToSelector:@selector(bundleIdentifier)]
                        ? ((NSString *(*)(id, SEL))objc_msgSend)(best, @selector(bundleIdentifier)) : nil;
                    if (bid.length) {
                        info[@"bundleID"] = bid;
                        info[@"method"] = @"FrontBoardServices";
                        int pid = [self tvnc_pidOfInfo:best];
                        if (pid > 0) info[@"pid"] = @(pid);
                        TVLog(@"Frontmost app (FBS): %@ pid=%d", bid, pid);
                        return info;
                    }
                }
            }
        }
    }

    // ===== Tier 2：SpringBoardServices XPC（部分环境可用）=====
    static void *sbs = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    });
    if (sbs) {
        // 1) SBFrontmostApplicationBundleIdentifier() 直接返回 bundle id
        NSString *(*sbFrontBid)(void) = (NSString *(*)(void))dlsym(sbs, "SBFrontmostApplicationBundleIdentifier");
        if (sbFrontBid) {
            NSString *bid = sbFrontBid();
            if (bid.length) {
                info[@"bundleID"] = bid;
                info[@"method"] = @"SBS.BundleID";
                TVLog(@"Frontmost app (SBS.BundleID): %@", bid);
                return info;
            }
        }
        // 2) SBFrontmostApplication() -> SBApplication -> bundleIdentifier
        id (*sbFrontmost)(void) = (id (*)(void))dlsym(sbs, "SBFrontmostApplication");
        if (sbFrontmost) {
            id app = sbFrontmost();
            if (app) {
                NSString *bid = [self tvnc_sbsBundleId:app];
                if (bid.length) {
                    info[@"bundleID"] = bid;
                    info[@"method"] = @"SBS.Frontmost";
                    TVLog(@"Frontmost app (SBS.Frontmost): %@", bid);
                    return info;
                }
            }
        }
    }

    // ===== Tier 3：老 API（部分越狱/旧环境可用）=====
    CFStringRef frontmostAppID = SBSCopyFrontmostApplicationDisplayIdentifier();
    if (frontmostAppID) {
        NSString *bundleID = (__bridge_transfer NSString *)frontmostAppID;
        info[@"bundleID"] = bundleID;
        info[@"method"] = @"SBS.legacy";
        TVLog(@"Frontmost app (SBS legacy): %@", bundleID);
        return info;
    }

    // ===== Tier 4：sysctl 枚举 /Applications 下的用户进程（最后兜底）=====
    // 用户空间 App 通常排在 procs 末尾，从后往前取第一个 /Applications/ 下的进程作为前台候选。
    @try {
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) == 0 && size > 0) {
            struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
            if (procs && sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
                int count = (int)(size / sizeof(struct kinfo_proc));
                for (int i = count - 1; i >= 0; i--) {
                    if (procs[i].kp_proc.p_stat == SRUN) {
                        pid_t pid = procs[i].kp_proc.p_pid;
                        char pathBuf[4096] = {0};  // PROC_PIDPATH_MAXSIZE (4*MAXPATHLEN)，部分 SDK 未导出该宏，用字面值
                        if (proc_pidpath(pid, pathBuf, sizeof(pathBuf)) > 0) {
                            NSString *procPath = [NSString stringWithUTF8String:pathBuf];
                            if ([procPath hasPrefix:@"/Applications/"]) {
                                NSString *appName = [[procPath lastPathComponent] stringByDeletingPathExtension];
                                if (appName.length) {
                                    info[@"bundleID"] = appName;
                                    info[@"pid"] = @(pid);
                                    info[@"method"] = @"sysctl";
                                    TVLog(@"Frontmost app (sysctl): %@ from %@", appName, procPath);
                                    free(procs);
                                    return info;
                                }
                            }
                        }
                    }
                }
            }
            free(procs);
        }
    } @catch (NSException *e) {
        TVLog(@"sysctl process scan failed: %@", e.reason);
    }

    TVLog(@"Frontmost app: all methods returned nil");
    return info;
}

// 从 FBS/SBS 的 app info 对象取进程号（兼容 processIdentifier / pid 两种属性名）。
- (int)tvnc_pidOfInfo:(id)info {
    SEL sel = @selector(processIdentifier);
    if (![info respondsToSelector:sel]) {
        sel = @selector(pid);
        if (![info respondsToSelector:sel]) return -1;
    }
    NSMethodSignature *sig = [info methodSignatureForSelector:sel];
    if (!sig || sig.methodReturnLength == 0) return -1;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    [inv invokeWithTarget:info];
    int val = 0;
    [inv getReturnValue:&val];
    return val;
}

// 获取当前前台应用的 Bundle ID（FBS 优先，SBS XPC 与 legacy 兜底）
- (NSString *)getFrontmostAppBundleID {
    NSDictionary *info = [self frontmostAppInfo];
    id bid = info[@"bundleID"];
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

// 检查是否在桌面（SpringBoard）
//
// daemon 下 [UIApplication sharedApplication] 返回 nil（没有 UIKit 应用环境），
// 旧实现据此直接 return YES 会“永远判定在桌面”。改为以 frontmostBundleID 为主，
// UIApplication 状态仅作最后兜底（且必须 app 真实存在时才用它）。
- (BOOL)isOnSpringBoard {
    // 优先用前台 App Bundle ID 判断
    NSString *frontmostBundleID = [self getFrontmostAppBundleID];
    TVLog(@"isOnSpringBoard: frontmostBundleID = %@", frontmostBundleID);

    if (frontmostBundleID.length) {
        if ([frontmostBundleID isEqualToString:@"com.apple.springboard"] ||
            [frontmostBundleID isEqualToString:@"SpringBoard"]) {
            TVLog(@"isOnSpringBoard: Detected SpringBoard");
            return YES;
        }
        NSArray *systemApps = @[
            @"com.apple.springboard",
            @"com.apple.PineBoard",  // tvOS SpringBoard
            @"com.apple.home.screen",  // iPadOS 可能的桌面标识
            @"com.apple.Home.HomeScreen"
        ];
        for (NSString *systemApp in systemApps) {
            if ([frontmostBundleID isEqualToString:systemApp]) {
                TVLog(@"isOnSpringBoard: Detected system app %@", systemApp);
                return YES;
            }
        }
        TVLog(@"isOnSpringBoard: Not on SpringBoard, frontmost app is %@", frontmostBundleID);
        return NO;
    }

    // 拿不到前台 App：daemon 下 UIApplication 为 nil，不能再据此误判为桌面
    UIApplication *app = [UIApplication sharedApplication];
    if (app && [app applicationState] == UIApplicationStateBackground) {
        TVLog(@"isOnSpringBoard: Could not get frontmost app, but app is in background -> not on SpringBoard");
        return NO;
    }
    TVLog(@"isOnSpringBoard: Assuming on SpringBoard (fallback)");
    return YES;
}

// 智能清理后台应用（force=NO：在桌面则跳过；force=YES：即使桌面也强制清理）
- (NSDictionary *)clearBackgroundAppsSmart {
    return [self clearBackgroundAppsSmartForce:NO];
}

- (NSDictionary *)clearBackgroundAppsSmartForce:(BOOL)force {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"force"] = @(force);

    @try {
        TVLog(@"Smart clear: Starting... (force=%d)", force);

        // 获取当前前台应用
        NSString *frontmostApp = [self getFrontmostAppBundleID];
        result[@"frontmostApp"] = frontmostApp ?: @"unknown";
        TVLog(@"Smart clear: frontmostApp = %@", frontmostApp);

        BOOL isSpringBoard = !frontmostApp ||
            [frontmostApp isEqualToString:@"com.apple.springboard"] ||
            [frontmostApp isEqualToString:@"SpringBoard"];
        result[@"onSpringBoard"] = @(isSpringBoard);

        // 非强制且在桌面：跳过
        if (isSpringBoard && !force) {
            result[@"success"] = @YES;
            result[@"message"] = @"Already on SpringBoard, no apps to clear";
            result[@"action"] = @"skipped";
            TVLog(@"Smart clear: Skipped - already on SpringBoard");
            return result;
        }

        // 必须在主线程执行 HID 事件
        if (![NSThread isMainThread]) {
            __block NSDictionary *syncResult = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                syncResult = [self clearBackgroundAppsSmartForce:force];
            });
            return syncResult ?: result;
        }

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        if (!generator) {
            TVLog(@"Smart clear: Failed - STHIDEventGenerator is nil");
            result[@"success"] = @NO;
            result[@"message"] = @"HID generator not available";
            return result;
        }

        // 强制模式且当前在桌面：直接清理；否则先按 Home 回桌面再清理
        if (!isSpringBoard) {
            TVLog(@"Smart clear: Sending menuPress to go home...");
            [generator menuPress];
            struct timespec ts = {0, 600000000}; // 0.6s
            nanosleep(&ts, NULL);
            result[@"closedApp"] = frontmostApp ?: @"unknown";
        } else {
            TVLog(@"Smart clear: Force mode on SpringBoard, killing background apps directly");
        }

        // 执行后台应用清理（打开多任务 + 上滑杀进程）
        [self performClearBackgroundApps:result];

    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to clear background apps";
        TVLog(@"Smart clear background apps failed: %@", exception.reason);
    }

    return result;
}

// 打开多任务管理器并上滑杀掉后台应用
- (void)performClearBackgroundApps:(NSMutableDictionary *)result {
    STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];

    // 双击 Home 打开多任务管理器
    TVLog(@"Smart clear: Double pressing Home to open app switcher...");
    [generator menuDoublePress];
    struct timespec ts = {0, 800000000}; // 0.8s 等待多任务打开
    nanosleep(&ts, NULL);

    // 获取屏幕尺寸（daemon 下 UIScreen 可能取不到，给一个常见兜底值）
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat screenWidth = screenBounds.size.width;
    CGFloat screenHeight = screenBounds.size.height;
    if (screenWidth < 100 || screenHeight < 100) {
        screenWidth = 390;
        screenHeight = 844;
        TVLog(@"Smart clear: UIScreen bounds invalid, fallback to %gx%g", screenWidth, screenHeight);
    }

    // 向上滑动清理应用（多次滑动覆盖）
    int killed = 0;
    for (int i = 0; i < 6; i++) {
        CGPoint start = CGPointMake(screenWidth / 2, screenHeight * 0.65);
        CGPoint end = CGPointMake(screenWidth / 2, screenHeight * 0.15);
        [generator dragLinearWithStartPoint:start endPoint:end duration:0.3];
        killed++;
        struct timespec wt = {0, 300000000}; // 0.3s 等待动画
        nanosleep(&wt, NULL);
    }

    // 回桌面
    struct timespec ht = {0, 500000000};
    nanosleep(&ht, NULL);
    [generator menuPress];

    result[@"success"] = @YES;
    result[@"message"] = @"Background apps cleared";
    result[@"action"] = @"cleared";
    result[@"killed"] = @(killed);
    TVLog(@"Smart clear: Completed, swiped %d cards", killed);
}


#pragma mark - 文件权限 API

// 将 POSIX 权限模式转换为字符串（如 "drwxr-xr-x"）
static NSString *permissionString(mode_t mode) {
    char str[11] = "----------";
    
    // 文件类型
    if (S_ISDIR(mode)) str[0] = 'd';
    else if (S_ISLNK(mode)) str[0] = 'l';
    else if (S_ISREG(mode)) str[0] = '-';
    else if (S_ISCHR(mode)) str[0] = 'c';
    else if (S_ISBLK(mode)) str[0] = 'b';
    else if (S_ISFIFO(mode)) str[0] = 'p';
    else if (S_ISSOCK(mode)) str[0] = 's';
    
    // Owner 权限
    if (mode & S_IRUSR) str[1] = 'r';
    if (mode & S_IWUSR) str[2] = 'w';
    if (mode & S_IXUSR) str[3] = 'x';
    
    // Group 权限
    if (mode & S_IRGRP) str[4] = 'r';
    if (mode & S_IWGRP) str[5] = 'w';
    if (mode & S_IXGRP) str[6] = 'x';
    
    // Other 权限
    if (mode & S_IROTH) str[7] = 'r';
    if (mode & S_IWOTH) str[8] = 'w';
    if (mode & S_IXOTH) str[9] = 'x';
    
    // Setuid/Setgid/Sticky
    if (mode & S_ISUID) str[3] = (str[3] == 'x') ? 's' : 'S';
    if (mode & S_ISGID) str[6] = (str[6] == 'x') ? 's' : 'S';
    if (mode & S_ISVTX) str[9] = (str[9] == 'x') ? 't' : 'T';
    
    return [NSString stringWithUTF8String:str];
}

@end
