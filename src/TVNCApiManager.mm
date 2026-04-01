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
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>  // 用于 system()
#import <notify.h>  // 用于 notify_post 系统通知
#import <spawn.h>   // 用于 posix_spawn

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

    // 释放旋转后的图像和缓冲区
    if (rotatedImage) {
        // 获取 data provider 的数据指针
        CGDataProviderRef rProvider = CGImageGetDataProvider(rotatedImage);
        void *providerData = NULL;
        if (rProvider) {
            CFDataRef data = CGDataProviderCopyData(rProvider);
            if (data) {
                providerData = (void *)CFDataGetBytePtr(data);
                CFRelease(data);
            }
        }
        CGImageRelease(rotatedImage);
        // 释放旋转缓冲区内存
        if (providerData) {
            free(providerData);
        }
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

#pragma mark - 系统控制 API

// 清理后台应用
- (BOOL)clearBackgroundApps {
    // 在主线程执行
    if (![NSThread isMainThread]) {
        __block BOOL result = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = [self clearBackgroundApps];
        });
        return result;
    }
    
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        
        // 使用双击 Home 键打开应用切换器
        [generator menuDoublePress];
        
        // 等待应用切换器打开
        [NSThread sleepForTimeInterval:0.8];
        
        // 使用上滑手势关闭应用
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        
        CGPoint startPoint = CGPointMake(screenWidth / 2, screenHeight - 100);
        CGPoint endPoint = CGPointMake(screenWidth / 2, screenHeight / 3);
        
        [generator dragLinearWithStartPoint:startPoint endPoint:endPoint duration:0.3];
        
        // 等待关闭动画完成
        [NSThread sleepForTimeInterval:0.5];
        
        // 点击 Home 键返回桌面
        [generator menuPress];
        
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Clear background apps failed: %@", exception.reason);
        return NO;
    }
}

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
            [NSThread sleepForTimeInterval:0.05];
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
            [NSThread sleepForTimeInterval:0.05];
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
    return [self trollStoreHelperPath] != nil;
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
        TVLog(@"Attempting to reboot device (iOS 15)...");
        
        // iOS 15 上 TrollStore 环境使用以下方式重启
        // 方法1: 使用 notify 触发系统重启
        int ret = notify_post("com.apple.system.reboot");
        TVLog(@"notify_post(com.apple.system.reboot) returned: %d", ret);
        if (ret == NOTIFY_STATUS_OK) {
            TVLog(@"Reboot notification sent successfully");
            return YES;
        }
        
        // 方法3: 尝试其他重启通知
        ret = notify_post("com.apple.mobile.reboot");
        TVLog(@"notify_post(com.apple.mobile.reboot) returned: %d", ret);
        if (ret == NOTIFY_STATUS_OK) {
            TVLog(@"Mobile reboot notification sent successfully");
            return YES;
        }
        
        // 方法4: 使用 posix_spawn 执行 reboot 命令
        TVLog(@"Trying posix_spawn /sbin/reboot...");
        pid_t pid;
        const char *args[] = {"/sbin/reboot", NULL};
        int status = posix_spawn(&pid, "/sbin/reboot", NULL, NULL, (char **)args, NULL);
        TVLog(@"posix_spawn returned: %d", status);
        if (status == 0) {
            TVLog(@"Reboot command executed");
            return YES;
        }
        
        TVLog(@"All reboot methods failed");
        return NO;
    } @catch (NSException *exception) {
        TVLog(@"Reboot failed: %@", exception.reason);
        return NO;
    }
}

