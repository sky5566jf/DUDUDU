//
//  TVNCHttpServer+Screenshot.mm
//  Auto-split from TVNCHttpServer.mm (P3 maintainability refactor, 2026-07-20)
//  P2-1: 双路径统一为 handleScreenshotWithQuery:strategy: (2026-07-21)
//
#import "TVNCHttpServer+Handlers.h"

// P2-1: 截图策略枚举 — 统一两条截图路径
typedef NS_ENUM(NSInteger, TVNCScreenshotStrategy) {
    TVNCScreenshotStrategyAuto,   // UIKit 优先 + framebuffer 兜底（原 handleScreenshot）
    TVNCScreenshotStrategyFast,   // framebuffer 优先 + UIKit 兜底（原 handleScreenshotFast）
};

@interface TVNCHttpServer (Screenshot)
- (TVNCHttpResponse *)handleScreenshotWithQuery:(NSDictionary *)query strategy:(TVNCScreenshotStrategy)strategy;
@end

@implementation TVNCHttpServer (Screenshot)

#pragma mark - P2-1: 统一截图入口

// 统一截图方法 — 消除 handleScreenshot / handleScreenshotFast 的重复参数解析和响应构建。
// strategy=Auto: UIKit 优先，framebuffer 兜底（原 /api/screenshot）
// strategy=Fast: framebuffer 优先，UIKit 兜底（原 /api/screenshot/fast）
- (TVNCHttpResponse *)handleScreenshotWithQuery:(NSDictionary *)query strategy:(TVNCScreenshotStrategy)strategy {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    // --- 统一参数解析（兼容两种参数风格）---
    NSString *format;
    CGFloat quality;
    CGFloat scale = 1.0;
    NSInteger rotation = 0;
    int maxW = 0, maxH = 0;

    if (strategy == TVNCScreenshotStrategyFast) {
        // Fast 路径: 默认 jpeg/0.6，支持 q/quality 双别名 + maxw/maxh
        format = query[@"fmt"] ?: query[@"format"] ?: @"jpeg";
        quality = 0.6;
        NSString *qStr = query[@"q"] ?: query[@"quality"];
        if (qStr) { quality = [qStr floatValue]; quality = MAX(0.0, MIN(1.0, quality)); }
    } else {
        // Auto 路径: 默认 png/0.9，支持 rotation
        format = query[@"format"] ?: @"png";
        quality = 0.9;
        NSString *qStr = query[@"quality"];
        if (qStr) { quality = [qStr floatValue]; quality = MAX(0.0, MIN(1.0, quality)); }
        // 旋转参数（仅 Auto 路径支持）
        NSString *rotStr = query[@"rotation"];
        if (rotStr) {
            rotation = [rotStr integerValue];
            rotation = ((rotation % 360) + 360) % 360;  // 规范化
            rotation = (rotation / 90) * 90;             // 对齐到 0/90/180/270
        }
    }

    // 缩放参数（两条路径都支持）
    NSString *scaleStr = query[@"scale"];
    if (scaleStr) { scale = [scaleStr floatValue]; scale = MAX(0.1, MIN(1.0, scale)); }

    // maxW/maxH（仅 Fast 路径支持）
    if (strategy == TVNCScreenshotStrategyFast) {
        if (query[@"maxw"]) maxW = [query[@"maxw"] intValue];
        if (query[@"maxh"]) maxH = [query[@"maxh"] intValue];
    }

    BOOL isPng = [format.lowercaseString containsString:@"png"];
    NSString *contentType = isPng ? @"image/png" : @"image/jpeg";

    // --- 策略派发：根据策略选择主路径 + 兜底路径 ---
    NSData *imageData = nil;

    if (strategy == TVNCScreenshotStrategyFast) {
        // Fast: framebuffer 优先
        if ([[TVNCApiManager sharedManager] isFramebufferAvailable]) {
            imageData = [[TVNCApiManager sharedManager]
                captureScreenshotFromFramebufferWithFormat:format
                                                   quality:quality
                                                     scale:scale
                                                      maxW:maxW
                                                      maxH:maxH];
        }
        // P2-2: 空帧体积守卫 — <1KB 判定为空帧
        if (imageData && imageData.length < 1024) {
            TVLog(@"[screenshot] Empty frame from framebuffer (%lu bytes), falling back to UIKit",
                  (unsigned long)imageData.length);
            imageData = nil;
        }
        // 兜底: UIKit 截图
        if (!imageData) {
            if (scale < 1.0) {
                imageData = [[TVNCApiManager sharedManager]
                    captureScreenshotWithFormat:format quality:quality rotation:0 scale:scale];
            } else {
                imageData = isPng
                    ? [[TVNCApiManager sharedManager] captureScreenshotAsPNG]
                    : [[TVNCApiManager sharedManager] captureScreenshotAsJPEGWithQuality:quality];
            }
        }
    } else {
        // Auto: UIKit 优先
        if (scale < 1.0 || rotation != 0) {
            imageData = [[TVNCApiManager sharedManager]
                captureScreenshotWithFormat:format quality:quality rotation:rotation scale:scale];
        } else {
            imageData = isPng
                ? [[TVNCApiManager sharedManager] captureScreenshotAsPNG]
                : [[TVNCApiManager sharedManager] captureScreenshotAsJPEGWithQuality:quality];
        }
        // P2-2: 空帧体积守卫 — <1KB 判定为空帧
        if (imageData && imageData.length < 1024) {
            TVLog(@"[screenshot] Empty frame from UIKit (%lu bytes), falling back to framebuffer",
                  (unsigned long)imageData.length);
            imageData = nil;
        }
        // 兜底: framebuffer（App 后台/锁屏时 UIKit 返回 nil）
        if (!imageData && [[TVNCApiManager sharedManager] isFramebufferAvailable]) {
            imageData = [[TVNCApiManager sharedManager]
                captureScreenshotFromFramebufferWithFormat:format
                                                   quality:quality
                                                     scale:scale
                                                      maxW:0
                                                      maxH:0];
            if (imageData) {
                TVLog(@"[screenshot] UIKit 失败，已回退 VNC 帧缓冲兜底");
            }
        }
    }

    // --- 统一响应构建 ---
    if (imageData) {
        response.statusCode = 200;
        response.contentType = contentType;
        response.body = imageData;
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Screenshot failed"} options:0 error:nil];
    }

    return response;
}

