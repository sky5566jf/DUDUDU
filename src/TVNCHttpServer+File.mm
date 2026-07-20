//
//  TVNCHttpServer+File.mm
//  Auto-split from TVNCHttpServer.mm (P3 maintainability refactor, 2026-07-20)
//
#import "TVNCHttpServer+Handlers.h"

@interface TVNCHttpServer (File)
@end

@implementation TVNCHttpServer (File)

- (TVNCHttpResponse *)handleWebDAV:(NSString *)method path:(NSString *)path query:(NSDictionary *)query body:(NSData *)body headers:(NSDictionary *)headers {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    NSString *filePath = [self webdavFilePathForPath:path];
    
    TVLog(@"WebDAV: %@ %@", method, filePath);
    
    if ([method isEqualToString:@"PROPFIND"]) {
        // 列出目录或文件信息
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:filePath isDirectory:&isDir];
        
        if (!exists) {
            // 如果路径不存在，尝试父目录
            NSString *parentDir = [filePath stringByDeletingLastPathComponent];
            BOOL parentIsDir = NO;
            if ([fm fileExistsAtPath:parentDir isDirectory:&parentIsDir] && parentIsDir) {
                // 返回父目录列表
                NSString *xml = [self generatePropfindXMLForPath:parentDir isDirectory:YES];
                response.statusCode = 207;
                response.contentType = @"application/xml; charset=utf-8";
                response.body = [xml dataUsingEncoding:NSUTF8StringEncoding];
                return response;
            }
            
            response.statusCode = 404;
            response.contentType = @"text/plain";
            response.body = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }
        
        NSString *xml = [self generatePropfindXMLForPath:filePath isDirectory:isDir];
        response.statusCode = 207;
        response.contentType = @"application/xml; charset=utf-8";
        response.body = [xml dataUsingEncoding:NSUTF8StringEncoding];
        return response;
        
    } else if ([method isEqualToString:@"GET"]) {
        // 下载文件
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:filePath isDirectory:&isDir] && !isDir) {
            NSData *fileData = [NSData dataWithContentsOfFile:filePath];
            if (fileData) {
                response.statusCode = 200;
                response.contentType = @"application/octet-stream";
                response.body = fileData;
                return response;
            }
        }
        
        response.statusCode = 404;
        response.contentType = @"text/plain";
        response.body = [@"Not Found" dataUsingEncoding:NSUTF8StringEncoding];
        return response;
        
    } else if ([method isEqualToString:@"PUT"]) {
        // 上传文件
        NSString *dirPath = [filePath stringByDeletingLastPathComponent];
        NSFileManager *fm = [NSFileManager defaultManager];
        
        // 确保目录存在
        if (![fm fileExistsAtPath:dirPath]) {
            [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        BOOL success = [body writeToFile:filePath atomically:YES];
        if (success) {
            response.statusCode = 201;
            response.contentType = @"text/plain";
            response.body = [@"Created" dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            response.statusCode = 500;
            response.contentType = @"text/plain";
            response.body = [@"Internal Server Error" dataUsingEncoding:NSUTF8StringEncoding];
        }
        return response;
        
    } else if ([method isEqualToString:@"DELETE"]) {
        // 删除文件或目录
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        BOOL success = [fm removeItemAtPath:filePath error:&error];
        
        if (success) {
            response.statusCode = 204;
            response.contentType = @"text/plain";
            response.body = [@"No Content" dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            response.statusCode = 500;
            response.contentType = @"text/plain";
            response.body = [[error localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
        }
        return response;
        
    } else if ([method isEqualToString:@"MKCOL"]) {
        // 创建目录
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        BOOL success = [fm createDirectoryAtPath:filePath withIntermediateDirectories:YES attributes:nil error:&error];
        
        if (success) {
            response.statusCode = 201;
            response.contentType = @"text/plain";
            response.body = [@"Created" dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            response.statusCode = 500;
            response.contentType = @"text/plain";
            response.body = [[error localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
        }
        return response;
        
    } else if ([method isEqualToString:@"MOVE"]) {
        // 移动/重命名文件
        NSString *destination = headers[@"Destination"];
        if (!destination || destination.length == 0) {
            response.statusCode = 400;
            response.contentType = @"text/plain";
            response.body = [@"Missing Destination header" dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }

        // 解析 Destination URL，提取路径部分
        // Destination 可能是完整 URL（http://host/webdav/xxx）或绝对路径（/webdav/xxx）
        NSString *destPath = nil;
        if ([destination hasPrefix:@"/"]) {
            // 绝对路径
            destPath = destination;
        } else {
            // 完整 URL，提取路径部分
            NSURL *destURL = [NSURL URLWithString:destination];
            if (destURL) {
                destPath = destURL.path;
            }
        }

        if (!destPath || ![destPath hasPrefix:@"/webdav"]) {
            response.statusCode = 400;
            response.contentType = @"text/plain";
            response.body = [@"Invalid Destination header" dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }

        // 提取源和目标文件系统路径
        NSString *srcFilePath = filePath;
        NSString *dstFilePath = [self webdavFilePathForPath:destPath];
        NSString *overwrite = headers[@"Overwrite"];

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL srcExists = [fm fileExistsAtPath:srcFilePath];
        BOOL dstExists = [fm fileExistsAtPath:dstFilePath];

        if (!srcExists) {
            response.statusCode = 404;
            response.contentType = @"text/plain";
            response.body = [@"Source not found" dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }

        if (dstExists && ![overwrite isEqualToString:@"T"]) {
            response.statusCode = 412;
            response.contentType = @"text/plain";
            response.body = [@"Destination already exists" dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }

        NSError *error = nil;
        BOOL success = NO;

        // 如果目标存在，先删除
        if (dstExists) {
            success = [fm removeItemAtPath:dstFilePath error:&error];
            if (!success) {
                response.statusCode = 500;
                response.contentType = @"text/plain";
                response.body = [[error localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
                return response;
            }
        }

        // 执行移动
        success = [fm moveItemAtPath:srcFilePath toPath:dstFilePath error:&error];
        if (success) {
            response.statusCode = dstExists ? 204 : 201;
            response.contentType = @"text/plain";
            response.body = [@"Moved" dataUsingEncoding:NSUTF8StringEncoding];
        } else {
            response.statusCode = 500;
            response.contentType = @"text/plain";
            response.body = [[error localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
        }
        return response;
        
    } else if ([method isEqualToString:@"OPTIONS"]) {
        // WebDAV OPTIONS
        response.statusCode = 200;
        response.contentType = @"text/plain";
        NSString *davMethods = @"1, 2";
        response.body = [davMethods dataUsingEncoding:NSUTF8StringEncoding];
        return response;
        
    } else {
        response.statusCode = 405;
        response.contentType = @"text/plain";
        response.body = [@"Method Not Allowed" dataUsingEncoding:NSUTF8StringEncoding];
        return response;
    }
}

- (TVNCHttpResponse *)handleWebDAVStart:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    // 固定根目录为 /，忽略客户端传的 root 参数
    self.webdavRootPath = @"/";

    self.webdavEnabled = YES;
    TVNCWriteBool(CFSTR("WebDAVEnabled"), YES);

    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"message": @"WebDAV 已启用",
        @"rootPath": @"/"
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleWebDAVStop {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    self.webdavEnabled = NO;
    TVNCWriteBool(CFSTR("WebDAVEnabled"), NO);
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"message": @"WebDAV 已停用"
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleWebDAVStatus {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    BOOL enabled = TVNCReadBool(CFSTR("WebDAVEnabled"));
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"enabled": @(enabled),
        @"rootPath": self.webdavRootPath ?: @"/"
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return response;
}

- (TVNCHttpResponse *)handleWebDAVUI {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];

    // 优先从文件系统读取 webdav.html（方便修改/调试）
    NSString *fsPath = @"/var/mobile/Library/MatisuXCS/webdav.html";
    if ([[NSFileManager defaultManager] fileExistsAtPath:fsPath]) {
        NSError *readError = nil;
        NSString *htmlString = [NSString stringWithContentsOfFile:fsPath encoding:NSUTF8StringEncoding error:&readError];
        if (htmlString && !readError) {
            response.statusCode = 200;
            response.contentType = @"text/html; charset=utf-8";
            response.body = [htmlString dataUsingEncoding:NSUTF8StringEncoding];
            return response;
        }
    }

    // Fallback: 使用内嵌的 base64 HTML
    NSData *htmlData = [[NSData alloc] initWithBase64EncodedString:kWebDAVHTMLBase64 options:0];
    if (htmlData) {
        response.statusCode = 200;
        response.contentType = @"text/html; charset=utf-8";
        response.body = htmlData;
    } else {
        // base64 解码失败，返回简单提示
        NSString *msg = @"<html><body><h2>WebDAV UI Error</h2><p>Failed to decode embedded HTML.</p></body></html>";
        response.statusCode = 200;
        response.contentType = @"text/html; charset=utf-8";
        response.body = [msg dataUsingEncoding:NSUTF8StringEncoding];
    }
    return response;
}

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

- (TVNCHttpResponse *)handleClipboardGet:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *text = [[TVNCApiManager sharedManager] getClipboardText];
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES, @"text": text ?: @""};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

- (TVNCHttpResponse *)handleClipboardTextGet:(NSDictionary *)query {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *text = [[TVNCApiManager sharedManager] getClipboardText];
    
    response.statusCode = 200;
    response.contentType = @"text/plain; charset=utf-8";
    response.body = (text ? [text dataUsingEncoding:NSUTF8StringEncoding] : [NSData data]);
    
    return response;
}

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
            NSDate *modDate = attrs[NSFileModificationDate];
            // 将 NSDate 转换为时间戳（可序列化）
            NSNumber *modTimestamp = modDate ? @([modDate timeIntervalSince1970]) : @0;
            [files addObject:@{
                @"name": name,
                @"path": fullPath,
                @"isDirectory": @(isDir),
                @"size": attrs[NSFileSize] ?: @(0),
                @"modTimestamp": modTimestamp
            }];
        }
    }
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{@"success": @YES, @"path": path, @"files": files};
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

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
    
    // 将 NSDate 转换为时间戳
    NSDate *modDate = attrs[NSFileModificationDate];
    NSNumber *modTimestamp = modDate ? @([modDate timeIntervalSince1970]) : @0;
    
    response.statusCode = 200;
    response.contentType = @"application/json";
    NSDictionary *result = @{
        @"success": @YES,
        @"path": path,
        @"size": @(data.length),
        @"content": content ?: @"<binary data>",
        @"modTimestamp": modTimestamp
    };
    response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    
    return response;
}

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
    // 注意：spawnRoot 内部会捕获异常，如果 persona API 不可用会自动降级
    int exitCode = 1;
    @try {
        exitCode = spawnRoot(@"/usr/bin/rm", @[@"-rf", path]);
    } @catch (NSException *exception) {
        TVLog(@"spawnRoot delete exception: %@", exception.reason);
    }
    if (exitCode != 0) {
        // spawnRoot 失败，降级为 mobile 权限
        NSError *error = nil;
        [fm removeItemAtPath:path error:&error];
    }
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
        // 检查文件是否还存在
        BOOL stillExists = [fm fileExistsAtPath:path];
        if (!stillExists) {
            // 文件已不存在（可能通过其他方式删除了）
            response.statusCode = 200;
            response.contentType = @"application/json";
            NSDictionary *result = @{@"success": @YES, @"message": @"Deleted (or already gone)", @"path": path};
            response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        } else {
            response.statusCode = 500;
            response.contentType = @"application/json";
            NSDictionary *result = @{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"Delete failed with exit code %d", exitCode],
                @"path": path
            };
            response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        }
    }
    
    return response;
}

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
    // 注意：spawnRoot 内部会捕获异常，如果 persona API 不可用会自动降级
    int exitCode = 1;
    @try {
        exitCode = spawnRoot(@"/bin/mkdir", @[@"-p", path]);
    } @catch (NSException *exception) {
        TVLog(@"spawnRoot mkdir exception: %@", exception.reason);
    }
    if (exitCode != 0) {
        // spawnRoot 失败，降级为 mobile 权限
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    }
#else
    // 降级为 mobile 权限创建目录
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
    int exitCode = (error == nil) ? 0 : 1;
#endif
    
    if (exitCode == 0) {
        response.statusCode = 200;
        response.contentType = @"application/json";
        NSDictionary *result = @{@"success": @YES, @"message": @"Folder created successfully", @"path": path};
        response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    } else {
        // 检查目录是否已存在
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL exists = [fm fileExistsAtPath:path];
        BOOL isDir = NO;
        [fm fileExistsAtPath:path isDirectory:&isDir];
        if (exists && isDir) {
            // 目录已存在，视为成功
            response.statusCode = 200;
            response.contentType = @"application/json";
            NSDictionary *result = @{@"success": @YES, @"message": @"Folder already exists", @"path": path};
            response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        } else {
            response.statusCode = 500;
            response.contentType = @"application/json";
            NSDictionary *result = @{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"Create folder failed with exit code %d", exitCode],
                @"path": path
            };
            response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        }
    }
    
    return response;
}

- (TVNCHttpResponse *)handlePlist:(NSString *)method query:(NSDictionary *)query body:(NSData *)body {
    TVNCHttpResponse *response = [[TVNCHttpResponse alloc] init];
    
    NSString *plistPath = query[@"path"];
    if (!plistPath || plistPath.length == 0) {
        response.statusCode = 400;
        response.contentType = @"application/json";
        NSDictionary *error = @{
            @"success": @NO,
            @"error": @"Missing path parameter. Usage: GET/POST /api/plist?path=/var/mobile/Library/Preferences/xxx.plist"
        };
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
        return response;
    }
    
    // 检查路径是否为有效 plist 文件
    if (![plistPath hasSuffix:@".plist"]) {
        TVLog(@"HTTP Server: Warning - path does not end with .plist: %@", plistPath);
    }
    
    if ([method isEqualToString:@"GET"]) {
        // 读取 plist 文件
        TVLog(@"HTTP Server: Reading plist: %@", plistPath);
        
        NSData *plistData = [NSData dataWithContentsOfFile:plistPath options:0 error:nil];
        if (!plistData) {
            response.statusCode = 404;
            response.contentType = @"application/json";
            NSDictionary *error = @{
                @"success": @NO,
                @"error": @"plist file not found",
                @"path": plistPath
            };
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        // 解析 plist
        NSError *parseError = nil;
        id plistObject = [NSPropertyListSerialization propertyListWithData:plistData
                                                                   options:NSPropertyListImmutable
                                                                    format:nil
                                                                     error:&parseError];
        
        if (parseError || !plistObject) {
            response.statusCode = 500;
            response.contentType = @"application/json";
            NSDictionary *error = @{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"Failed to parse plist: %@", parseError.localizedDescription]
            };
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        // 转换为 NSDictionary 或 NSArray
        NSDictionary *resultDict = nil;
        if ([plistObject isKindOfClass:[NSDictionary class]]) {
            resultDict = (NSDictionary *)plistObject;
        } else if ([plistObject isKindOfClass:[NSArray class]]) {
            resultDict = @{@"_array": plistObject};
        } else {
            resultDict = @{@"_value": plistObject};
        }
        
        // 检查是否需要过滤（keys 或 match 参数）
        NSString *keysParam = query[@"keys"];
        NSString *matchParam = query[@"match"];
        
        if (keysParam || matchParam) {
            // 过滤模式：返回 JSON 格式
            NSMutableDictionary *filteredData = [NSMutableDictionary dictionary];
            
            if ([resultDict isKindOfClass:[NSDictionary class]]) {
                // 处理 keys 参数（逗号分隔的键名）
                if (keysParam && [keysParam isKindOfClass:[NSString class]]) {
                    NSArray *keys = [keysParam componentsSeparatedByString:@","];
                    for (NSString *key in keys) {
                        NSString *trimmedKey = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (trimmedKey.length > 0 && resultDict[trimmedKey] != nil) {
                            filteredData[trimmedKey] = resultDict[trimmedKey];
                        }
                    }
                }
                
                // 处理 match 参数（部分匹配键名）
                if (matchParam && [matchParam isKindOfClass:[NSString class]]) {
                    [resultDict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                        if ([key isKindOfClass:[NSString class]] && [key containsString:matchParam]) {
                            filteredData[key] = value;
                        }
                    }];
                }
            }
            
            response.statusCode = 200;
            response.contentType = @"application/json";
            NSDictionary *result = @{
                @"success": @YES,
                @"path": plistPath,
                @"data": filteredData
            };
            response.body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            TVLog(@"HTTP Server: plist filtered read: %@ (keys=%@, match=%@)", plistPath, keysParam ?: @"", matchParam ?: @"");
        } else {
            // 完整读取模式：返回 XML plist
            NSError *writeError = nil;
            NSData *xmlData = [NSPropertyListSerialization dataWithPropertyList:resultDict
                                                                               format:NSPropertyListXMLFormat_v1_0
                                                                                options:0
                                                                                  error:&writeError];
            if (writeError || !xmlData) {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": [NSString stringWithFormat:@"plist to XML failed: %@", writeError.localizedDescription ?: @"unknown"]
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                return response;
            }
            
            response.statusCode = 200;
            response.contentType = @"application/x-plist+xml";
            response.body = xmlData;
            TVLog(@"HTTP Server: plist read success: %@ (%ld bytes)", plistPath, (long)response.body.length);
        }
        
    } else if ([method isEqualToString:@"POST"]) {
        // 写入/修改 plist 文件
        if (!body || body.length == 0) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{
                @"success": @NO,
                @"error": @"Request body is empty. Send JSON data to write."
            };
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        // 解析 JSON
        NSError *parseError = nil;
        NSDictionary *jsonObject = [NSJSONSerialization JSONObjectWithData:body options:0 error:&parseError];
        if (parseError || !jsonObject || ![jsonObject isKindOfClass:[NSDictionary class]]) {
            response.statusCode = 400;
            response.contentType = @"application/json";
            NSDictionary *error = @{
                @"success": @NO,
                @"error": [NSString stringWithFormat:@"Invalid JSON: %@", parseError ? parseError.localizedDescription : @"must be a JSON object"]
            };
            response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
            return response;
        }
        
        // 检查是否是新格式（包含 path + set/match）
        BOOL isNewFormat = jsonObject[@"path"] != nil;
        
        NSString *targetPath = plistPath;  // 默认使用 query 中的 path
        NSMutableArray *modifiedKeys = [NSMutableArray array];
        NSMutableDictionary *resultData = [NSMutableDictionary dictionary];
        
        if (isNewFormat) {
            // 新格式：修改现有 plist
            targetPath = jsonObject[@"path"];
            if (![targetPath isKindOfClass:[NSString class]] || ((NSString *)targetPath).length == 0) {
                response.statusCode = 400;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": @"path must be a non-empty string"
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                return response;
            }
            
            TVLog(@"HTTP Server: Modifying plist (new format): %@", targetPath);
            
            // 读取现有 plist
            NSMutableDictionary *plistDict = nil;
            NSData *existingData = [NSData dataWithContentsOfFile:targetPath options:0 error:nil];
            if (existingData) {
                NSError *readError = nil;
                plistDict = [NSPropertyListSerialization propertyListWithData:existingData
                                                                      options:NSPropertyListMutableContainers
                                                                       format:nil
                                                                        error:&readError];
                if (readError || ![plistDict isKindOfClass:[NSMutableDictionary class]]) {
                    plistDict = [NSMutableDictionary dictionary];
                }
            } else {
                plistDict = [NSMutableDictionary dictionary];
            }
            
            // 应用 set 键值对
            NSDictionary *setDict = jsonObject[@"set"];
            if (setDict && [setDict isKindOfClass:[NSDictionary class]]) {
                [setDict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                    plistDict[key] = value;
                    [modifiedKeys addObject:key];
                    resultData[key] = value;
                }];
            }
            
            // 应用 match 匹配
            NSString *match = jsonObject[@"match"];
            NSString *matchValue = jsonObject[@"matchValue"];
            if (match && matchValue && [match isKindOfClass:[NSString class]] && [matchValue isKindOfClass:[NSString class]]) {
                [plistDict enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
                    if ([key isKindOfClass:[NSString class]] && [key containsString:match]) {
                        plistDict[key] = matchValue;
                        [modifiedKeys addObject:key];
                        resultData[key] = matchValue;
                    }
                }];
            }
            
            // 写入文件
            NSError *writeError = nil;
            NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plistDict
                                                                        format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:&writeError];
            
            if (writeError || !plistData) {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": [NSString stringWithFormat:@"Failed to serialize plist: %@", writeError.localizedDescription]
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                return response;
            }
            
            // 确保目录存在
            NSString *dirPath = [targetPath stringByDeletingLastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:dirPath]) {
                [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
            }
            
            BOOL success = [plistData writeToFile:targetPath atomically:YES];
            
            if (success) {
                response.statusCode = 200;
                response.contentType = @"application/json";
                NSDictionary *result = @{
                    @"success": @YES,
                    @"path": targetPath,
                    @"modified": modifiedKeys,
                    @"data": resultData
                };
                response.body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
                TVLog(@"HTTP Server: plist modified: %@ (keys: %@)", targetPath, modifiedKeys);
            } else {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": @"Failed to write plist file"
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                TVLog(@"HTTP Server: Failed to write plist: %@", targetPath);
            }
            
        } else {
            // 旧格式：直接写入（支持 _array 或 _value 包装）
            id plistObject = jsonObject;
            if (jsonObject[@"_array"]) {
                plistObject = jsonObject[@"_array"];
            } else if (jsonObject[@"_value"]) {
                plistObject = jsonObject[@"_value"];
            }
            
            TVLog(@"HTTP Server: Writing plist (legacy format): %@", plistPath);
            
            // 确保目录存在
            NSString *dirPath = [plistPath stringByDeletingLastPathComponent];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:dirPath]) {
                NSError *dirError = nil;
                [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&dirError];
                if (dirError) {
                    TVLog(@"HTTP Server: Failed to create directory: %@", dirError);
                }
            }
            
            // 序列化为 XML plist 格式
            NSError *writeError = nil;
            NSData *plistData = [NSPropertyListSerialization dataWithPropertyList:plistObject
                                                                        format:NSPropertyListXMLFormat_v1_0
                                                                     options:0
                                                                       error:&writeError];
            
            if (writeError || !plistData) {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": [NSString stringWithFormat:@"Failed to serialize plist: %@", writeError.localizedDescription]
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                return response;
            }
            
            // 写入文件
            BOOL success = [plistData writeToFile:plistPath atomically:YES];
            
            if (success) {
                response.statusCode = 200;
                response.contentType = @"application/json";
                NSDictionary *result = @{
                    @"success": @YES,
                    @"message": @"plist saved successfully",
                    @"path": plistPath
                };
                response.body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                TVLog(@"HTTP Server: plist saved: %@", plistPath);
            } else {
                response.statusCode = 500;
                response.contentType = @"application/json";
                NSDictionary *error = @{
                    @"success": @NO,
                    @"error": @"Failed to write plist file"
                };
                response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
                TVLog(@"HTTP Server: Failed to write plist: %@", plistPath);
            }
        }
        
    } else {
        response.statusCode = 405;
        response.contentType = @"application/json";
        NSDictionary *error = @{
            @"success": @NO,
            @"error": @"Method not allowed. Use GET to read or POST to write."
        };
        response.body = [NSJSONSerialization dataWithJSONObject:error options:0 error:nil];
    }
    
    return response;
}

@end
