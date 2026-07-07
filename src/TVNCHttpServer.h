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

#ifndef TVNCHttpServer_h
#define TVNCHttpServer_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 TVNCHttpServer
--------------
轻量级 HTTP 服务器，提供 REST API 接口
默认在 8182 端口启动
 */
@interface TVNCHttpServer : NSObject

+ (instancetype)sharedServer;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// HTTP 服务器端口，默认 8182
@property (nonatomic, assign) NSUInteger port;

/// 是否已启动
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// WebDAV 是否启用（默认 NO，需手动开启）
@property (nonatomic, assign) BOOL webdavEnabled;

/// WebDAV 根目录（默认 /var/mobile/Media）
@property (nonatomic, copy) NSString *webdavRootPath;

/// 启动 HTTP 服务器
- (BOOL)startServer;

/// 停止 HTTP 服务器
- (void)stopServer;

/// 群控模式：是否作为主控（默认 NO）
@property (nonatomic, assign) BOOL groupMasterEnabled;

/// 群控 WebSocket 端口，默认 8183
@property (nonatomic, assign) NSUInteger groupWSPort;

/// 启动群控 WebSocket 服务器（默认端口 8183）
- (BOOL)startGroupWebSocketServer;

/// 停止群控 WebSocket 服务器
- (void)stopGroupWebSocketServer;

/// 广播群控事件到所有从控 WS 连接（主控调用）
/// @param eventJSON 事件 JSON 字符串（如 {"type":"touch","x":0.5,"y":0.3,"action":"down"}）
- (void)broadcastGroupEvent:(NSString *)eventJSON;

/// 获取当前从控连接数
- (NSInteger)groupSlaveCount;

/// 获取当前从控设备 IP 列表
- (NSArray<NSString *> *)groupSlaveIPs;

/// 广播群控事件到除指定 socket 外的所有从控
/// @param eventJSON 事件 JSON 字符串
/// @param excludeSock 排除的 socket fd（Web 客户端自身）
- (void)broadcastGroupEvent:(NSString *)eventJSON exceptSock:(int)excludeSock;

/// 从控模式：连接到主控的 WebSocket 服务器
/// @param masterIP 主控设备 IP 地址
/// @param port 主控 WS 端口
- (BOOL)connectToMaster:(NSString *)masterIP port:(NSUInteger)port;

/// 从控模式：断开与主控的连接
- (void)disconnectFromMaster;

/// 是否已连接到主控
@property (nonatomic, readonly) BOOL isConnectedToMaster;

#pragma mark - 电脑中继模式 (Relay Mode)

/// 是否启用电脑中继模式（默认 NO，NO=传统手机直连模式）
@property (nonatomic, assign) BOOL relayModeEnabled;

/// 是否已连接到电脑中继服务器
@property (nonatomic, readonly) BOOL isRelayConnected;

/// 防回环标志：YES 表示当前正在执行群控注入事件，ptrAddEvent 不应上报
@property (nonatomic, assign) BOOL isInjectingTouchEvent;

/// 连接到电脑中继服务器
/// @param relayIP 中继服务器 IP 地址
/// @param port 中继服务器 WS 端口（默认 8183）
/// @param role 设备角色："master" 或 "slave"
- (BOOL)connectToRelay:(NSString *)relayIP port:(NSUInteger)port role:(NSString *)role;

/// 断开与中继服务器的连接
- (void)disconnectFromRelay;

/// 主控设备上报真实触摸事件到中继服务器（供 ptrAddEvent 调用）
/// @param action 触摸动作：down / move / up
/// @param nx 归一化 X 坐标 (0~1)
/// @param ny 归一化 Y 坐标 (0~1)
- (void)reportRealTouchToRelay:(NSString *)action nx:(double)nx ny:(double)ny;

/// 中继 WebSocket 连接 (Unix socket FD, 只读，内部使用)
@property (nonatomic, assign) int relaySocket;

/// 通过中继 WebSocket 发送文本消息（内部使用，供 ptrAddEvent 调用）
- (void)sendRelayMessage:(NSString *)text;

@end

NS_ASSUME_NONNULL_END

#endif /* TVNCHttpServer_h */
