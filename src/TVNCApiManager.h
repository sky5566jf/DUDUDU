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

#ifndef TVNCApiManager_h
#define TVNCApiManager_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 TVNCApiManager
 --------------
 提供扩展API功能：
 1. 获取截图原图
 2. 指定位置写入文件内容
 3. 粘贴支持中文
 4. 模拟键盘输入
 */
@interface TVNCApiManager : NSObject

+ (instancetype)sharedManager;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - 截图 API

/**
 获取当前屏幕截图的原始数据（PNG格式）
 返回 PNG 格式的图片数据，如果失败返回 nil
 */
- (nullable NSData *)captureScreenshotAsPNG;

/**
 获取当前屏幕截图的原始数据（JPEG格式）
 quality: 0.0 ~ 1.0
 返回 JPEG 格式的图片数据，如果失败返回 nil
 */
- (nullable NSData *)captureScreenshotAsJPEGWithQuality:(CGFloat)quality;

/**
 获取当前屏幕截图的原始数据（带旋转）
 format: "png" 或 "jpeg"
 quality: 0.0 ~ 1.0（仅对 JPEG 有效）
 rotation: 旋转角度（0, 90, 180, 270）
   0°   → Home 在下面（默认竖屏，不旋转）
   90°  → Home 在右侧
   180° → Home 在上面
   270° → Home 在左侧
 返回旋转后的图片数据，如果失败返回 nil
 */
- (nullable NSData *)captureScreenshotWithFormat:(NSString *)format quality:(CGFloat)quality rotation:(NSInteger)rotation;

/**
 获取当前屏幕截图的原始数据（带旋转和缩放）
 format: "png" 或 "jpeg"
 quality: 0.0 ~ 1.0（仅对 JPEG 有效）
 rotation: 旋转角度（0, 90, 180, 270）
   0°   → Home 在下面（默认竖屏，不旋转）
   90°  → Home 在右侧
   180° → Home 在上面
   270° → Home 在左侧
 scale: 缩放比例（0.1 ~ 1.0，默认1.0，使用 vImageScale 高质量缩放）
 返回旋转+缩放后的图片数据，如果失败返回 nil
 */
- (nullable NSData *)captureScreenshotWithFormat:(NSString *)format quality:(CGFloat)quality rotation:(NSInteger)rotation scale:(CGFloat)scale;

#pragma mark - 文件操作 API

/**
 写入内容到指定文件路径
 @param content 要写入的内容（支持NSString或NSData）
 @param filePath 目标文件路径
 @param append 是否追加模式（YES=追加，NO=覆盖）
 @return 是否成功
 */
- (BOOL)writeContent:(id)content toFilePath:(NSString *)filePath append:(BOOL)append error:(NSError **)error;

#pragma mark - 剪贴板 API

/**
 设置剪贴板内容，支持中文
 @param text 要设置的文本内容
 @return 是否成功
 */
- (BOOL)setClipboardText:(NSString *)text;

/**
 获取剪贴板内容
 @return 剪贴板文本，如果没有内容返回 nil
 */
- (nullable NSString *)getClipboardText;

#pragma mark - 键盘输入 API

/**
 模拟键盘输入文本到当前焦点输入框
 @param text 要输入的文本内容
 @return 是否成功
 */
- (BOOL)inputText:(NSString *)text;

/**
 模拟按键事件
 @param keyCode 按键码（如回车键 13，退格键 8 等）
 @return 是否成功
 */
- (BOOL)sendKeyCode:(NSInteger)keyCode;

/**
 模拟组合键（如 Ctrl+C, Ctrl+V 等）
 @param keyCodes 按键码数组
 @return 是否成功
 */
- (BOOL)sendKeyCombination:(NSArray<NSNumber *> *)keyCodes;

#pragma mark - 系统控制 API

/**
 清理后台应用（模拟双击Home键上滑关闭所有应用）
 @return 是否成功
 */
- (BOOL)clearBackgroundApps;

/**
 设置系统音量
 @param volume 音量值 0.0 ~ 1.0
 @return 是否成功
 */
- (BOOL)setVolume:(CGFloat)volume;

/**
 获取当前系统音量
 @return 音量值 0.0 ~ 1.0，失败返回 -1
 */
- (CGFloat)getCurrentVolume;

/**
 设置屏幕亮度
 @param brightness 亮度值 0.0 ~ 1.0
 @return 是否成功
 */
- (BOOL)setBrightness:(CGFloat)brightness;

/**
 获取当前屏幕亮度
 @return 亮度值 0.0 ~ 1.0，失败返回 -1
 */
- (CGFloat)getCurrentBrightness;

#pragma mark - 应用管理 API (TrollStore)

/**
 通过 TrollStore 安装 IPA 文件
 @param ipaPath IPA 文件的完整路径
 @param error 错误信息输出
 @return 是否成功
 */
- (BOOL)installAppWithIPAPath:(NSString *)ipaPath error:(NSError **)error;

/**
 通过 TrollStore 卸载应用
 @param bundleId 应用的 Bundle ID
 @param error 错误信息输出
 @return 是否成功
 */
- (BOOL)uninstallAppWithBundleId:(NSString *)bundleId error:(NSError **)error;

/**
 检查 TrollStore 是否可用
 @return 是否可用
 */
- (BOOL)isTrollStoreAvailable;

/**
 获取 TrollStore 诊断信息
 @return 包含诊断信息的字典
 */
- (NSDictionary *)getTrollStoreDiagnostics;

#pragma mark - 系统重启/注销 API

/**
 * 重启设备
 * @return 是否成功发起重启（注意：重启后无法返回结果）
 */
- (BOOL)rebootDevice;

/**
 * 注销当前用户（Respring）
 * @return 是否成功发起注销
 */
- (BOOL)respringDevice;

#pragma mark - 智能清理后台应用

/**
 * 智能清理后台应用
 * 识别当前运行的应用并关闭，如果在桌面则跳过
 * @return 包含操作结果的字典
 */
- (NSDictionary *)clearBackgroundAppsSmart;

#pragma mark - AssistiveTouch 控制

/**
 * 禁用 AssistiveTouch（修改系统 plist）
 * 直接修改 /var/mobile/Library/Preferences/com.apple.Accessibility.plist
 * ⚠️ 警告：此操作修改系统文件，可能导致辅助功能异常
 * @return 包含操作结果的字典
 */
- (NSDictionary *)disableAssistiveTouchPermanent;

/**
 * 启用 AssistiveTouch（恢复系统 plist）
 * @return 包含操作结果的字典
 */
- (NSDictionary *)enableAssistiveTouchPermanent;

/**
 * 获取 AssistiveTouch 当前状态
 * @return 包含状态信息的字典
 */
- (NSDictionary *)getAssistiveTouchStatus;

@end

NS_ASSUME_NONNULL_END

#endif /* TVNCApiManager_h */