// 注销设备（Respring）
- (BOOL)respringDevice {
    @try {
        TVLog(@"Attempting to respring device (iOS 15)...");
        
        // iOS 15 上 killall SpringBoard 是最可靠的方法
        // 方法1: 使用 posix_spawn 执行 killall SpringBoard
        TVLog(@"Trying posix_spawn killall SpringBoard...");
        pid_t pid;
        const char *killArgs[] = {"/usr/bin/killall", "-9", "SpringBoard", NULL};
        int killStatus = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char **)killArgs, NULL);
        TVLog(@"posix_spawn(killall SpringBoard) returned: %d", killStatus);
        if (killStatus == 0) {
            TVLog(@"SpringBoard killed, respring initiated");
            return YES;
        }
        
        // 方法2: 尝试 killall backboardd（也会触发 respring）
        TVLog(@"Trying posix_spawn killall backboardd...");
        const char *bbArgs[] = {"/usr/bin/killall", "-9", "backboardd", NULL};
        killStatus = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char **)bbArgs, NULL);
        TVLog(@"posix_spawn(killall backboardd) returned: %d", killStatus);
        if (killStatus == 0) {
            TVLog(@"BackBoard killed, respring initiated");
            return YES;
        }
        
        // 方法3: 使用 notify_post 触发 respring
        int ret = notify_post("com.apple.springboard.respring");
        TVLog(@"notify_post(com.apple.springboard.respring) returned: %d", ret);
        if (ret == NOTIFY_STATUS_OK) {
            TVLog(@"Respring notification sent successfully");
            return YES;
        }
        
        // 方法4: 尝试其他 respring 通知
        ret = notify_post("com.apple.springboard.Restart");
        TVLog(@"notify_post(com.apple.springboard.Restart) returned: %d", ret);
        if (ret == NOTIFY_STATUS_OK) {
            TVLog(@"SpringBoard restart notification sent successfully");
            return YES;
        }
        
        // 方法5: 使用 popen 执行 killall SpringBoard（iOS 不支持 NSTask）
        TVLog(@"Trying popen killall SpringBoard...");
        FILE *fp = popen("killall -9 SpringBoard 2>&1", "r");
        if (fp) {
            char buffer[256];
            while (fgets(buffer, sizeof(buffer), fp) != NULL) {
                TVLog(@"killall output: %s", buffer);
            }
            int ret = pclose(fp);
            TVLog(@"popen killall returned: %d", ret);
            if (ret == 0) {
                TVLog(@"SpringBoard killed via popen, respring initiated");
                return YES;
            }
        }

        // 方法6: HID 按 Power 键（可能触发锁屏或电源菜单）
        // HID 操作需要在主线程
        if ([NSThread isMainThread]) {
            STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
            TVLog(@"Trying HID power press...");
            [generator powerPress];
            struct timespec halfSec = {0, (long)(0.5 * 1e9)};
            nanosleep(&halfSec, 0);
            TVLog(@"Trying HID menu press...");
            [generator menuPress];
        } else {
            __block BOOL hidResult = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                hidResult = [self respringDeviceHID];
            });
            if (hidResult) return YES;
        }

        TVLog(@"All respring methods failed");
        return NO;
    } @catch (NSException *exception) {
        TVLog(@"Respring failed: %@", exception.reason);
        return NO;
    }
}

// HID 注销方法（主线程调用）
- (BOOL)respringDeviceHID {
    @try {
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];

        // 方法A: Home+Power 长按 10 秒（强制关机/重启）
        TVLog(@"Trying HID Home+Power long press (10s)...");

        // 同时按下 Home 和 Power
        [generator menuDown];
        [generator powerDown];

        // 等待 10 秒
        struct timespec tenSec = {10, 0};
        nanosleep(&tenSec, 0);

        // 松开 Power（Home 保持）
        [generator powerUp];
        TVLog(@"Power released after 10s");

        // 再等 0.5 秒后松开 Home
        struct timespec halfSec = {0, (long)(0.5 * 1e9)};
        nanosleep(&halfSec, 0);
        [generator menuUp];
        TVLog(@"Home released");

        TVLog(@"HID Home+Power respring attempted");
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"HID respring failed: %@", exception.reason);
        return NO;
    }
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
        [generator hardwareLock];
        TVLog(@"Device screen locked");
        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Lock screen failed: %@", exception.reason);
        return NO;
    }
}

// 解锁屏幕（唤醒 + 滑动解锁）
- (BOOL)unlockDeviceScreen {
    @try {
        TVLog(@"Unlocking device screen...");

        // 在主线程执行 HID 事件
        if (![NSThread isMainThread]) {
            __block BOOL result = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                result = [self unlockDeviceScreen];
            });
            return result;
        }

        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];

        // Step 1: 唤醒屏幕（AC Unlock）
        [generator hardwareUnlock];
        TVLog(@"Screen wake event sent");

        // Step 2: 等待锁屏界面出现
        struct timespec waitDelay = {0, (long)(0.5 * 1e9)};
        nanosleep(&waitDelay, 0);

        // Step 3: 按一次 Home
        [generator menuPress];
        TVLog(@"Home press 1 sent");

        // Step 4: 等待 1.5 秒
        struct timespec delay15 = {1, (long)(0.5 * 1e9)};
        nanosleep(&delay15, 0);

        // Step 5: 再按一次 Home
        [generator menuPress];
        TVLog(@"Home press 2 sent");

        return YES;
    } @catch (NSException *exception) {
        TVLog(@"Unlock screen failed: %@", exception.reason);
        return NO;
    }
}

#pragma mark - 智能清理后台应用

