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

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>  // 用于 popen(), fgets(), pclose()

#import "TVNCHttpServer.h"
#import "TVNCApiManager.h"
#import "Logging.h"
#ifdef HAS_ROOT_SUPPORT
#import "TSUtil.h"
#endif

// 简单的 HTTP 响应结构
@interface TVNCHttpResponse : NSObject
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, copy) NSData *body;
@end

@implementation TVNCHttpResponse
@end

// HTTP 连接处理
@interface TVNCHttpConnection : NSObject
@property (nonatomic, assign) int clientSocket;
@property (nonatomic, strong) TVNCHttpServer *server;
- (void)handle;
@end

@interface TVNCHttpServer () {
    int _serverSocket;
    BOOL _running;
    dispatch_queue_t _serverQueue;
}
@end

@implementation TVNCHttpServer

// 辅助函数：使用 popen 执行命令并获取输出
- (NSString *)executeCommand:(NSString *)command {
    FILE *fp = popen([command UTF8String], "r");
    if (fp == NULL) {
        return nil;
    }
    
    char buffer[256];
    NSMutableString *output = [NSMutableString string];
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        [output appendString:[NSString stringWithUTF8String:buffer]];
    }
    pclose(fp);
    
    return [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 辅助函数：使用 popen 执行命令（无输出）
- (BOOL)runCommand:(NSString *)command {
    FILE *fp = popen([command UTF8String], "r");
    if (fp == NULL) {
        return NO;
    }
    pclose(fp);
    return YES;
}

+ (instancetype)sharedServer {
    static TVNCHttpServer *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    if (self = [super init]) {
        _port = 8182;
        _serverSocket = -1;
        _running = NO;
        _serverQueue = dispatch_queue_create("com.trollvnc.httpserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRunning {
    return _running;
}

- (BOOL)start {
    if (_running) {
        return YES;
    }
    
    // 创建 socket
    _serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        TVLog(@"HTTP Server: Failed to create socket");
        return NO;
    }
    
    // 允许地址重用
    int opt = 1;
    setsockopt(_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    
    // 绑定地址
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons((uint16_t)_port);
    
    if (bind(_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        TVLog(@"HTTP Server: Failed to bind to port %lu", (unsigned long)_port);
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }
    
    // 开始监听
    if (listen(_serverSocket, 10) < 0) {
        TVLog(@"HTTP Server: Failed to listen");
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }
    
    _running = YES;
    TVLog(@"HTTP Server: Started on port %lu", (unsigned long)_port);
    
    // 在后台队列接受连接
    dispatch_async(_serverQueue, ^{
        [self acceptConnections];
    });
    
    return YES;
}

- (void)stop {
    if (!_running) {
        return;
    }
    
    _running = NO;
    
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    
    TVLog(@"HTTP Server: Stopped");
}

- (void)acceptConnections {
    while (_running) {
        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        
        int clientSocket = accept(_serverSocket, (struct sockaddr *)&clientAddr, &addrLen);
        if (clientSocket < 0) {
            if (_running) {
                TVLog(@"HTTP Server: Accept failed");
            }
            continue;
        }
        
        // 在全局队列处理连接
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            TVNCHttpConnection *conn = [[TVNCHttpConnection alloc] init];
            conn.clientSocket = clientSocket;
            conn.server = self;
            [conn handle];
        });
    }
}

// 处理 HTTP 请求并返回响应
- (TVNCHttpResponse *)handleRequest:(NSString *)method 
                                 path:(NSString *)path 
                                query:(NSDictionary *)query 
                                 body:(nullable NSData *)body 
                           clientAddr:(nullable NSString *)clientAddr {
    
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 处理 OPTIONS 请求（CORS 预检）
    if ([method isEqualToString:@"OPTIONS"]) {
        response.statusCode = 200;
        response.contentType = @"text/plain";
        response.body = [@"OK" dataUsingEncoding:NSUTF8StringEncoding];
        return response;
    }
    
    // API 路由处理
    if ([path isEqualToString:@"/api/screenshot"]) {
        return [self handleScreenshot:query];
    } else if ([path isEqualToString:@"/api/writefile_text"]) {
        return [self handleWriteFileText:query body:body];
    } else if ([path isEqualToString:@"/api/clipboard"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleClipboardGet:query];
        } else {
            return [self handleClipboard:query body:body];
        }
    } else if ([path isEqualToString:@"/api/clipboard_text"]) {
        if ([method isEqualToString:@"GET"]) {
            return [self handleClipboardTextGet:query];
        } else {
            return [self handleClipboardText:query body:body];
        }
    } else if ([path isEqualToString:@"/api/input"]) {
        return [self handleInput:query body:body];
    } else if ([path isEqualToString:@"/api/key"]) {
        return [self handleKey:query];
    } else if ([path isEqualToString:@"/api/clients"]) {
        return [self handleClients];
    } else if ([path isEqualToString:@"/api/status"]) {
        return [self handleStatus];
    } else if ([path isEqualToString:@"/api/device"]) {
        return [self handleDeviceInfo:query clientAddr:clientAddr];
    } else if ([path isEqualToString:@"/api/checkfile"]) {
        return [self handleCheckFile];
    } else if ([path isEqualToString:@"/api/upload"]) {
        return [self handleUploadFile:query body:body];
    } else if ([path isEqualToString:@"/api/volume"]) {
        return [self handleVolume:query body:body];
    } else if ([path isEqualToString:@"/api/brightness"]) {
        return [self handleBrightness:query body:body];
    } else if ([path isEqualToString:@"/api/install"]) {
        return [self handleInstallApp:query];
    } else if ([path isEqualToString:@"/api/uninstall"]) {
        return [self handleUninstallApp:query];
    } else if ([path isEqualToString:@"/api/trollstore/diagnostics"]) {
        return [self handleTrollStoreDiagnostics];
    } else if ([path isEqualToString:@"/api/reboot"]) {
        return [self handleReboot];
    } else if ([path isEqualToString:@"/api/respring"]) {
        return [self handleRespring];
    } else if ([path isEqualToString:@"/api/screen/lock"]) {
        return [self handleScreenLock];
    } else if ([path isEqualToString:@"/api/screen/unlock"]) {
        return [self handleScreenUnlock];
    } else if ([path isEqualToString:@"/api/home"]) {
        return [self handleHome];
    } else if ([path isEqualToString:@"/api/taskmanager"]) {
        return [self handleTaskManager];
    } else if ([path isEqualToString:@"/api/clearapps/smart"]) {
        return [self handleClearAppsSmart];
    } else if ([path isEqualToString:@"/api/assistivetouch"]) {
        return [self handleAssistiveTouch:query method:method];
    } else if ([path isEqualToString:@"/api/filelist"]) {
        return [self handleFileList:query];
    } else if ([path isEqualToString:@"/api/readfile"]) {
        return [self handleReadFile:query];
    } else if ([path isEqualToString:@"/api/deletefile"]) {
        return [self handleDeleteFile:query];
    } else if ([path isEqualToString:@"/api/createfolder"]) {
        return [self handleCreateFolder:query];
    } else if ([path isEqualToString:@"/"]) {
        // 返回简单的 API 文档
        return [self handleRoot];
    }
    
    // 404 Not Found
    response.statusCode = 404;
    response.contentType = @"application/json";
    NSDictionary *error = @{@"error": @"Not Found", @"path": path};
    response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
    return response;
}

#pragma mark - API Handlers

// GET /api/screenshot?format=png&quality=0.8&rotation=90&scale=0.5
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

// POST /api/writefile_text?path=/xxx&append=true
// Body: plain text (UTF-8)
- (TVNCHttpResponse *)handleWriteFileText:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *filePath = query[@"path"];
    if (!filePath || filePath.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Missing path parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    BOOL append = [query[@"append"] isEqualToString:@"true"];
    
    TVLog(@"HTTP Server: WriteFileText request - path: %@, append: %@, size: %lu bytes", 
          filePath, append ? @"YES" : @"NO", (unsigned long)body.length);
    
    // 直接使用 body 作为文本内容
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] writeContent:body
                                                      toFilePath:filePath
                                                          append:append
                                                           error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"path": filePath, @"bytes": @(body.length)};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Unknown error";
        TVLog(@"HTTP Server: WriteFileText failed - %@", errMsg);
        NSDictionary *result = @{
            @"success": @NO, 
            @"error": errMsg,
            @"path": filePath
        };
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// POST /api/clipboard
// Body: base64 encoded text
- (TVNCHttpResponse *)handleClipboard:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 解析 body（base64）
    NSString *base64Content = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    base64Content = [base64Content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64Content options:0];
    if (!decodedData) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid base64 content"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    NSString *text = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    if (!text) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid UTF-8 text"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    BOOL success = [[TVNCApiManager sharedManager] setClipboardText:text];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @(success), @"text": text};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// POST /api/clipboard_text