// 原接口保持兼容 — 薄包装，委托给统一方法
- (TVNCHttpResponse *)handleScreenshot:(NSDictionary *)query {
    return [self handleScreenshotWithQuery:query strategy:TVNCScreenshotStrategyAuto];
}

- (TVNCHttpResponse *)handleScreenshotFast:(NSDictionary *)query {
    return [self handleScreenshotWithQuery:query strategy:TVNCScreenshotStrategyFast];
}

- (TVNCHttpResponse *)handleStreamMjpeg:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    response.statusCode = 200;
    response.contentType = @"multipart/x-mixed-replace; boundary=frameboundary";

    // 将 MJPEG 参数编码到 body 中（JSON 格式，由 handle 方法解析）
    NSMutableDictionary *mjpegParams = [NSMutableDictionary dictionary];
    mjpegParams[@"q"] = @(0.6);
    if (query[@"q"] ?: query[@"quality"]) {
        CGFloat q = [(query[@"q"] ?: query[@"quality"]) floatValue];
        mjpegParams[@"q"] = @(q);
    }
    mjpegParams[@"scale"] = @(1.0);
    if (query[@"scale"]) {
        mjpegParams[@"scale"] = @([query[@"scale"] floatValue]);
    }
    mjpegParams[@"fps"] = @(10);
    if (query[@"fps"]) {
        int fps = [query[@"fps"] intValue];
        if (fps < 1) fps = 1;
        if (fps > 30) fps = 30;
        mjpegParams[@"fps"] = @(fps);
    }
    mjpegParams[@"maxw"] = @(0);
    if (query[@"maxw"]) mjpegParams[@"maxw"] = @([query[@"maxw"] intValue]);
    mjpegParams[@"maxh"] = @(0);
    if (query[@"maxh"]) mjpegParams[@"maxh"] = @([query[@"maxh"] intValue]);

    // 使用特殊标记 "__MJPEG_STREAM__" 让 handle 方法识别
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:mjpegParams options:0 error:nil];
    NSMutableData *markerData = [NSMutableData dataWithData:[@"__MJPEG_STREAM__" dataUsingEncoding:NSUTF8StringEncoding]];
    [markerData appendData:jsonData];
    response.body = markerData;

    return response;
}