// 获取当前前台应用的 Bundle ID
- (NSString *)getFrontmostAppBundleID {
    // 方法1: 使用 SpringBoardServices 私有 API 获取前台应用
    // 在 iOS 15 上这个 API 是可用的
    CFStringRef frontmostAppID = SBSCopyFrontmostApplicationDisplayIdentifier();
    if (frontmostAppID) {
        NSString *bundleID = (__bridge_transfer NSString *)frontmostAppID;
        TVLog(@"Frontmost app (via SBS): %@", bundleID);
        return bundleID;
    }
    
    TVLog(@"Frontmost app: SBSCopyFrontmostApplicationDisplayIdentifier returned nil");
    
    // 方法2: 尝试使用 FrontBoardServices（如果可用）
    // 方法3: 返回 nil 让调用者处理
    return nil;
}

// 检查是否在桌面（SpringBoard）
- (BOOL)isOnSpringBoard {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        TVLog(@"isOnSpringBoard: UIApplication is nil, assuming on SpringBoard");
        return YES;
    }
    
    // 获取当前前台应用的 Bundle ID
    NSString *frontmostBundleID = [self getFrontmostAppBundleID];
    TVLog(@"isOnSpringBoard: frontmostBundleID = %@", frontmostBundleID);
    
    // 如果无法获取前台应用，尝试通过应用状态判断
    if (!frontmostBundleID) {
        // 检查当前应用是否在后台
        UIApplicationState state = [app applicationState];
        TVLog(@"isOnSpringBoard: Could not get frontmost app, current app state = %ld", (long)state);
        
        // 如果当前应用在后台，可能用户在看别的应用
        // 如果在前台，可能是 SpringBoard
        if (state == UIApplicationStateBackground) {
            TVLog(@"isOnSpringBoard: App in background, assuming not on SpringBoard");
            return NO;
        }
        
        // 无法确定，默认假设在桌面（跳过清理）
        TVLog(@"isOnSpringBoard: Assuming on SpringBoard (fallback)");
        return YES;
    }
    
    // 如果是 SpringBoard 或者 com.apple.springboard，说明在桌面
    if ([frontmostBundleID isEqualToString:@"com.apple.springboard"] ||
        [frontmostBundleID isEqualToString:@"SpringBoard"]) {
        TVLog(@"isOnSpringBoard: Detected SpringBoard");
        return YES;
    }
    
    // 检查是否是系统应用（在桌面上运行的）
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

// 智能清理后台应用
- (NSDictionary *)clearBackgroundAppsSmart {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        TVLog(@"Smart clear: Starting...");
        
        // 检查是否在桌面
        BOOL onSpringBoard = [self isOnSpringBoard];
        result[@"onSpringBoard"] = @(onSpringBoard);
        TVLog(@"Smart clear: onSpringBoard = %d", onSpringBoard);
        
        if (onSpringBoard) {
            result[@"success"] = @YES;
            result[@"message"] = @"Already on SpringBoard, no apps to clear";
            result[@"action"] = @"skipped";
            TVLog(@"Smart clear: Skipped - already on SpringBoard");
            return result;
        }
        
        // 获取当前前台应用
        NSString *frontmostApp = [self getFrontmostAppBundleID];
        result[@"frontmostApp"] = frontmostApp ?: @"unknown";
        TVLog(@"Smart clear: frontmostApp = %@", frontmostApp);
        
        // 执行清理操作
        STHIDEventGenerator *generator = [STHIDEventGenerator sharedGenerator];
        if (!generator) {
            TVLog(@"Smart clear: Failed - STHIDEventGenerator is nil");
            result[@"success"] = @NO;
            result[@"message"] = @"HID generator not available";
            return result;
        }
        
        // 双击 Home 键打开应用切换器
        TVLog(@"Smart clear: Sending menuDoublePress...");
        [generator menuDoublePress];
        [NSThread sleepForTimeInterval:0.8];
        
        // 获取屏幕尺寸
        CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
        CGFloat screenHeight = [UIScreen mainScreen].bounds.size.height;
        TVLog(@"Smart clear: Screen size = %.0f x %.0f", screenWidth, screenHeight);
        
        // 上滑关闭当前应用
        CGPoint startPoint = CGPointMake(screenWidth / 2, screenHeight - 100);
        CGPoint endPoint = CGPointMake(screenWidth / 2, screenHeight / 3);
        
        TVLog(@"Smart clear: Sending swipe gesture...");
        [generator dragLinearWithStartPoint:startPoint endPoint:endPoint duration:0.3];
        [NSThread sleepForTimeInterval:0.5];
        
        // 返回桌面
        TVLog(@"Smart clear: Sending menuPress to return home...");
        [generator menuPress];
        
        result[@"success"] = @YES;
        result[@"message"] = @"Background apps cleared";
        result[@"action"] = @"cleared";
        result[@"closedApp"] = frontmostApp ?: @"unknown";
        
        TVLog(@"Smart clear: Completed successfully");
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to clear background apps";
        TVLog(@"Smart clear background apps failed: %@", exception.reason);
    }
    
    return result;
}