// Body: plain text (UTF-8)
- (TVNCHttpResponse *)handleClipboardText:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 直接解析 body 为 UTF-8 文本
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid UTF-8 text"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    BOOL success = [[TVNCApiManager sharedManager] setClipboardText:text];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @(success), @"text": text};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/clipboard - 获取剪贴板内容
- (TVNCHttpResponse *)handleClipboardGet:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *text = [[TVNCApiManager sharedManager] getClipboardText];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES, @"text": text ?: @""};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/clipboard_text - 获取剪贴板内容（纯文本）
- (TVNCHttpResponse *)handleClipboardTextGet:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *text = [[TVNCApiManager sharedManager] getClipboardText];
    
    response.statusCode = 200;
    response.contentType = @"text/plain; charset=utf-8";
    response.body = (text ? [text dataUsingEncoding:NSUTF8StringEncoding] : [NSData data]);
    
    return response;
}

// GET /api/clients
- (TVNCHttpResponse *)handleClients {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 这里需要访问 trollvncserver 中的客户端列表
    // 暂时返回空列表，后续可以添加全局访问接口
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"clients": @[], @"count": @0};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/status
- (TVNCHttpResponse *)handleStatus {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    
    // 使用局部变量避免多线程竞争
    NSUInteger currentPort = self.port;
    
    NSDictionary *result = @{
        @"status": @"running",
        @"httpPort": @(currentPort),
        @"version": @PACKAGE_VERSION
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/device
// 返回设备信息：设备名、设备ID、系统版本、电量、充电状态
// 支持参数：ip=客户端IP，save=true（保存到 /var/mobile/Media/fuwuduan.txt）
// 设备ID优先读取 /var/mobile/Media/.matisu_device_id，不存在则生成并保存
- (TVNCHttpResponse *)handleDeviceInfo:(NSDictionary *)query clientAddr:(NSString *)clientAddr {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 获取设备名称
    NSString *deviceName = [[UIDevice currentDevice] name];
    if (!deviceName || deviceName.length == 0) {
        deviceName = [[NSProcessInfo processInfo] hostName];
    }
    if (!deviceName || deviceName.length == 0) {
        deviceName = @"iPhone";
    }
    
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

// 辅助方法：将设备标识符转换为友好名称
- (NSString *)deviceModelNameFromIdentifier:(NSString *)identifier {
    NSDictionary *modelMap = @{
        // iPhone
        @"iPhone1,1": @"iPhone",
        @"iPhone1,2": @"iPhone 3G",
        @"iPhone2,1": @"iPhone 3GS",
        @"iPhone3,1": @"iPhone 4",
        @"iPhone3,2": @"iPhone 4",
        @"iPhone3,3": @"iPhone 4",
        @"iPhone4,1": @"iPhone 4S",
        @"iPhone5,1": @"iPhone 5",
        @"iPhone5,2": @"iPhone 5",
        @"iPhone5,3": @"iPhone 5c",
        @"iPhone5,4": @"iPhone 5c",
        @"iPhone6,1": @"iPhone 5s",
        @"iPhone6,2": @"iPhone 5s",
        @"iPhone7,1": @"iPhone 6 Plus",
        @"iPhone7,2": @"iPhone 6",
        @"iPhone8,1": @"iPhone 6s",
        @"iPhone8,2": @"iPhone 6s Plus",
        @"iPhone8,4": @"iPhone SE",
        @"iPhone9,1": @"iPhone 7",
        @"iPhone9,2": @"iPhone 7 Plus",
        @"iPhone9,3": @"iPhone 7",
        @"iPhone9,4": @"iPhone 7 Plus",
        @"iPhone10,1": @"iPhone 8",
        @"iPhone10,2": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X",
        @"iPhone10,4": @"iPhone 8",
        @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,6": @"iPhone X",
        @"iPhone11,2": @"iPhone XS",
        @"iPhone11,4": @"iPhone XS Max",
        @"iPhone11,6": @"iPhone XS Max",
        @"iPhone11,8": @"iPhone XR",
        @"iPhone12,1": @"iPhone 11",
        @"iPhone12,3": @"iPhone 11 Pro",
        @"iPhone12,5": @"iPhone 11 Pro Max",
        @"iPhone12,8": @"iPhone SE (2nd gen)",
        @"iPhone13,1": @"iPhone 12 mini",
        @"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro",
        @"iPhone13,4": @"iPhone 12 Pro Max",
        @"iPhone14,4": @"iPhone 13 mini",
        @"iPhone14,5": @"iPhone 13",
        @"iPhone14,2": @"iPhone 13 Pro",
        @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,6": @"iPhone SE (3rd gen)",
        @"iPhone14,7": @"iPhone 14",
        @"iPhone14,8": @"iPhone 14 Plus",
        @"iPhone15,2": @"iPhone 14 Pro",
        @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPhone15,4": @"iPhone 15",
        @"iPhone15,5": @"iPhone 15 Plus",
        @"iPhone16,1": @"iPhone 15 Pro",
        @"iPhone16,2": @"iPhone 15 Pro Max",
        @"iPhone17,1": @"iPhone 16 Pro",
        @"iPhone17,2": @"iPhone 16 Pro Max",
        @"iPhone17,3": @"iPhone 16",
        @"iPhone17,4": @"iPhone 16 Plus",
        // iPad
        @"iPad1,1": @"iPad",
        @"iPad2,1": @"iPad 2",
        @"iPad2,2": @"iPad 2",
        @"iPad2,3": @"iPad 2",
        @"iPad2,4": @"iPad 2",
        @"iPad3,1": @"iPad (3rd gen)",
        @"iPad3,2": @"iPad (3rd gen)",
        @"iPad3,3": @"iPad (3rd gen)",
        @"iPad3,4": @"iPad (4th gen)",
        @"iPad3,5": @"iPad (4th gen)",
        @"iPad3,6": @"iPad (4th gen)",
        @"iPad6,11": @"iPad (5th gen)",
        @"iPad6,12": @"iPad (5th gen)",
        @"iPad7,5": @"iPad (6th gen)",
        @"iPad7,6": @"iPad (6th gen)",
        @"iPad7,11": @"iPad (7th gen)",
        @"iPad7,12": @"iPad (7th gen)",
        @"iPad11,6": @"iPad (8th gen)",
        @"iPad11,7": @"iPad (8th gen)",
        @"iPad12,1": @"iPad (9th gen)",
        @"iPad12,2": @"iPad (9th gen)",
        @"iPad13,18": @"iPad (10th gen)",
        @"iPad13,19": @"iPad (10th gen)",
        // iPad Air
        @"iPad4,1": @"iPad Air",
        @"iPad4,2": @"iPad Air",
        @"iPad4,3": @"iPad Air",
        @"iPad5,3": @"iPad Air 2",
        @"iPad5,4": @"iPad Air 2",
        @"iPad11,3": @"iPad Air (3rd gen)",
        @"iPad11,4": @"iPad Air (3rd gen)",
        @"iPad13,1": @"iPad Air (4th gen)",
        @"iPad13,2": @"iPad Air (4th gen)",
        @"iPad13,16": @"iPad Air (5th gen)",
        @"iPad13,17": @"iPad Air (5th gen)",
        @"iPad14,8": @"iPad Air (6th gen)",
        @"iPad14,9": @"iPad Air (6th gen)",
        // iPad mini
        @"iPad2,5": @"iPad mini",
        @"iPad2,6": @"iPad mini",
        @"iPad2,7": @"iPad mini",
        @"iPad4,4": @"iPad mini 2",
        @"iPad4,5": @"iPad mini 2",
        @"iPad4,6": @"iPad mini 2",
        @"iPad4,7": @"iPad mini 3",
        @"iPad4,8": @"iPad mini 3",
        @"iPad4,9": @"iPad mini 3",
        @"iPad5,1": @"iPad mini 4",
        @"iPad5,2": @"iPad mini 4",
        @"iPad11,1": @"iPad mini (5th gen)",
        @"iPad11,2": @"iPad mini (5th gen)",
        @"iPad14,1": @"iPad mini (6th gen)",
        @"iPad14,2": @"iPad mini (6th gen)",
        // iPad Pro
        @"iPad6,3": @"iPad Pro 9.7\"",
        @"iPad6,4": @"iPad Pro 9.7\"",
        @"iPad6,7": @"iPad Pro 12.9\" (1st gen)",
        @"iPad6,8": @"iPad Pro 12.9\" (1st gen)",
        @"iPad7,1": @"iPad Pro 12.9\" (2nd gen)",
        @"iPad7,2": @"iPad Pro 12.9\" (2nd gen)",
        @"iPad7,3": @"iPad Pro 10.5\"",
        @"iPad7,4": @"iPad Pro 10.5\"",
        @"iPad8,1": @"iPad Pro 11\" (1st gen)",
        @"iPad8,2": @"iPad Pro 11\" (1st gen)",
        @"iPad8,3": @"iPad Pro 11\" (1st gen)",
        @"iPad8,4": @"iPad Pro 11\" (1st gen)",
        @"iPad8,5": @"iPad Pro 12.9\" (3rd gen)",
        @"iPad8,6": @"iPad Pro 12.9\" (3rd gen)",
        @"iPad8,7": @"iPad Pro 12.9\" (3rd gen)",
        @"iPad8,8": @"iPad Pro 12.9\" (3rd gen)",
        @"iPad8,9": @"iPad Pro 11\" (2nd gen)",
        @"iPad8,10": @"iPad Pro 11\" (2nd gen)",
        @"iPad8,11": @"iPad Pro 12.9\" (4th gen)",
        @"iPad8,12": @"iPad Pro 12.9\" (4th gen)",
        @"iPad13,4": @"iPad Pro 11\" (3rd gen)",
        @"iPad13,5": @"iPad Pro 11\" (3rd gen)",
        @"iPad13,6": @"iPad Pro 11\" (3rd gen)",
        @"iPad13,7": @"iPad Pro 11\" (3rd gen)",
        @"iPad13,8": @"iPad Pro 12.9\" (5th gen)",
        @"iPad13,9": @"iPad Pro 12.9\" (5th gen)",
        @"iPad13,10": @"iPad Pro 12.9\" (5th gen)",
        @"iPad13,11": @"iPad Pro 12.9\" (5th gen)",
        @"iPad14,3": @"iPad Pro 11\" (4th gen)",
        @"iPad14,4": @"iPad Pro 11\" (4th gen)",
        @"iPad14,5": @"iPad Pro 12.9\" (6th gen)",
        @"iPad14,6": @"iPad Pro 12.9\" (6th gen)",
        @"iPad16,3": @"iPad Pro 11\" (M4)",
        @"iPad16,4": @"iPad Pro 11\" (M4)",
        @"iPad16,5": @"iPad Pro 13\" (M4)",
        @"iPad16,6": @"iPad Pro 13\" (M4)"
    };
    
    return modelMap[identifier] ?: identifier;
}

// GET /api/checkfile
// 检查 /var/mobile/Media/zhuangtai.txt 文件是否存在
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

// POST /api/upload?path=/var/mobile/Documents/folder/filename.ext
// 上传任意文件，如果目标文件夹不存在会自动创建
- (TVNCHttpResponse *)handleUploadFile:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *filePath = query[@"path"];
    if (!filePath || filePath.length == 0) {
        TVLog(@"HTTP Server: Upload failed - missing path parameter");
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Missing path parameter", @"message": @"Please provide target file path via ?path=/xxx/xxx"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    if (!body || body.length == 0) {
        TVLog(@"HTTP Server: Upload failed - empty body for path: %@", filePath);
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Empty body", @"message": @"Please provide file content in request body"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Upload request - path: %@, size: %lu bytes", filePath, (unsigned long)body.length);
    
    // 获取目标目录
    NSString *directory = [filePath stringByDeletingLastPathComponent];
    const char *dirPath = [directory UTF8String];
    const char *filePathC = [filePath UTF8String];
    
    // 使用 POSIX API 创建目录（更可靠，适用于 TrollStore）
    char tmp[PATH_MAX];
    snprintf(tmp, sizeof(tmp), "%s", dirPath);
    size_t len = strlen(tmp);
    
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    
    // 检查目录是否已存在
    struct stat st;
    BOOL dirExisted = (stat(dirPath, &st) == 0);
    
    if (!dirExisted) {
        // 递归创建目录（使用 0777 权限）
        for (char *p = tmp + 1; *p; p++) {
            if (*p == '/') {
                *p = 0;
                if (mkdir(tmp, 0777) == 0) {
                    chmod(tmp, 0777);
                }
                *p = '/';
            }
        }
        if (mkdir(tmp, 0777) == 0) {
            chmod(tmp, 0777);
        }
        
        // 验证目录是否创建成功
        if (stat(dirPath, &st) != 0) {
            TVLog(@"HTTP Server: Upload failed - cannot create directory: %s", strerror(errno));
            response.statusCode = 500;
            response.contentType = @"application/json";
            NSDictionary *error = @{
                @"success": @NO,
                @"error": @"Failed to create directory",
                @"details": [NSString stringWithFormat:@"%s", strerror(errno)],
                @"path": directory
            };
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
    } else if (!S_ISDIR(st.st_mode)) {
        // 路径存在但不是目录
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{
            @"success": @NO,
            @"error": @"Path exists but is not a directory",
            @"path": directory
        };
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 使用 POSIX API 写入文件（更可靠，适用于 TrollStore）
    int fd = open(filePathC, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        TVLog(@"HTTP Server: Upload failed - cannot open file: %s", strerror(errno));
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{
            @"success": @NO,
            @"error": @"Failed to open file",
            @"details": [NSString stringWithFormat:@"%s", strerror(errno)],
            @"path": filePath
        };
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 写入数据
    ssize_t written = write(fd, body.bytes, body.length);
    close(fd);
    
    if (written < 0 || (size_t)written != body.length) {
        TVLog(@"HTTP Server: Upload failed - write error: %s", strerror(errno));
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{
            @"success": @NO,
            @"error": @"Failed to write file",
            @"details": [NSString stringWithFormat:@"%s", strerror(errno)],
            @"path": filePath
        };
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 获取文件修改时间
    NSString *modificationDate = @"Unknown";
    if (stat(filePathC, &st) == 0) {
        modificationDate = [[NSDate dateWithTimeIntervalSince1970:st.st_mtime] description];
    }
    
    TVLog(@"HTTP Server: Upload success - path: %@, size: %lu bytes", filePath, (unsigned long)body.length);
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"path": filePath,
        @"bytes": @(body.length),
        @"directory": directory,
        @"created": dirExisted ? @NO : @YES,
        @"modified": modificationDate
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// POST /api/input
// Body: 要输入的文本（UTF-8）
- (TVNCHttpResponse *)handleInput:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 解析 body 为 UTF-8 文本
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid UTF-8 text"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查是否有输入框焦点
    BOOL hasFocus = [[TVNCApiManager sharedManager] inputText:text];
    
    if (hasFocus) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"text": text, @"length": @(text.length)};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"No active text input field found. Please focus an input field first."};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// POST /api/key?code=13
// 发送单个按键
- (TVNCHttpResponse *)handleKey:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *codeStr = query[@"code"];
    if (!codeStr) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Missing code parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    NSInteger keyCode = [codeStr integerValue];
    BOOL success = [[TVNCApiManager sharedManager] sendKeyCode:keyCode];
    
    response.statusCode = success ? 200 : 400;
    response.contentType = @"application/json";
    NSDictionary *result = success ? 
        @{@"success": @YES, @"keyCode": @(keyCode)} :
        @{@"success": @NO, @"error": @"Failed to send key or no active input field"};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/volume - 获取当前音量
// POST /api/volume?value=0.5 - 设置音量
- (TVNCHttpResponse *)handleVolume:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *valueStr = query[@"value"];
    if (valueStr) {
        // 设置音量
        CGFloat volume = [valueStr floatValue];
        if (volume < 0.0 || volume > 1.0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{@"success": @NO, @"error": @"Volume must be between 0.0 and 1.0"};
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        BOOL success = [[TVNCApiManager sharedManager] setVolume:volume];
        response.statusCode = success ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = success ? 
            @{@"success": @YES, @"volume": @(volume)} :
            @{@"success": @NO, @"error": @"Failed to set volume"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        // 获取当前音量
        CGFloat currentVolume = [[TVNCApiManager sharedManager] getCurrentVolume];
        response.statusCode = (currentVolume >= 0) ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = (currentVolume >= 0) ? 
            @{@"success": @YES, @"volume": @(currentVolume)} :
            @{@"success": @NO, @"error": @"Failed to get volume"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// GET /api/brightness - 获取当前亮度
// POST /api/brightness?value=0.5 - 设置亮度
- (TVNCHttpResponse *)handleBrightness:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *valueStr = query[@"value"];
    if (valueStr) {
        // 设置亮度
        CGFloat brightness = [valueStr floatValue];
        if (brightness < 0.0 || brightness > 1.0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{@"success": @NO, @"error": @"Brightness must be between 0.0 and 1.0"};
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        BOOL success = [[TVNCApiManager sharedManager] setBrightness:brightness];
        response.statusCode = success ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = success ? 
            @{@"success": @YES, @"brightness": @(brightness)} :
            @{@"success": @NO, @"error": @"Failed to set brightness"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        // 获取当前亮度
        CGFloat currentBrightness = [[TVNCApiManager sharedManager] getCurrentBrightness];
        response.statusCode = (currentBrightness >= 0) ? 200 : 500;
        response.contentType = @"application/json";
        NSDictionary *result = (currentBrightness >= 0) ? 
            @{@"success": @YES, @"brightness": @(currentBrightness)} :
            @{@"success": @NO, @"error": @"Failed to get brightness"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// POST /api/install?path=/var/mobile/Documents/app.ipa
// 通过 TrollStore 安装 IPA 文件
- (TVNCHttpResponse *)handleInstallApp:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *ipaPath = query[@"path"];
    if (!ipaPath || ipaPath.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing path parameter. Usage: /api/install?path=/path/to/app.ipa"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 TrollStore 是否可用
    if (![[TVNCApiManager sharedManager] isTrollStoreAvailable]) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"TrollStore is not available. Please ensure TrollStore is installed."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 IPA 文件是否存在
    if (access([ipaPath UTF8String], F_OK) != 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"IPA file not found", @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Install app request - path: %@", ipaPath);
    
    // 执行安装
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] installAppWithIPAPath:ipaPath error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"App installed successfully", @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App installed successfully: %@", ipaPath);
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Installation failed";
        NSDictionary *result = @{@"success": @NO, @"error": errMsg, @"path": ipaPath};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App installation failed: %@", errMsg);
    }
    
    return response;
}

// GET /api/trollstore/diagnostics
// 获取 TrollStore 诊断信息
- (TVNCHttpResponse *)handleTrollStoreDiagnostics {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSDictionary *diagnostics = [[TVNCApiManager sharedManager] getTrollStoreDiagnostics];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:diagnostics options:NSJSONWritingPrettyPrinted error:nil];
    
    return response;
}

// POST /api/reboot
// 重启设备
- (TVNCHttpResponse *)handleReboot {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    TVLog(@"HTTP Server: Reboot request received");
    
    BOOL success = [[TVNCApiManager sharedManager] rebootDevice];
    
    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";
    
    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Reboot initiated",
            @"warning": @"Device will restart immediately"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to initiate reboot"
        };
    
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/respring
// 注销设备（Respring），完成后等待 15 秒再解锁屏幕
- (TVNCHttpResponse *)handleRespring {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Respring request received");

    BOOL success = [[TVNCApiManager sharedManager] respringDevice];

    // 注销后等待 15 秒，然后解锁屏幕
    if (success) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            TVLog(@"Respring completed, unlocking screen after 15s delay");
            [[TVNCApiManager sharedManager] unlockDeviceScreen];
        });
    }

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Respring initiated",
            @"warning": @"Screen will unlock after 15 seconds"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to initiate respring"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/screen/lock
// 锁定屏幕
- (TVNCHttpResponse *)handleScreenLock {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Screen lock request received");

    BOOL success = [[TVNCApiManager sharedManager] lockDeviceScreen];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Screen locked"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to lock screen"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/screen/unlock
// 解锁屏幕（唤醒 + 滑动解锁）
- (TVNCHttpResponse *)handleScreenUnlock {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Screen unlock request received");

    BOOL success = [[TVNCApiManager sharedManager] unlockDeviceScreen];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"message": @"Screen unlocked"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to unlock screen"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/home
// 返回桌面（按一次 Home 键）
- (TVNCHttpResponse *)handleHome {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Home request received");

    BOOL success = [[TVNCApiManager sharedManager] goToHome];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"action": @"home",
            @"message": @"Returned to home screen"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to go to home"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/taskmanager
// 打开任务管理器（双击 Home 键）
- (TVNCHttpResponse *)handleTaskManager {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    TVLog(@"HTTP Server: Task manager request received");

    BOOL success = [[TVNCApiManager sharedManager] openTaskManager];

    response.statusCode = success ? 200 : 500;
    response.contentType = @"application/json";

    NSDictionary *result = success ?
        @{
            @"success": @YES,
            @"action": @"taskmanager",
            @"message": @"Task manager opened"
        } :
        @{
            @"success": @NO,
            @"error": @"Failed to open task manager"
        };

    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

// POST /api/clearapps/smart
// 智能清理后台应用（识别当前应用，桌面则跳过）
- (TVNCHttpResponse *)handleClearAppsSmart {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    TVLog(@"HTTP Server: Smart clear apps request received");
    
    NSDictionary *result = [[TVNCApiManager sharedManager] clearBackgroundAppsSmart];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// @end - AssistiveTouch Handlers

// GET /api/assistivetouch
// POST /api/assistivetouch?action=enable
// POST /api/assistivetouch?action=disable
- (TVNCHttpResponse *)handleAssistiveTouch:(NSDictionary *)query method:(NSString *)method {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSDictionary *result = nil;
    
    if ([method isEqualToString:@"GET"]) {
        // GET 请求：获取状态
        TVLog(@"HTTP Server: AssistiveTouch status request received");
        
        // 使用 popen 获取当前状态
        NSString *status = [self executeCommand:@"defaults read com.apple.Accessibility AXAssistiveTouchEnabled 2>/dev/null"];
        BOOL enabled = [status containsString:@"1"] || [status containsString:@"true"];
        
        result = @{
            @"success": @YES,
            @"action": @"status",
            @"enabled": @(enabled)
        };
        TVLog(@"HTTP Server: AssistiveTouch status: %@", enabled ? @"enabled" : @"disabled");
        
    } else {
        // POST 请求：启用或禁用
        NSString *action = query[@"action"];
        TVLog(@"HTTP Server: AssistiveTouch action request: %@", action ?: @"status");
        
        if ([action isEqualToString:@"enable"]) {
            // 设置启用
            [self runCommand:@"defaults write com.apple.Accessibility AXAssistiveTouchEnabled -bool true 2>/dev/null"];
            
            // Respring 后等待 15 秒，然后解锁屏幕
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                BOOL success = [[TVNCApiManager sharedManager] respringDevice];
                if (success) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        TVLog(@"AssistiveTouch enable: Respring completed, unlocking screen");
                        [[TVNCApiManager sharedManager] unlockDeviceScreen];
                    });
                }
            });
            
            result = @{
                @"success": @YES,
                @"action": @"enable",
                @"message": @"AssistiveTouch enabled, respringing..."
            };
            TVLog(@"HTTP Server: AssistiveTouch enabled, respringing...");
            
        } else if ([action isEqualToString:@"disable"]) {
            // 设置禁用
            [self runCommand:@"defaults write com.apple.Accessibility AXAssistiveTouchEnabled -bool false 2>/dev/null"];
            
            // Respring 后等待 15 秒，然后解锁屏幕
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                BOOL success = [[TVNCApiManager sharedManager] respringDevice];
                if (success) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                        TVLog(@"AssistiveTouch disable: Respring completed, unlocking screen");
                        [[TVNCApiManager sharedManager] unlockDeviceScreen];
                    });
                }
            });
            
            result = @{
                @"success": @YES,
                @"action": @"disable",
                @"message": @"AssistiveTouch disabled, respringing..."
            };
            TVLog(@"HTTP Server: AssistiveTouch disabled, respringing...");
            
        } else {
            result = @{
                @"success": @NO,
                @"message": @"Invalid action. Use 'enable' or 'disable'"
            };
        }
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// POST /api/uninstall?bundleId=com.example.app
// 通过 TrollStore 卸载应用
- (TVNCHttpResponse *)handleUninstallApp:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *bundleId = query[@"bundleId"];
    if (!bundleId || bundleId.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"Missing bundleId parameter. Usage: /api/uninstall?bundleId=com.example.app"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查 TrollStore 是否可用
    if (![[TVNCApiManager sharedManager] isTrollStoreAvailable]) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"success": @NO, @"error": @"TrollStore is not available. Please ensure TrollStore is installed."};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Uninstall app request - bundleId: %@", bundleId);
    
    // 执行卸载
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] uninstallAppWithBundleId:bundleId error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"App uninstalled successfully", @"bundleId": bundleId};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App uninstalled successfully: %@", bundleId);
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Uninstallation failed";
        NSDictionary *result = @{@"success": @NO, @"error": errMsg, @"bundleId": bundleId};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        TVLog(@"HTTP Server: App uninstallation failed: %@", errMsg);
    }
    
    return response;
}

// GET /api/filelist?path=/var/mobile/Media/xxx
- (TVNCHttpResponse *)handleFileList:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *path = query[@"path"];
    if (!path || path.length == 0) {
        // 默认列出懒人精灵目录
        path = @"/var/mobile/Media/com.matisu.one.nxs.rootcore";
    }
    
    TVLog(@"HTTP Server: File list request - path: %@", path);
    
    NSMutableArray *files = [NSMutableArray array];
    NSError *error = nil;
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:path error:&error];
    
    if (error) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": error.localizedDescription, @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    for (NSString *name in contents) {
        NSString *fullPath = [path stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if (attrs) {
            NSString *type = attrs[NSFileType];
            BOOL isDir = [type isEqualToString:NSFileTypeDirectory];
            [files addObject:@{
                @"name": name,
                @"path": fullPath,
                @"isDirectory": @(isDir),
                @"size": attrs[NSFileSize] ?: @(0),
                @"modDate": attrs[NSFileModificationDate] ?: [NSDate date]
            }];
        }
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES, @"path": path, @"files": files};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/readfile?path=/var/mobile/Media/xxx/file.txt
- (TVNCHttpResponse *)handleReadFile:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *path = query[@"path"];
    if (!path || path.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"Missing path parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Read file request - path: %@", path);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        response.statusCode = 404;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"File not found", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSData *data = [NSData dataWithContentsOfFile:path];
    
    if (!data) {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"Failed to read file", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    // 返回文件内容（如果是文本则尝试解码）
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        content = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"path": path,
        @"size": @(data.length),
        @"content": content ?: @"<binary data>",
        @"modDate": attrs[NSFileModificationDate] ?: [NSDate date]
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// POST /api/deletefile?path=/var/mobile/Media/xxx/file.txt
- (TVNCHttpResponse *)handleDeleteFile:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *path = query[@"path"];
    if (!path || path.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"Missing path parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Delete file request - path: %@", path);
    
    // 先检查文件是否存在
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        response.statusCode = 404;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"File not found", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
#ifdef HAS_ROOT_SUPPORT
    // 使用 spawnRoot 以 root 权限删除
    NSString *output = nil;
    int exitCode = spawnRoot(@"/bin/rm", @[@"-rf", path], &output, nil);
#else
    // 降级为 mobile 权限删除
    NSError *error = nil;
    BOOL success = [fm removeItemAtPath:path error:&error];
    int exitCode = success ? 0 : 1;
    NSString *output = error.localizedDescription;
#endif
    
    if (exitCode == 0) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"Deleted successfully", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *result = @{
            @"success": @NO,
            @"error": output ?: [NSString stringWithFormat:@"Delete failed with exit code %d", exitCode],
            @"path": path
        };
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// POST /api/createfolder?path=/var/mobile/Media/xxx/newfolder
- (TVNCHttpResponse *)handleCreateFolder:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *path = query[@"path"];
    if (!path || path.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @NO, @"error": @"Missing path parameter"};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        return response;
    }
    
    TVLog(@"HTTP Server: Create folder request - path: %@", path);
    
#ifdef HAS_ROOT_SUPPORT
    // 使用 spawnRoot 以 root 权限创建目录
    NSString *output = nil;
    int exitCode = spawnRoot(@"/bin/mkdir", @[@"-p", path], &output, nil);
#else
    // 降级为 mobile 权限创建目录
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    BOOL success = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    int exitCode = success ? 0 : 1;
    NSString *output = error.localizedDescription;
#endif
    
    if (exitCode == 0) {
        // 设置目录权限为可读写
        chmod([path UTF8String], 0777);
        
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"Folder created successfully", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSDictionary *result = @{
            @"success": @NO,
            @"error": output ?: [NSString stringWithFormat:@"Create folder failed with exit code %d", exitCode],
            @"path": path
        };
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    }
    
    return response;
}

