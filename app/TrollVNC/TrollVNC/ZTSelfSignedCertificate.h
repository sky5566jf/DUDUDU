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

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZTSelfSignedCertificate : NSObject

/// PEM 鏍煎紡鐨勮嚜绛捐瘉涔︼紙-----BEGIN CERTIFICATE-----锛?@property (nonatomic, readonly) NSString *certificatePEM;

/// PEM 鏍煎紡鐨勭閽ワ紙-----BEGIN RSA PRIVATE KEY-----锛?@property (nonatomic, readonly) NSString *privateKeyPEM;

/// 鐢熸垚涓€涓?RSA 2048 鑷璇佷功 + 绉侀挜锛岀敤 commonName 浣滀负 CN銆?/// 澶辫触杩斿洖 nil銆?+ (nullable instancetype)generateWithCommonName:(NSString *)commonName;

@end

NS_ASSUME_NONNULL_END