#pragma mark - AssistiveTouch 控制

// 获取 AssistiveTouch 当前状态
- (NSDictionary *)getAssistiveTouchStatus {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        // 读取系统 Accessibility 设置
        NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        
        BOOL isEnabled = NO;
        id value = plist[@"AssistiveTouchEnabled"];
        if (value) {
            isEnabled = [value boolValue];
        }
        
        result[@"success"] = @YES;
        result[@"enabled"] = @(isEnabled);
        result[@"message"] = isEnabled ? @"AssistiveTouch is enabled" : @"AssistiveTouch is disabled";
        
        TVLog(@"AssistiveTouch status: %@", isEnabled ? @"enabled" : @"disabled");
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to get AssistiveTouch status";
        TVLog(@"Get AssistiveTouch status failed: %@", exception.reason);
    }
    
    return result;
}

// 禁用 AssistiveTouch（修改系统 plist）
- (NSDictionary *)disableAssistiveTouchPermanent {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        
        // 读取现有 plist
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) {
            plist = [NSMutableDictionary dictionary];
        }
        
        // 记录原始值
        id originalValue = plist[@"AssistiveTouchEnabled"];
        BOOL wasEnabled = originalValue ? [originalValue boolValue] : NO;
        
        // 设置禁用
        plist[@"AssistiveTouchEnabled"] = @NO;
        
        // 同时禁用相关功能
        plist[@"AssistiveTouchTouchEnabled"] = @NO;
        plist[@"AssistiveTouchMouseEnabled"] = @NO;
        
        // 写入 plist
        BOOL writeSuccess = [plist writeToFile:plistPath atomically:YES];
        
        if (!writeSuccess) {
            result[@"success"] = @NO;
            result[@"error"] = @"Failed to write plist file";
            result[@"message"] = @"Could not modify Accessibility settings";
            TVLog(@"Failed to write Accessibility plist");
            return result;
        }
        
        // 修改文件权限（确保系统能读取）
        chmod([plistPath UTF8String], 0644);
        
        // 杀掉 accessibilityd 进程让设置生效
        // 使用 notify 通知系统设置变更
        notify_post("com.apple.accessibility.settings.changed");
        
        // 尝试杀掉 AssistiveTouch 服务进程（使用 popen 代替 system）
        FILE *fp1 = popen("killall -9 AssistiveTouch 2>/dev/null", "r");
        if (fp1) pclose(fp1);
        FILE *fp2 = popen("killall -9 accessibilityd 2>/dev/null", "r");
        if (fp2) pclose(fp2);
        
        result[@"success"] = @YES;
        result[@"wasEnabled"] = @(wasEnabled);
        result[@"message"] = @"AssistiveTouch has been disabled permanently";
        result[@"warning"] = @"Settings modified at /var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        
        TVLog(@"AssistiveTouch disabled permanently (was enabled: %d)", wasEnabled);
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to disable AssistiveTouch";
        TVLog(@"Disable AssistiveTouch failed: %@", exception.reason);
    }
    
    return result;
}

// 启用 AssistiveTouch（恢复系统 plist）
- (NSDictionary *)enableAssistiveTouchPermanent {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        
        // 读取现有 plist
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) {
            plist = [NSMutableDictionary dictionary];
        }
        
        // 记录原始值
        id originalValue = plist[@"AssistiveTouchEnabled"];
        BOOL wasEnabled = originalValue ? [originalValue boolValue] : NO;
        
        // 设置启用
        plist[@"AssistiveTouchEnabled"] = @YES;
        plist[@"AssistiveTouchTouchEnabled"] = @YES;
        
        // 写入 plist
        BOOL writeSuccess = [plist writeToFile:plistPath atomically:YES];
        
        if (!writeSuccess) {
            result[@"success"] = @NO;
            result[@"error"] = @"Failed to write plist file";
            result[@"message"] = @"Could not modify Accessibility settings";
            TVLog(@"Failed to write Accessibility plist");
            return result;
        }
        
        // 修改文件权限
        chmod([plistPath UTF8String], 0644);
        
        // 通知系统设置变更
        notify_post("com.apple.accessibility.settings.changed");
        
        result[@"success"] = @YES;
        result[@"wasEnabled"] = @(wasEnabled);
        result[@"message"] = @"AssistiveTouch has been enabled permanently";
        
        TVLog(@"AssistiveTouch enabled permanently (was enabled: %d)", wasEnabled);
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to enable AssistiveTouch";
        TVLog(@"Enable AssistiveTouch failed: %@", exception.reason);
    }
    
    return result;
}