// GET /
- (TVNCHttpResponse *)handleRoot {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *html = @"<!DOCTYPE html>"
        "<html><head><meta charset='UTF-8'><title>TrollVNC API</title></head>"
        "<body><h1>TrollVNC HTTP API</h1>"
        "<h2>Endpoints:</h2><ul>"
        "<li><b>GET /api/screenshot?format=png|jpeg&quality=0.9&rotation=0&scale=1.0</b> - 获取截图（rotation: 0=Home下, 90=Home右, 180=Home上, 270=Home左; scale: 0.1~1.0 缩放比例）</li>"
        "<li><b>POST /api/writefile_text?path=/xxx&append=true|false</b> - 写入文件（body: 纯文本）</li>"
        "<li><b>POST /api/clipboard</b> - 设置剪贴板（body: base64）</li>"
        "<li><b>POST /api/clipboard_text</b> - 设置剪贴板（body: 纯文本）</li>"
        "<li><b>POST /api/input</b> - 输入文本到当前焦点输入框（body: 纯文本）</li>"
        "<li><b>POST /api/key?code=13</b> - 发送按键（13=回车, 8=退格）</li>"
        "<li><b>GET /api/clients</b> - 获取客户端列表</li>"
        "<li><b>GET /api/status</b> - 获取服务器状态</li>"
        "<li><b>GET /api/device</b> - 获取设备信息（名称、ID、型号、版本、电量）</li>"
        "<li><b>GET /api/checkfile</b> - 检查文件是否存在</li>"
        "<li><b>POST /api/upload?path=/xxx/xxx</b> - 上传任意文件（自动创建目录）</li>"
        "<li><b>GET/POST /api/volume?value=0.5</b> - 获取/设置音量</li>"
        "<li><b>GET/POST /api/brightness?value=0.5</b> - 获取/设置亮度</li>"
        "<li><b>POST /api/install?path=/xxx/app.ipa</b> - 通过 TrollStore 安装 IPA</li>"
        "<li><b>POST /api/uninstall?bundleId=com.xxx.app</b> - 通过 TrollStore 卸载应用</li>"
        "<li><b>GET /api/trollstore/diagnostics</b> - 获取 TrollStore 诊断信息</li>"
        "<li><b>POST /api/reboot</b> - 重启设备</li>"
        "<li><b>POST /api/respring</b> - 注销设备（Respring），15秒后自动解锁屏幕</li>"
        "<li><b>POST /api/screen/lock</b> - 锁定屏幕（电源键）</li>"
        "<li><b>POST /api/screen/unlock</b> - 解锁屏幕（唤醒+Home键）</li>"
        "<li><b>POST /api/home</b> - 返回桌面（按一次 Home 键）</li>"
        "<li><b>POST /api/taskmanager</b> - 打开任务管理器（双击 Home 键）</li>"
        "<li><b>POST /api/clearapps/smart</b> - 智能清理后台应用（桌面则跳过）</li>"
        "<li><b>GET /api/assistivetouch</b> - 获取 AssistiveTouch 状态</li>"
        "<li><b>POST /api/assistivetouch?action=enable</b> - 启用 AssistiveTouch（小白点）</li>"
        "<li><b>POST /api/assistivetouch?action=disable</b> - 禁用 AssistiveTouch（小白点）</li>"
        "<li><b>GET /api/filelist?path=/var/mobile/Media/xxx</b> - 列出目录（默认：懒人精灵目录）</li>"
        "<li><b>GET /api/readfile?path=/var/mobile/Media/xxx/file.txt</b> - 读取文件内容</li>"
        "<li><b>POST /api/deletefile?path=/var/mobile/Media/xxx/file.txt</b> - 删除文件或目录</li>"
        "<li><b>POST /api/createfolder?path=/var/mobile/Media/xxx/newfolder</b> - 创建目录</li>"
        "</ul></body></html>";
    
    response.statusCode = 200;
    response.contentType = @"text/html; charset=utf-8";
    response.body = [html dataUsingEncoding:NSUTF8StringEncoding];
    
    return response;
}

