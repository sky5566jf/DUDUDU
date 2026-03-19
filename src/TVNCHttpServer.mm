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
#import <sys/socket.h>
#import <sys/utsname.h>
#import <unistd.h>

#import "TVNCHttpServer.h"
#import "TVNCApiManager.h"
#import "Logging.h"

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
        _port = 8080;
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
                                 body:(nullable NSData *)body {
    
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
    } else if ([path isEqualToString:@"/api/writefile"]) {
        return [self handleWriteFile:query body:body];
    } else if ([path isEqualToString:@"/api/writefile_text"]) {
        return [self handleWriteFileText:query body:body];
    } else if ([path isEqualToString:@"/api/clipboard"]) {
        return [self handleClipboard:query body:body];
    } else if ([path isEqualToString:@"/api/clipboard_text"]) {
        return [self handleClipboardText:query body:body];
    } else if ([path isEqualToString:@"/api/input"]) {
        return [self handleInput:query body:body];
    } else if ([path isEqualToString:@"/api/key"]) {
        return [self handleKey:query];
    } else if ([path isEqualToString:@"/api/clients"]) {
        return [self handleClients];
    } else if ([path isEqualToString:@"/api/status"]) {
        return [self handleStatus];
    } else if ([path isEqualToString:@"/api/device"]) {
        return [self handleDeviceInfo];
    } else if ([path isEqualToString:@"/api/checkfile"]) {
        return [self handleCheckFile];
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

// GET /api/screenshot?format=png
- (TVNCHttpResponse *)handleScreenshot:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *format = query[@"format"] ?: @"png";
    NSData *imageData = nil;
    
    if ([format isEqualToString:@"jpeg"] || [format isEqualToString:@"jpg"]) {
        imageData = [[TVNCApiManager sharedManager] captureScreenshotAsJPEGWithQuality:0.9];
    } else {
        imageData = [[TVNCApiManager sharedManager] captureScreenshotAsPNG];
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

// POST /api/writefile?path=/xxx&append=true
// Body: base64 encoded content
- (TVNCHttpResponse *)handleWriteFile:(NSDictionary *)query body:(NSData *)body {
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
    
    // 解析 body（base64）
    NSString *base64Content = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    base64Content = [base64Content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    NSData *contentData = [[NSData alloc] initWithBase64EncodedString:base64Content options:0];
    if (!contentData) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{@"error": @"Invalid base64 content"};
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    NSError *error = nil;
    BOOL success = [[TVNCApiManager sharedManager] writeContent:contentData
                                                      toFilePath:filePath
                                                          append:append
                                                           error:&error];
    
    if (success) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"path": filePath, @"bytes": @(contentData.length)};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        response.statusCode = 500;
        response.contentType = @"application/json";
        NSString *errMsg = error ? error.localizedDescription : @"Unknown error";
        NSDictionary *result = @{@"success": @NO, @"error": errMsg};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
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
        NSDictionary *result = @{@"success": @NO, @"error": errMsg};
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
    NSDictionary *result = @{
        @"status": @"running",
        @"httpPort": @(_port),
        @"version": @PACKAGE_VERSION
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

// GET /api/device
// 返回设备信息：设备名、设备ID、系统版本
- (TVNCHttpResponse *)handleDeviceInfo {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    // 获取设备名称
    NSString *deviceName = [[UIDevice currentDevice] name];
    
    // 获取系统版本
    NSString *systemVersion = [[UIDevice currentDevice] systemVersion];
    
    // 获取设备型号标识符 (如 iPhone15,2)
    NSString *deviceModel = nil;
    struct utsname systemInfo;
    uname(&systemInfo);
    deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    
    // 获取设备UUID (作为设备ID)
    NSString *deviceUUID = [[UIDevice currentDevice] identifierForVendor].UUIDString;
    
    // 获取更友好的设备型号名称
    NSString *deviceModelName = [self deviceModelNameFromIdentifier:deviceModel];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"deviceName": deviceName ?: @"Unknown",
        @"deviceId": deviceUUID ?: @"Unknown",
        @"deviceModel": deviceModel ?: @"Unknown",
        @"deviceModelName": deviceModelName ?: @"Unknown",
        @"systemVersion": systemVersion ?: @"Unknown",
        @"systemName": [[UIDevice currentDevice] systemName] ?: @"iOS"
    };
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

// GET /
- (TVNCHttpResponse *)handleRoot {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *html = @"<!DOCTYPE html>"
        "<html><head><meta charset='UTF-8'><title>TrollVNC API</title></head>"
        "<body><h1>TrollVNC HTTP API</h1>"
        "<h2>Endpoints:</h2><ul>"
        "<li><b>GET /api/screenshot?format=png|jpeg</b> - 获取截图</li>"
        "<li><b>POST /api/writefile?path=/xxx&append=true|false</b> - 写入文件（body: base64）</li>"
        "<li><b>POST /api/writefile_text?path=/xxx&append=true|false</b> - 写入文件（body: 纯文本）</li>"
        "<li><b>POST /api/clipboard</b> - 设置剪贴板（body: base64）</li>"
        "<li><b>POST /api/clipboard_text</b> - 设置剪贴板（body: 纯文本）</li>"
        "<li><b>POST /api/input</b> - 输入文本到当前焦点输入框（body: 纯文本）</li>"
        "<li><b>POST /api/key?code=13</b> - 发送按键（13=回车, 8=退格）</li>"
        "<li><b>GET /api/clients</b> - 获取客户端列表</li>"
        "<li><b>GET /api/status</b> - 获取服务器状态</li>"
        "<li><b>GET /api/device</b> - 获取设备信息（名称、ID、型号、版本）</li>"
        "<li><b>GET /api/checkfile</b> - 检查文件是否存在（/var/mobile/Media/zhuangtai.txt）</li>"
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
    // 设置接收超时
    struct timeval tv;
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    setsockopt(_clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    
    // 读取请求
    NSMutableData *requestData = [NSMutableData data];
    uint8_t buffer[4096];
    
    while (true) {
        ssize_t n = recv(_clientSocket, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        
        [requestData appendBytes:buffer length:n];
        
        // 检查是否接收完头部
        NSRange range = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                         options:0
                                           range:NSMakeRange(0, requestData.length)];
        if (range.location != NSNotFound) {
            // 检查是否有 body
            NSUInteger headerEnd = range.location + range.length;
            NSString *headerStr = [[NSString alloc] initWithBytes:requestData.bytes
                                                           length:headerEnd
                                                         encoding:NSUTF8StringEncoding];
            
            // 解析 Content-Length
            NSInteger contentLength = 0;
            NSRange clRange = [headerStr rangeOfString:@"Content-Length: "];
            if (clRange.location != NSNotFound) {
                NSUInteger start = clRange.location + clRange.length;
                NSRange endRange = [headerStr rangeOfString:@"\r\n" options:0 range:NSMakeRange(start, headerStr.length - start)];
                if (endRange.location != NSNotFound) {
                    NSString *lenStr = [headerStr substringWithRange:NSMakeRange(start, endRange.location - start)];
                    contentLength = [lenStr integerValue];
                }
            }
            
            // 如果已接收完 body，退出循环
            if (requestData.length >= headerEnd + contentLength) {
                break;
            }
        }
    }
    
    // 解析请求
    NSString *requestStr = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
    NSArray *lines = [requestStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        close(_clientSocket);
        return;
    }
    
    // 解析请求行
    NSArray *requestParts = [lines[0] componentsSeparatedByString:@" "];
    if (requestParts.count < 2) {
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
    
    // 解析 body
    NSData *body = nil;
    NSRange headerEndRange = [requestData rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0
                                                range:NSMakeRange(0, requestData.length)];
    if (headerEndRange.location != NSNotFound) {
        NSUInteger bodyStart = headerEndRange.location + headerEndRange.length;
        if (requestData.length > bodyStart) {
            body = [requestData subdataWithRange:NSMakeRange(bodyStart, requestData.length - bodyStart)];
        }
    }
    
    // 处理请求
    TVNCHttpResponse *response = [_server handleRequest:method path:path query:query body:body];
    
    // 发送响应
    NSMutableString *responseHeader = [NSMutableString string];
    [responseHeader appendFormat:@"HTTP/1.1 %ld OK\r\n", (long)response.statusCode];
    [responseHeader appendFormat:@"Content-Type: %@\r\n", response.contentType];
    [responseHeader appendFormat:@"Content-Length: %lu\r\n", (unsigned long)response.body.length];
    [responseHeader appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [responseHeader appendString:@"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"];
    [responseHeader appendString:@"Access-Control-Allow-Headers: Content-Type\r\n"];
    [responseHeader appendString:@"Connection: close\r\n"];
    [responseHeader appendString:@"\r\n"];
    
    send(_clientSocket, responseHeader.UTF8String, responseHeader.length, 0);
    if (response.body.length > 0) {
        send(_clientSocket, response.body.bytes, response.body.length, 0);
    }
    
    close(_clientSocket);
}

@end
