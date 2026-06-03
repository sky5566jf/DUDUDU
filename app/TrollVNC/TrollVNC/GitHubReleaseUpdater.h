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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// ver.txt URL — contains the latest version number (e.g., "3.3")
FOUNDATION_EXPORT NSString *const kVerTxtURL;
/// tipa download URL for TrollStore auto-install
FOUNDATION_EXPORT NSString *const kTipaDownloadURL;

/// Simple version check result from ver.txt
@interface TVNCUpdateInfo : NSObject
@property(nonatomic, copy) NSString *latestVersion;  // version string from ver.txt (e.g., "3.3")
@property(nonatomic, copy) NSString *currentVersion; // current app version
@property(nonatomic, assign) BOOL isNewer;           // YES if latestVersion > currentVersion
@end

typedef void (^TVNCUpdateCheckCompletion)(TVNCUpdateInfo *_Nullable info, NSError *_Nullable error);

/// Lightweight updater: reads ver.txt from a fixed URL, compares version numbers.
/// No background checking — only manual trigger via checkForUpdates.
@interface TVNCVersionChecker : NSObject

@property(nonatomic, copy, readonly) NSString *currentVersion;

+ (instancetype)shared;
- (instancetype)init NS_UNAVAILABLE;

/// Set current version (called once at launch)
- (void)setCurrentVersion:(NSString *)version;

/// Check for update now (network request to ver.txt URL)
- (void)checkNowWithCompletion:(nullable TVNCUpdateCheckCompletion)completion;

@end

NS_ASSUME_NONNULL_END