// 锁定 AssistiveTouch（禁用 + 锁死 plist 为只读）
- (NSDictionary *)lockAssistiveTouch {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        // 先禁用
        NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) {
            plist = [NSMutableDictionary dictionary];
        }
        
        // 禁用 AssistiveTouch
        plist[@"AssistiveTouchEnabled"] = @NO;
        plist[@"AssistiveTouchTouchEnabled"] = @NO;
        plist[@"AssistiveTouchMouseEnabled"] = @NO;
        
        // 写入 plist
        if (![plist writeToFile:plistPath atomically:YES]) {
            result[@"success"] = @NO;
            result[@"message"] = @"Failed to write plist file";
            TVLog(@"Lock AssistiveTouch failed: cannot write plist");
            return result;
        }
        
        // 同步偏好设置
        FILE *syncFp = popen("sync", "r");
        if (syncFp) pclose(syncFp);
        
        // 锁死文件为只读（444）
        FILE *fp = popen("chmod 444 /var/mobile/Library/Preferences/com.apple.Accessibility.plist 2>/dev/null", "r");
        if (fp) pclose(fp);
        
        // 发送通知
        notify_post("com.apple.accessibility.settings.changed");

        // 注销设备让 SpringBoard 重启，悬浮球立即消失
        BOOL respringSuccess = [self respringDevice];

        // Respring 后等待 30 秒再解锁屏幕
        if (respringSuccess) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                TVLog(@"AssistiveTouch lock: respring done, unlocking screen after 30s");
                [self unlockDeviceScreen];
            });
        }

        result[@"success"] = @YES;
        result[@"message"] = @"AssistiveTouch locked";
        result[@"warning"] = @"Screen will unlock after 30 seconds";
        
        TVLog(@"AssistiveTouch locked successfully");
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to lock AssistiveTouch";
        TVLog(@"Lock AssistiveTouch failed: %@", exception.reason);
    }
    
    return result;
}

// 解锁 AssistiveTouch（解锁 plist + 启用）
- (NSDictionary *)unlockAssistiveTouch {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    @try {
        NSString *plistPath = @"/var/mobile/Library/Preferences/com.apple.Accessibility.plist";
        
        // 先解锁文件为可写（644）
        FILE *fp = popen("chmod 644 /var/mobile/Library/Preferences/com.apple.Accessibility.plist 2>/dev/null", "r");
        if (fp) pclose(fp);
        
        // 读取 plist
        NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
        if (!plist) {
            plist = [NSMutableDictionary dictionary];
        }
        
        // 启用 AssistiveTouch
        plist[@"AssistiveTouchEnabled"] = @YES;
        plist[@"AssistiveTouchTouchEnabled"] = @YES;
        
        // 写入 plist
        if (![plist writeToFile:plistPath atomically:YES]) {
            result[@"success"] = @NO;
            result[@"message"] = @"Failed to write plist file";
            TVLog(@"Unlock AssistiveTouch failed: cannot write plist");
            return result;
        }
        
        // 同步
        FILE *syncFp = popen("sync", "r");
        if (syncFp) pclose(syncFp);
        
        // 发送通知
        notify_post("com.apple.accessibility.settings.changed");

        // 注销设备让 SpringBoard 重启，AssistiveTouch 悬浮球立即显示
        BOOL respringSuccess = [self respringDevice];

        // Respring 后等待 30 秒再解锁屏幕
        if (respringSuccess) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                TVLog(@"AssistiveTouch unlock: respring done, unlocking screen after 30s");
                [self unlockDeviceScreen];
            });
        }

        result[@"success"] = @YES;
        result[@"message"] = @"AssistiveTouch unlocked and enabled";
        result[@"warning"] = @"Screen will unlock after 30 seconds";

        TVLog(@"AssistiveTouch unlocked successfully");
        
    } @catch (NSException *exception) {
        result[@"success"] = @NO;
        result[@"error"] = exception.reason;
        result[@"message"] = @"Failed to unlock AssistiveTouch";
        TVLog(@"Unlock AssistiveTouch failed: %@", exception.reason);
    }
    
    return result;
}

@end