- (TVNCHttpResponse *)handleCheckFile {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *filePath = @"/var/mobile/Media/zhuangtai.txt";
    
    // 使用 POSIX access 函数检查文件是否存在
    BOOL fileExists = (access([filePath UTF8String], F_OK) == 0);
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    
    if (fileExists) {
        NSDictionary *result = @{@"status": @"ok", @"message": @"File exists", @"path": filePath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        NSDictionary *result = @{@"status": @"no", @"message": @"File not found", @"path": filePath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

- (TVNCHttpResponse *)handleDeviceInfo:(NSDictionary *)query clientAddr:(NSString *)clientAddr {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 获取设备名称 (v3.41: 使用 tvncGetRealDeviceName 修复 iOS 16+ daemon 上下文返回 "iPhone" 的问题)
    NSString *deviceName = tvncGetRealDeviceName();
    
    // 获取系统版本
    NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
    
    // 获取设备型号标识符 (如 iPhone15,2)
    NSString *deviceModel = nil;
    struct utsname systemInfo;
    uname(&systemInfo);
    deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    
    // 获取设备UUID (作为设备ID)
    // 优先读取 .matisu_device_id 文件，如果没有则生成并保存
    NSString *deviceIDFile = @"/var/mobile/Media/.matisu_device_id";
    NSString *deviceUUID = nil;
    
    // 使用 NSData 读取文件（更兼容的方法）
    NSError *readError = nil;
    NSData *fileData = [NSData dataWithContentsOfFile:deviceIDFile options:0 error:&readError];
    NSString *savedDeviceId = nil;
    
    if (fileData && readError == nil) {
        savedDeviceId = [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
    }
    
    if (savedDeviceId && savedDeviceId.length > 0) {
        // 文件存在，读取已有的设备ID
        deviceUUID = [savedDeviceId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        TVLog(@"HTTP Server: Read existing deviceId from %@: %@", deviceIDFile, deviceUUID);
    } else {
        // 文件不存在，读取手机设备ID并保存
        deviceUUID = [[UIDevice currentDevice] identifierForVendor].UUIDString;
        
        NSError *writeError = nil;
        if ([deviceUUID writeToFile:deviceIDFile atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
            TVLog(@"HTTP Server: Saved new deviceId to %@: %@", deviceIDFile, deviceUUID);
        } else {
            TVLog(@"HTTP Server: Failed to save deviceId to %@: %@", deviceIDFile, writeError);
        }
    }
    
    // 获取更友好的设备型号名称
    NSString *deviceModelName = [self deviceModelNameFromIdentifier:deviceModel];
    
    // 获取电量信息
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
    float batteryLevel = [[UIDevice currentDevice] batteryLevel];
    UIDeviceBatteryState batteryState = [[UIDevice currentDevice] batteryState];
    [[UIDevice currentDevice] setBatteryMonitoringEnabled:NO];
    
    // 转换电量状态为字符串
    NSString *batteryStateString = @"unknown";
    switch (batteryState) {
        case UIDeviceBatteryStateUnplugged:
            batteryStateString = @"unplugged";  // 未充电
            break;
        case UIDeviceBatteryStateCharging:
            batteryStateString = @"charging";   // 正在充电
            break;
        case UIDeviceBatteryStateFull:
            batteryStateString = @"full";       // 已充满
            break;
        default:
            batteryStateString = @"unknown";
            break;
    }
    
    // 电量为 -1 表示无法获取
    NSNumber *batteryLevelNumber = (batteryLevel >= 0) ? @(batteryLevel * 100) : @(-1);
    
    // 获取存储空间信息
    NSError *storageError = nil;
    NSDictionary *storageAttrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:&storageError];
    
    NSMutableDictionary *storage = [NSMutableDictionary dictionary];
    if (storageAttrs) {
        unsigned long long totalSpace = [storageAttrs[NSFileSystemSize] unsignedLongLongValue];
        unsigned long long freeSpace = [storageAttrs[NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long usedSpace = totalSpace - freeSpace;
        
        storage[@"totalBytes"] = @(totalSpace);
        storage[@"freeBytes"] = @(freeSpace);
        storage[@"usedBytes"] = @(usedSpace);
        storage[@"totalGB"] = [NSString stringWithFormat:@"%.1f", totalSpace / (1024.0 * 1024.0 * 1024.0)];
        storage[@"freeGB"] = [NSString stringWithFormat:@"%.1f", freeSpace / (1024.0 * 1024.0 * 1024.0)];
        storage[@"usedGB"] = [NSString stringWithFormat:@"%.1f", usedSpace / (1024.0 * 1024.0 * 1024.0)];
        storage[@"usagePercent"] = @(totalSpace > 0 ? (usedSpace * 100.0 / totalSpace) : 0);
    } else {
        storage[@"error"] = storageError.localizedDescription ?: @"Unable to get storage info";
    }
    
    // 构建设备信息字典
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"deviceName"] = deviceName ?: @"Unknown";
    result[@"deviceId"] = deviceUUID ?: @"Unknown";
    result[@"deviceModel"] = deviceModel ?: @"Unknown";
    result[@"deviceModelName"] = deviceModelName ?: @"Unknown";
    result[@"systemVersion"] = systemVersion ?: @"Unknown";
    result[@"systemName"] = [[UIDevice currentDevice] systemName] ?: @"iOS";
    result[@"batteryLevel"] = batteryLevelNumber;
    result[@"batteryState"] = batteryStateString;
    result[@"storage"] = storage;
    
    // 处理 save 参数
    NSString *saveParam = query[@"save"];
    BOOL shouldSave = [saveParam isEqualToString:@"true"] || [saveParam isEqualToString:@"1"];
    
    if (shouldSave) {
        // 获取 IP 参数（API 传入的 ip 作为 serverIP）
        NSString *serverIP = query[@"ip"];
        
        // 获取当前时间
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
        [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss Z"];
        NSString *recordTime = [formatter stringFromDate:[NSDate date]];
        
        // 添加 serverIP 和 recordTime
        result[@"serverIP"] = serverIP ?: @"Unknown";
        result[@"recordTime"] = recordTime;
        
        // 保存到 /var/mobile/Media/fuwuduan.txt
        NSString *savePath = @"/var/mobile/Media/fuwuduan.txt";
        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&error];
        
        if (jsonData) {
            BOOL success = [jsonData writeToFile:savePath options:NSDataWritingAtomic error:&error];
            if (success) {
                TVLog(@"HTTP Server: Device info saved to %@", savePath);
                result[@"_saved"] = @YES;
                result[@"_savePath"] = savePath;
            } else {
                TVLog(@"HTTP Server: Failed to save device info: %@", error);
                result[@"_saved"] = @NO;
                result[@"_saveError"] = error.localizedDescription ?: @"Unknown error";
            }
        }
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    
    return response;
}

@end
