/*
 TVNCAppInputServer.h
 --------------------
 在 TrollVNC.app 中运行的本地 HTTP 服务器
 用于接收 daemon 转发的文本输入请求
 执行 AX API（因为 App 有界面进程，可以安全使用）

 端口: 8183
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVNCAppInputServer : NSObject

+ (instancetype)sharedServer;

/// 启动本地 HTTP 服务器（端口 8183）
- (BOOL)startServer;

/// 停止服务器
- (void)stopServer;

/// 是否正在运行
@property (nonatomic, readonly, getter=isRunning) BOOL running;

@end

NS_ASSUME_NONNULL_END
