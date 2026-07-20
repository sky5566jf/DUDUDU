//
//  TVNCHttpServer+Screenshot.mm
//  Auto-split from TVNCHttpServer.mm (P3 maintainability refactor, 2026-07-20)
//
#import "TVNCHttpServer+Handlers.h"

@interface TVNCHttpServer (Screenshot)
@end

@implementation TVNCHttpServer (Screenshot)

- (TVNCHttpResponse *)handleScreenshot:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *format = query[@"format"] ?: @"png";
    NSData *imageData = nil;
    
    // 解析旋转参数，默认0度
    NSInteger rotation = 0;
    NSString *rotationStr = query[@"rotation"];
    if (rotationStr) {
        rotation = [rotationStr integerValue];
        // 规范化到 0, 90, 180, 270
        rotation = ((rotation % 360) + 360) % 360;
        rotation = (rotation / 90) * 90;
    }
    
    // 解析质量参数，默认0.9
    CGFloat quality = 0.9;
    NSString *qualityStr = query[@"quality"];
    if (qualityStr) {
        quality = [qualityStr floatValue];
        if (quality < 0.0) quality = 0.0;
        if (quality > 1.0) quality = 1.0;
    }
    
    // 解析缩放参数，默认1.0（不缩放）
    CGFloat scale = 1.0;
    NSString *scaleStr = query[@"scale"];
    if (scaleStr) {
        scale = [scaleStr floatValue];
        if (scale < 0.1) scale = 0.1;
        if (scale > 1.0) scale = 1.0;
    }
    
    // 如果有缩放参数，使用带缩放+旋转的方法
    if (scale < 1.0 || rotation != 0) {
        imageData = [[TVNCApiManager sharedManager] captureScreenshotWithFormat:format quality:quality rotation:rotation scale:scale];
    } else {
        // 无旋转无缩放时使用原始方法
        if ([format isEqualToString:@"jpeg"] || [format isEqualToString:@"jpg"]) {
            imageData = [[TVNCApiManager sharedManager] captureScreenshotAsJPEGWithQuality:quality];
        } else {
            imageData = [[TVNCApiManager sharedManager] captureScreenshotAsPNG];
        }
    }

    // 群控兜底：UIKit 截图失败（App 后台/锁屏/无前台窗口）时，回退到 VNC 帧缓冲。
    // 帧缓冲由 daemon 的 VNC 服务持续维护，与 App 前台态解耦，后台也能拿到上一帧，
    // 避免群控卡片因 500 空响应而长期黑/空。成功路径不变，仅失败时走兜底，零回归。
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

    if (imageData) {
        response.statusCode = 200;
        response.contentType = [format isEqualToString:@"png"] ? @"image/png" : @"image/jpeg";
        response.body = imageData;
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Screenshot failed"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
    }
    
    return response;
}

- (TVNCHttpResponse *)handleScreenshotFast:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    // 检查 VNC 帧缓存是否可用
    if ([[TVNCApiManager sharedManager] isFramebufferAvailable]) {
        // 解析参数
        NSString *format = query[@"fmt"] ?: query[@"format"] ?: @"jpeg";
        CGFloat quality = 0.6;
        NSString *qStr = query[@"q"] ?: query[@"quality"];
        if (qStr) {
            quality = [qStr floatValue];
            if (quality < 0.0) quality = 0.0;
            if (quality > 1.0) quality = 1.0;
        }
        CGFloat scale = 1.0;
        NSString *scaleStr = query[@"scale"];
        if (scaleStr) {
            scale = [scaleStr floatValue];
            if (scale < 0.1) scale = 0.1;
            if (scale > 1.0) scale = 1.0;
        }
        int maxW = 0, maxH = 0;
        if (query[@"maxw"]) maxW = [query[@"maxw"] intValue];
        if (query[@"maxh"]) maxH = [query[@"maxh"] intValue];

        NSData *imageData = [[TVNCApiManager sharedManager]
            captureScreenshotFromFramebufferWithFormat:format
                                               quality:quality
                                                 scale:scale
                                                  maxW:maxW
                                                  maxH:maxH];

        if (imageData) {
            response.statusCode = 200;
            response.contentType = ([format.lowercaseString containsString:@"png"]) ? @"image/png" : @"image/jpeg";
            response.body = imageData;
            // 添加 X-Source 头标识来源
            return response;
        }
    }

    // 降级到普通截图
    NSString *format = query[@"fmt"] ?: query[@"format"] ?: @"jpeg";
    CGFloat quality = 0.6;
    NSString *qStr = query[@"q"] ?: query[@"quality"];
    if (qStr) {
        quality = [qStr floatValue];
        if (quality < 0.0) quality = 0.0;
        if (quality > 1.0) quality = 1.0;
    }
    CGFloat scale = 1.0;
    NSString *scaleStr = query[@"scale"];
    if (scaleStr) {
        scale = [scaleStr floatValue];
        if (scale < 0.1) scale = 0.1;
        if (scale > 1.0) scale = 1.0;
    }

    NSData *imageData = nil;
    if (scale < 1.0) {
        imageData = [[TVNCApiManager sharedManager] captureScreenshotWithFormat:format quality:quality rotation:0 scale:scale];
    } else {
        if ([format.lowercaseString containsString:@"png"]) {
            imageData = [[TVNCApiManager sharedManager] captureScreenshotAsPNG];
        } else {
            imageData = [[TVNCApiManager sharedManager] captureScreenshotAsJPEGWithQuality:quality];
        }
    }

    if (imageData) {
        response.statusCode = 200;
        response.contentType = [format.lowercaseString containsString:@"png"] ? @"image/png" : @"image/jpeg";
        response.body = imageData;
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        response.body = [NSJSONSerialization dataWithJSONObject:@{@"error": @"Screenshot failed"} options:0 error:nil];
    }

    return response;
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