@end

#pragma mark - TVNCHttpConnection

@implementation TVNCHttpConnection

- (void)handle {
    // 设置接收超时（5分钟，支持大文件上传）
    struct timeval tv;
    tv.tv_sec = 300;
    tv.tv_usec = 0;
    setsockopt(_clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    // 读取请求头
    NSMutableData *headerData = [NSMutableData data];
    uint8_t buffer[8192];
    NSInteger totalReceived = 0;
    NSInteger maxHeaderSize = 64 * 1024; // 最大 64KB 头部
    NSRange headerEndRange = NSMakeRange(NSNotFound, 0);
    
    // 先读取头部（直到 \r\n\r\n）
    while (totalReceived < maxHeaderSize) {
        ssize_t n = recv(_clientSocket, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        
        [headerData appendBytes:buffer length:n];
        totalReceived += n;
        
        // 查找头部结束标记
        headerEndRange = [headerData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                         options:0
                                           range:NSMakeRange(0, headerData.length)];
        if (headerEndRange.location != NSNotFound) {
            break;
        }
    }
    
    if (headerEndRange.location == NSNotFound) {
        TVLog(@"HTTP Server: Failed to receive complete headers");
        close(_clientSocket);
        return;
    }
    
    // 解析请求头
    NSUInteger headerLength = headerEndRange.location + headerEndRange.length;
    NSString *headerStr = [[NSString alloc] initWithBytes:headerData.bytes
                                                   length:headerLength
                                                 encoding:NSUTF8StringEncoding];
    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        TVLog(@"HTTP Server: Empty request");
        close(_clientSocket);
        return;
    }
    
    // 解析请求行
    NSArray *requestParts = [lines[0] componentsSeparatedByString:@" "];
    if (requestParts.count < 2) {
        TVLog(@"HTTP Server: Invalid request line: %@", lines[0]);
        close(_clientSocket);
        return;
    }
    
    NSString *method = requestParts[0];
    NSString *fullPath = requestParts[1];
    
    // 解析路径和查询参数
    NSString *path = fullPath;
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    NSRange queryRange = [fullPath rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        path = [fullPath substringToIndex:queryRange.location];
        NSString *queryString = [fullPath substringFromIndex:queryRange.location + 1];
        NSArray *pairs = [queryString componentsSeparatedByString:@"&"];
        for (NSString *pair in pairs) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2) {
                NSString *key = [kv[0] stringByRemovingPercentEncoding];
                NSString *value = [kv[1] stringByRemovingPercentEncoding];
                query[key] = value;
            }
        }
    }
    
    // 解析 Content-Length
    NSInteger contentLength = 0;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"Content-Length: "]) {
            NSString *lenStr = [line substringFromIndex:16];
            contentLength = [lenStr integerValue];
            break;
        }
    }
    
    TVLog(@"HTTP Server: %@ %@ (Content-Length: %ld)", method, fullPath, (long)contentLength);
    
    // 处理 body
    NSData *body = nil;
    NSInteger maxMemorySize = 10 * 1024 * 1024; // 10MB 以下直接读入内存
    
    // 检查是否已有部分 body 数据（在头部之后）
    NSInteger bodyReceived = headerData.length - headerLength;
    NSMutableData *bodyData = [NSMutableData data];
    if (bodyReceived > 0) {
        [bodyData appendBytes:((uint8_t *)headerData.bytes + headerLength) length:bodyReceived];
    }
    
    // 对于 /api/upload 且文件较大的情况，使用流式处理
    BOOL isUploadRequest = [path isEqualToString:@"/api/upload"];
    NSString *tempFilePath = nil;
    int tempFileFd = -1;
    
    if (isUploadRequest && contentLength > maxMemorySize) {
        // 大文件上传：使用临时文件
        tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"upload_%ld", (long)time(NULL)]];
        tempFileFd = open([tempFilePath UTF8String], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        
        if (tempFileFd >= 0 && bodyData.length > 0) {
            write(tempFileFd, bodyData.bytes, bodyData.length);
        }
        
        // 继续接收剩余数据到临时文件
        NSInteger remaining = contentLength - bodyReceived;
        while (remaining > 0 && tempFileFd >= 0) {
            ssize_t toRead = sizeof(buffer);
            if (toRead > remaining) toRead = remaining;
            
            ssize_t n = recv(_clientSocket, buffer, toRead, 0);
            if (n <= 0) break;
            
            write(tempFileFd, buffer, n);
            remaining -= n;
        }
        
        if (tempFileFd >= 0) {
            close(tempFileFd);
            // 读取临时文件内容
            body = [NSData dataWithContentsOfFile:tempFilePath];
            // 删除临时文件
            unlink([tempFilePath UTF8String]);
        }
    } else {
        // 小文件或其他请求：读入内存
        // 如果 Content-Length > 0，按长度读取；否则读取直到连接关闭
        if (contentLength > 0) {
            NSInteger remaining = contentLength - bodyReceived;
            while (remaining > 0) {
                ssize_t toRead = sizeof(buffer);
                if (toRead > remaining) toRead = remaining;
                
                ssize_t n = recv(_clientSocket, buffer, toRead, 0);
                if (n <= 0) break;
                
                [bodyData appendBytes:buffer length:n];
                remaining -= n;
            }
        } else if ([method isEqualToString:@"POST"] || [method isEqualToString:@"PUT"]) {
            // 没有 Content-Length 但有 body，读取直到超时或连接关闭
            // 设置短超时用于检测 body 结束
            struct timeval shortTv;
            shortTv.tv_sec = 1;
            shortTv.tv_usec = 0;
            setsockopt(_clientSocket, SOL_SOCKET, SO_RCVTIMEO, &shortTv, sizeof(shortTv));
            
            while (true) {
                ssize_t n = recv(_clientSocket, buffer, sizeof(buffer), 0);
                if (n <= 0) break;
                [bodyData appendBytes:buffer length:n];
                // 限制最大读取 10MB
                if (bodyData.length > maxMemorySize) break;
            }
            
            // 恢复长超时
            struct timeval longTv;
            longTv.tv_sec = 300;
            longTv.tv_usec = 0;
            setsockopt(_clientSocket, SOL_SOCKET, SO_RCVTIMEO, &longTv, sizeof(longTv));
        }
        
        body = bodyData;
    }
    
    // 获取客户端 IP 地址
    NSString *clientAddr = nil;
    struct sockaddr_in peerAddr;
    socklen_t peerLen = sizeof(peerAddr);
    if (getpeername(_clientSocket, (struct sockaddr *)&peerAddr, &peerLen) == 0) {
        char ipStr[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &peerAddr.sin_addr, ipStr, INET_ADDRSTRLEN);
        clientAddr = [NSString stringWithUTF8String:ipStr];
    }
    
    // 处理请求
    TVNCHttpResponse *response = [_server handleRequest:method path:path query:query body:body clientAddr:clientAddr];
    
    // 发送响应
    NSMutableString *responseHeader = [NSMutableString string];
    [responseHeader appendFormat:@"HTTP/1.1 %ld OK\r\n", (long)response.statusCode];
    [responseHeader appendFormat:@"Content-Type: %@\r\n", response.contentType];
    [responseHeader appendFormat:@"Content-Length: %lu\r\n", (unsigned long)response.body.length];
    [responseHeader appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [responseHeader appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
    [responseHeader appendString:@"Access-Control-Allow-Headers: Content-Type, Content-Length, Accept, Accept-Language, Accept-Encoding\r\n"];
    [responseHeader appendString:@"Access-Control-Max-Age: 86400\r\n"];
    [responseHeader appendString:@"Connection: close\r\n"];
    [responseHeader appendString:@"\r\n"];
    
    send(_clientSocket, responseHeader.UTF8String, responseHeader.length, 0);
    if (response.body.length > 0) {
        send(_clientSocket, response.body.bytes, response.body.length, 0);
    }
    
    close(_clientSocket);
}

@end
