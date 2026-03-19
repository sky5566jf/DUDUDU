/*
 This file is part of MatisuVNC
 Copyright (c) 2025 Matisu <Matisu@gmail.com> and contributors

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

#import "MatisuAPI.h"
#import "ScreenCapturer.h"
#import "Logging.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

@interface MatisuAPI ()
@property(nonatomic, assign) int serverSocket;
@property(nonatomic, assign, getter=isRunning) BOOL running;
@property(nonatomic, assign) int port;
@property(nonatomic, strong) dispatch_queue_t serverQueue;
@property(nonatomic, assign) BOOL shouldStop;
@end

@implementation MatisuAPI

+ (instancetype)sharedAPI {
    static MatisuAPI *_inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _inst = [[self alloc] init];
    });
    return _inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _running = NO;
        _port = 0;
        _serverQueue = dispatch_queue_create("com.matisu.vnc.api", DISPATCH_QUEUE_SERIAL);
        _shouldStop = NO;
    }
    return self;
}

- (void)dealloc {
    [self stopServer];
}

#pragma mark - Server Control

- (BOOL)startServerOnPort:(int)port {
    if (self.running) {
        TVLog(@"MatisuAPI: Server already running on port %d", self.port);
        return YES;
    }

    self.port = port;
    self.shouldStop = NO;

    // Create server socket
    self.serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (self.serverSocket < 0) {
        TVLog(@"MatisuAPI: Failed to create server socket");
        return NO;
    }

    // Set socket options
    int opt = 1;
    setsockopt(self.serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind to port
    struct sockaddr_in serverAddr;
    memset(&serverAddr, 0, sizeof(serverAddr));
    serverAddr.sin_family = AF_INET;
    serverAddr.sin_addr.s_addr = INADDR_ANY;
    serverAddr.sin_port = htons(port);

    if (bind(self.serverSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) < 0) {
        TVLog(@"MatisuAPI: Failed to bind to port %d", port);
        close(self.serverSocket);
        self.serverSocket = -1;
        return NO;
    }

    // Listen for connections
    if (listen(self.serverSocket, 5) < 0) {
        TVLog(@"MatisuAPI: Failed to listen on port %d", port);
        close(self.serverSocket);
        self.serverSocket = -1;
        return NO;
    }

    self.running = YES;
    TVLog(@"MatisuAPI: Server started on port %d", port);

    // Start accepting connections
    dispatch_async(self.serverQueue, ^{
        [self acceptConnections];
    });

    return YES;
}

- (void)stopServer {
    if (!self.running) {
        return;
    }

    self.shouldStop = YES;
    self.running = NO;

    if (self.serverSocket >= 0) {
        close(self.serverSocket);
        self.serverSocket = -1;
    }

    TVLog(@"MatisuAPI: Server stopped");
}

- (void)acceptConnections {
    while (!self.shouldStop) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);

        int clientSocket = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientSocket < 0) {
            if (self.shouldStop) {
                break;
            }
            continue;
        }

        // Handle request in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self handleClient:clientSocket];
        });
    }
}

- (void)handleClient:(int)clientSocket {
    char buffer[4096];
    ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);

    if (bytesRead <= 0) {
        close(clientSocket);
        return;
    }

    buffer[bytesRead] = '\0';
    NSString *request = [NSString stringWithUTF8String:buffer];

    // Parse request line
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    NSString *firstLine = lines.firstObject;
    NSArray *parts = [firstLine componentsSeparatedByString:@" "];

    if (parts.count < 2) {
        [self sendErrorResponse:clientSocket statusCode:400 message:@"Bad Request"];
        close(clientSocket);
        return;
    }

    NSString *method = parts[0];
    NSString *path = parts[1];

    TVLog(@"MatisuAPI: Received %@ %@", method, path);

    // Parse query string
    NSString *queryString = @"";
    NSArray *pathParts = [path componentsSeparatedByString:@"?"];
    if (pathParts.count > 1) {
        queryString = pathParts[1];
    }
    NSString *cleanPath = pathParts[0];

    // Handle API endpoints
    NSData *responseData = nil;
    NSString *contentType = @"application/json";
    int statusCode = 200;

    if ([cleanPath isEqualToString:@"/api/screenshot"]) {
        // GET /api/screenshot - Get current screen as PNG
        responseData = [self captureScreenAsPNG];
        if (responseData) {
            contentType = @"image/png";
        } else {
            statusCode = 500;
            responseData = [@"{\"error\":\"Failed to capture screen\"}" dataUsingEncoding:NSUTF8StringEncoding];
        }
    } else if ([cleanPath isEqualToString:@"/api/screenshot.jpg"] || [cleanPath isEqualToString:@"/api/screenshot.jpeg"]) {
        // GET /api/screenshot.jpg - Get current screen as JPEG
        float quality = 0.8;
        NSArray *queryParams = [queryString componentsSeparatedByString:@"&"];
        for (NSString *param in queryParams) {
            if ([param hasPrefix:@"quality="]) {
                quality = [[param substringFromIndex:8] floatValue];
            }
        }
        responseData = [self captureScreenAsJPEGWithQuality:quality];
        if (responseData) {
            contentType = @"image/jpeg";
        } else {
            statusCode = 500;
            responseData = [@"{\"error\":\"Failed to capture screen\"}" dataUsingEncoding:NSUTF8StringEncoding];
        }
    } else if ([cleanPath isEqualToString:@"/api/file/write"]) {
        // POST /api/file/write - Write file to specified path
        NSDictionary *result = [self handleFileWrite:request];
        if ([result[@"success"] boolValue]) {
            responseData = [[NSString stringWithFormat:@"{\"success\":true,\"path\":\"%@\"}",
                          result[@"path"]] dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            statusCode = 400;
            responseData = [[NSString stringWithFormat:@"{\"success\":false,\"error\":\"%@\"}",
                          result[@"error"]] dataUsingEncoding:NSUTF8StringEncoding];
        }
    } else if ([cleanPath isEqualToString:@"/api/file/read"]) {
        // GET /api/file/read?path=xxx - Read file from specified path
        NSString *filePath = [self getQueryParam:queryString name:@"path"];
        if (filePath.length == 0) {
            statusCode = 400;
            responseData = [@"{\"success\":false,\"error\":\"Missing path parameter\"}" dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            NSError *error = nil;
            NSString *content = [self readStringFromPath:filePath error:&error];
            if (content) {
                responseData = [[NSString stringWithFormat:@"{\"success\":true,\"content\":\"%@\"}",
                              [self escapeJSONString:content]] dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                statusCode = 400;
                responseData = [[NSString stringWithFormat:@"{\"success\":false,\"error\":\"%@\"}",
                              error.localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
            }
        }
    } else if ([cleanPath isEqualToString:@"/api/status"]) {
        // GET /api/status - Server status
        responseData = [@"{\"status\":\"running\",\"service\":\"MatisuVNC\"}" dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        // Unknown endpoint
        statusCode = 404;
        responseData = [@"{\"error\":\"Not Found\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // Send response
    [self sendResponse:clientSocket statusCode:statusCode contentType:contentType data:responseData];
    close(clientSocket);
}

- (NSDictionary *)handleFileWrite:(NSString *)request {
    // Extract JSON body from request
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        return @{@"success": @NO, @"error": @"Missing request body"};
    }

    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&error];
    if (error || !json) {
        return @{@"success": @NO, @"error": @"Invalid JSON"};
    }

    NSString *path = json[@"path"];
    NSString *content = json[@"content"];

    if (!path || path.length == 0) {
        return @{@"success": @NO, @"error": @"Missing path parameter"};
    }

    if (content) {
        // Write string content
        NSError *writeError = nil;
        BOOL success = [self writeString:content toPath:path error:&writeError];
        if (success) {
            return @{@"success": @YES, @"path": path};
        } else {
            return @{@"success": @NO, @"error": writeError.localizedDescription ?: @"Unknown error"};
        }
    }

    // Check for binary data (base64 encoded)
    NSString *base64Data = json[@"data"];
    if (base64Data) {
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:base64Data options:0];
        if (decodedData) {
            NSError *writeError = nil;
            BOOL success = [self writeData:decodedData toPath:path error:&writeError];
            if (success) {
                return @{@"success": @YES, @"path": path};
            } else {
                return @{@"success": @NO, @"error": writeError.localizedDescription ?: @"Unknown error"};
            }
        }
    }

    return @{@"success": @NO, @"error": @"Missing content or data parameter"};
}

- (NSString *)getQueryParam:(NSString *)queryString name:(NSString *)name {
    if (queryString.length == 0) {
        return @"";
    }

    NSArray *params = [queryString componentsSeparatedByString:@"&"];
    for (NSString *param in params) {
        NSArray *kv = [param componentsSeparatedByString:@"="];
        if (kv.count == 2 && [kv[0] isEqualToString:name]) {
            return [self urlDecode:kv[1]];
        }
    }
    return @"";
}

- (NSString *)urlDecode:(NSString *)str {
    NSString *result = [str stringByReplacingOccurrencesOfString:@"%20" withString:@" "];
    result = [result stringByReplacingOccurrencesOfString:@"%3A" withString:@":"];
    result = [result stringByReplacingOccurrencesOfString:@"%2F" withString:@"/"];
    return result;
}

- (NSString *)escapeJSONString:(NSString *)str {
    return [str stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            .stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]
            .stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"]
            .stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
            .stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
}

- (void)sendResponse:(int)clientSocket statusCode:(int)statusCode contentType:(NSString *)contentType data:(NSData *)data {
    NSString *statusText = @"OK";
    switch (statusCode) {
        case 200: statusText = @"OK"; break;
        case 400: statusText = @"Bad Request"; break;
        case 404: statusText = @"Not Found"; break;
        case 500: statusText = @"Internal Server Error"; break;
        default: statusText = @"Unknown"; break;
    }

    NSMutableString *header = [NSMutableString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        statusCode, statusText, contentType, (unsigned long)data.length];

    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    send(clientSocket, headerData.bytes, headerData.length, 0);

    if (data.length > 0) {
        send(clientSocket, data.bytes, data.length, 0);
    }
}

- (void)sendErrorResponse:(int)clientSocket statusCode:(int)statusCode message:(NSString *)message {
    NSData *data = [[NSString stringWithFormat:@"{\"error\":\"%@\"}", message] dataUsingEncoding:NSUTF8StringEncoding];
    [self sendResponse:clientSocket statusCode:statusCode contentType:@"application/json" data:data];
}

#pragma mark - Screenshot

- (nullable NSData *)captureScreenAsPNG {
    __block NSData *pngData = nil;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    // Start capture
    ScreenCapturer *capturer = [ScreenCapturer sharedCapturer];
    [capturer startCaptureWithFrameHandler:^(CMSampleBufferRef sampleBuffer) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t width = CVPixelBufferGetWidth(pixelBuffer);
        size_t height = CVPixelBufferGetHeight(pixelBuffer);
        size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow,
                                                      colorSpace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);

        if (context) {
            CGImageRef cgImage = CGBitmapContextCreateImage(context);
            if (cgImage) {
                UIImage *image = [UIImage imageWithCGImage:cgImage];
                pngData = UIImagePNGRepresentation(image);
                CGImageRelease(cgImage);
            }
            CGContextRelease(context);
        }
        CGColorSpaceRelease(colorSpace);

        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

        dispatch_semaphore_signal(sem);
    }];

    // Wait for capture with timeout
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
    dispatch_semaphore_wait(sem, timeout);

    // Stop capture
    [capturer endCapture];

    return pngData;
}

- (nullable NSData *)captureScreenAsJPEGWithQuality:(float)quality {
    NSData *pngData = [self captureScreenAsPNG];
    if (!pngData) {
        return nil;
    }

    UIImage *image = [UIImage imageWithData:pngData];
    if (!image) {
        return nil;
    }

    return UIImageJPEGRepresentation(image, quality);
}

#pragma mark - File Operations

- (BOOL)writeData:(NSData *)data toPath:(NSString *)path error:(NSError **)error {
    // Security check: prevent writing outside allowed directories
    if (![self isPathAllowed:path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MatisuAPI" code:403
                                      userInfo:@{NSLocalizedDescriptionKey: @"Path not allowed"}];
        }
        return NO;
    }

    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (BOOL)writeString:(NSString *)content toPath:(NSString *)path error:(NSError **)error {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    return [self writeData:data toPath:path error:error];
}

- (nullable NSString *)readStringFromPath:(NSString *)path error:(NSError **)error {
    // Security check: prevent reading outside allowed directories
    if (![self isPathAllowed:path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MatisuAPI" code:403
                                      userInfo:@{NSLocalizedDescriptionKey: @"Path not allowed"}];
        }
        return nil;
    }

    return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
}

- (BOOL)isPathAllowed:(NSString *)path {
    // Only allow paths in /var/mobile or /tmp
    NSArray *allowedPrefixes = @[@"/var/mobile", @"/tmp", @"/private/var/mobile"];
    for (NSString *prefix in allowedPrefixes) {
        if ([path hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

@end
