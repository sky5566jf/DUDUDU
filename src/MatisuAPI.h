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

#ifndef MatisuAPI_h
#define MatisuAPI_h

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * MatisuAPI
 * --------
 * Custom API server for MatisuVNC providing:
 * 1. Screenshot capture (full resolution original image)
 * 2. File write to specified path
 * 3. Clipboard with full Unicode/Chinese support
 *
 * The API runs on a configurable port (default 8080) and provides
 * RESTful endpoints for remote control.
 */
@interface MatisuAPI : NSObject

/// Shared singleton instance
+ (instancetype)sharedAPI;

/// Start the API server on the specified port
/// @param port The TCP port to listen on (default 8080)
/// @return YES if server started successfully
- (BOOL)startServerOnPort:(int)port;

/// Stop the API server
- (void)stopServer;

/// Check if server is running
@property (nonatomic, readonly, getter=isRunning) BOOL running;

/// Current server port
@property (nonatomic, readonly) int port;

/**
 * Capture current screen and return as PNG data
 * @return PNG image data or nil if capture fails
 */
- (nullable NSData *)captureScreenAsPNG;

/**
 * Capture current screen and return as JPEG data
 * @param quality JPEG compression quality (0.0-1.0)
 * @return JPEG image data or nil if capture fails
 */
- (nullable NSData *)captureScreenAsJPEGWithQuality:(float)quality;

/**
 * Write data to a specified file path
 * @param data The data to write
 * @param path The absolute file path
 * @param error Error pointer for failure details
 * @return YES if write succeeded
 */
- (BOOL)writeData:(NSData *)data toPath:(NSString *)path error:(NSError **)error;

/**
 * Write string content to a specified file path (supports UTF-8/Chinese)
 * @param content The string content to write
 * @param path The absolute file path
 * @param error Error pointer for failure details
 * @return YES if write succeeded
 */
- (BOOL)writeString:(NSString *)content toPath:(NSString *)path error:(NSError **)error;

/**
 * Read content from a specified file path
 * @param path The absolute file path to read
 * @param error Error pointer for failure details
 * @return File content as string, or nil if read fails
 */
- (nullable NSString *)readStringFromPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif /* MatisuAPI_h */
