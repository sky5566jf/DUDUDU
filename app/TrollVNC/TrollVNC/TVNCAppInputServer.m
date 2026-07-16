/*
 TVNCAppInputServer.m
 --------------------
 在 TrollVNC.app 中运行的本地 HTTP 服务器
 用于接收 daemon 转发的文本输入请求
 执行 AX API（因为 App 有界面进程，可以安全使用）
 */

#import "TVNCAppInputServer.h"
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

// AX 动态加载
static struct {
    void *handle;
    CFTypeRef (*createSystemWide)(void);
    int (*copyAttr)(CFTypeRef, CFStringRef, CFTypeRef *);
    int (*setAttr)(CFTypeRef, CFStringRef, CFTypeRef);
    CFTypeID (*getTypeID)(void);
    BOOL loaded;
} gAX = {0};

static BOOL loadAX(void) {
    if (gAX.loaded) return gAX.handle != NULL;
    gAX.loaded = YES;
    
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        NULL
    };
    
    for (int i = 0; paths[i]; i++) {
        gAX.handle = dlopen(paths[i], RTLD_LAZY);
        if (gAX.handle) break;
    }
    
    if (!gAX.handle) return NO;
    
    gAX.createSystemWide = dlsym(gAX.handle, "AXUIElementCreateSystemWide");
    gAX.copyAttr = dlsym(gAX.handle, "AXUIElementCopyAttributeValue");
    gAX.setAttr = dlsym(gAX.handle, "AXUIElementSetAttributeValue");
    gAX.getTypeID = dlsym(gAX.handle, "AXUIElementGetTypeID");
    
    return gAX.createSystemWide && gAX.copyAttr && gAX.setAttr && gAX.getTypeID;
}

// 通过 AX API 输入文本（在 App 进程中执行）
static BOOL inputTextViaAX(NSString *text) {
    if (!loadAX()) {
        NSLog(@"[TVNCAppInput] AX framework not available");
        return NO;
    }
    
    CFTypeRef systemWide = gAX.createSystemWide();
    if (!systemWide) {
        NSLog(@"[TVNCAppInput] createSystemWide failed");
        return NO;
    }
    
    CFTypeRef focusedRaw = NULL;
    int err = gAX.copyAttr(systemWide, CFSTR("AXFocusedUIElement"), &focusedRaw);
    
    if (err != 0 || !focusedRaw) {
        NSLog(@"[TVNCAppInput] no focused element (err=%d)", err);
        if (focusedRaw) CFRelease(focusedRaw);
        CFRelease(systemWide);
        return NO;
    }
    
    // 类型检查
    if (CFGetTypeID(focusedRaw) != gAX.getTypeID()) {
        NSLog(@"[TVNCAppInput] focused element type mismatch");
        CFRelease(focusedRaw);
        CFRelease(systemWide);
        return NO;
    }
    
    CFTypeRef focused = focusedRaw;
    
    // 方法1: 设置 AXValue
    int setErr = gAX.setAttr(focused, CFSTR("AXValue"), (__bridge CFStringRef)text);
    BOOL ok = (setErr == 0);
    
    // 方法2: 如果 AXValue 失败，尝试 AXSelectedText
    if (!ok) {
        setErr = gAX.setAttr(focused, CFSTR("AXSelectedText"), (__bridge CFStringRef)text);
        ok = (setErr == 0);
        NSLog(@"[TVNCAppInput] AXValue failed (err=%d), AXSelectedText ok=%d", setErr, ok);
    }
    
    CFRelease(focused);
    CFRelease(systemWide);
    
    NSLog(@"[TVNCAppInput] inputText result: %d, text: %@", ok, text);
    return ok;
}

// HTTP 服务器
@interface TVNCAppInputServer ()
@property (nonatomic, assign) int serverSocket;
@property (nonatomic, assign, readwrite) BOOL running;
@end

@implementation TVNCAppInputServer

+ (instancetype)sharedServer {
    static TVNCAppInputServer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (BOOL)startServer {
    if (self.running) return YES;
    
    _serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        NSLog(@"[TVNCAppInput] Failed to create socket");
        return NO;
    }
    
    int reuse = 1;
    setsockopt(_serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8184);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 只监听本地
    
    if (bind(_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[TVNCAppInput] Failed to bind to port 8184");
        close(_serverSocket);
        return NO;
    }
    
    if (listen(_serverSocket, 5) < 0) {
        NSLog(@"[TVNCAppInput] Failed to listen");
        close(_serverSocket);
        return NO;
    }
    
    _running = YES;
    
    // 在后台线程处理连接
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self acceptLoop];
    });
    
    NSLog(@"[TVNCAppInput] Server started on port 8184");
    return YES;
}

- (void)stopServer {
    _running = NO;
    close(_serverSocket);
    NSLog(@"[TVNCAppInput] Server stopped");
}

- (void)acceptLoop {
    while (_running) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientSocket = accept(_serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
        
        if (clientSocket < 0) continue;
        
        // 处理请求
        [self handleClient:clientSocket];
        
        close(clientSocket);
    }
}

- (void)handleClient:(int)clientSocket {
    char buffer[4096];
    memset(buffer, 0, sizeof(buffer));
    
    ssize_t bytesRead = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    if (bytesRead <= 0) return;
    
    NSString *request = [[NSString alloc] initWithBytes:buffer length:bytesRead encoding:NSUTF8StringEncoding];
    
    // 解析请求
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return;
    
    NSString *requestLine = lines[0];
    NSArray *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    
    NSString *method = parts[0];
    NSString *path = parts[1];
    
    // 处理 POST /input
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/input"]) {
        // 提取 body
        NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
        NSString *body = @"";
        if (bodyRange.location != NSNotFound) {
            body = [request substringFromIndex:bodyRange.location + 4];
        }
        
        // 执行文本输入
        BOOL success = inputTextViaAX(body);
        
        // 返回响应
        NSString *responseBody = [NSString stringWithFormat:@"{\"success\":%@,\"text\":\"%@\"}", 
                                  success ? @"true" : @"false", body];
        [self sendResponse:clientSocket body:responseBody];
    }
    // 处理 GET /health
    else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/health"]) {
        [self sendResponse:clientSocket body:@"{\"status\":\"ok\",\"service\":\"TVNCAppInputServer\"}"];
    }
    // 404
    else {
        [self sendResponse:clientSocket body:@"{\"error\":\"Not Found\"}" statusCode:404];
    }
}

- (void)sendResponse:(int)clientSocket body:(NSString *)body {
    [self sendResponse:clientSocket body:body statusCode:200];
}

- (void)sendResponse:(int)clientSocket body:(NSString *)body statusCode:(int)statusCode {
    NSString *statusText = statusCode == 200 ? @"OK" : @"Not Found";
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"\r\n"
        @"%@",
        statusCode, statusText,
        (unsigned long)[body length],
        body];
    
    const char *responseStr = [response UTF8String];
    send(clientSocket, responseStr, strlen(responseStr), 0);
}

@end
