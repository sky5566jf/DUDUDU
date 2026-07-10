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

#import "TVNCDeviceInfoController.h"
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <unistd.h>

#ifndef PACKAGE_VERSION
#define PACKAGE_VERSION "3.5"
#endif

// 获取设备型号（如 "iPhone14,5"）
NS_INLINE NSString *TVNCGetDeviceModel(void) {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

// v3.43: 获取真实设备名（与服务端 tvncGetRealDeviceName 保持一致，修复 iOS 16+ 主界面返回 "iPhone" 的问题）
NS_INLINE NSString *TVNCGetRealDeviceName(void) {
    NSString *uidName = [[UIDevice currentDevice] name];

    // 1. UIDevice 返回非泛化 "iPhone" 直接用
    if (uidName && uidName.length > 0 && ![uidName isEqualToString:@"iPhone"]) {
        return uidName;
    }

    // 2. MGCopyAnswer("DeviceName") 私有 API
    void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (mg) {
        CFStringRef (*MGCopyAnswerPtr)(CFStringRef) = (CFStringRef (*)(CFStringRef))dlsym(mg, "MGCopyAnswer");
        if (MGCopyAnswerPtr) {
            CFStringRef mgName = MGCopyAnswerPtr(CFSTR("DeviceName"));
            if (mgName) {
                NSString *result = [(__bridge_transfer NSString *)mgName
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (result.length > 0 && ![result isEqualToString:@"iPhone"]) {
                    return result;
                }
            }
        }
    }

    // 3. 读 MobileGestalt cache plist（纯文件读取，不需要 entitlement）—— 这是 iOS 16+ 拿真名的关键兜底
    NSMutableArray *mgCachePaths = [NSMutableArray array];
    if (access("/var/jb", F_OK) == 0) {
        [mgCachePaths addObject:@"/var/jb/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"];
    }
    [mgCachePaths addObject:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"];
    for (NSString *mgPath in mgCachePaths) {
        NSDictionary *mgCache = [NSDictionary dictionaryWithContentsOfFile:mgPath];
        NSDictionary *cacheExtra = mgCache[@"CacheExtra"];
        NSString *devName = cacheExtra[@"DeviceName"];
        if ([devName isKindOfClass:[NSString class]] && devName.length > 0 && ![devName isEqualToString:@"iPhone"]) {
            return devName;
        }
    }

    // 4. 读 SystemConfiguration preferences.plist 的 DeviceName
    NSMutableArray *plistPaths = [NSMutableArray array];
    if (access("/var/jb", F_OK) == 0) {
        [plistPaths addObject:@"/var/jb/var/mobile/Library/Preferences/SystemConfiguration/preferences.plist"];
        [plistPaths addObject:@"/var/jb/var/preferences/SystemConfiguration/preferences.plist"];
    }
    [plistPaths addObject:@"/var/mobile/Library/Preferences/SystemConfiguration/preferences.plist"];
    [plistPaths addObject:@"/var/preferences/SystemConfiguration/preferences.plist"];
    for (NSString *plistPath in plistPaths) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *devName = prefs[@"Controller"][@"DeviceName"];
        if (devName && devName.length > 0 && ![devName isEqualToString:@"iPhone"]) {
            return devName;
        }
    }

    // 5. sysctl kern.hostname（iOS 上 hostname 通常由设备名派生）
    char hostname[256] = {0};
    size_t hsize = sizeof(hostname);
    if (sysctlbyname("kern.hostname", hostname, &hsize, NULL, 0) == 0) {
        NSString *hn = [[NSString stringWithUTF8String:hostname]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (hn.length > 0 && ![hn isEqualToString:@"iPhone"] && ![hn isEqualToString:@"localhost"]) {
            return hn;
        }
    }

    // 6. 兜底
    if (uidName && uidName.length > 0) return uidName;
    NSString *procHostname = [[NSProcessInfo processInfo] hostName];
    if (procHostname && procHostname.length > 0) return procHostname;

    return @"iPhone";
}

// 获取局域网 IP
NS_INLINE NSString *TVNCGetEn0IPAddress(void) {
    struct ifaddrs *ifaList = NULL;
    if (getifaddrs(&ifaList) != 0 || !ifaList)
        return nil;

    NSString *ipv4 = nil;
    for (struct ifaddrs *ifa = ifaList; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_name)
            continue;
        if (strcmp(ifa->ifa_name, "en0") != 0)
            continue;
        if (!(ifa->ifa_flags & IFF_UP) || (ifa->ifa_flags & IFF_LOOPBACK))
            continue;

        sa_family_t fam = ifa->ifa_addr->sa_family;
        char buf[INET6_ADDRSTRLEN] = {0};
        if (fam == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)ifa->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                ipv4 = [NSString stringWithUTF8String:buf];
            }
        } else if (fam == AF_INET6) {
            const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)ifa->ifa_addr;
            if (!(IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr))) {
                if (inet_ntop(AF_INET6, &sin6->sin6_addr, buf, sizeof(buf))) {
                    if (!ipv4)
                        ipv4 = [NSString stringWithUTF8String:buf];
                }
            }
        }
    }
    freeifaddrs(ifaList);
    return ipv4;
}

// 格式化字节数
NS_INLINE NSString *TVNCHumanReadableSize(unsigned long long bytes) {
    NSArray<NSString *> *units = @[ @"B", @"KB", @"MB", @"GB", @"TB" ];
    int unitIndex = 0;
    double size = (double)bytes;
    while (size >= 1024.0 && unitIndex < (int)units.count - 1) {
        size /= 1024.0;
        unitIndex++;
    }
    return [NSString stringWithFormat:@"%.1f %@", size, units[unitIndex]];
}

@implementation TVNCDeviceInfoController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设备信息";
    self.primaryColor = [UIColor colorWithRed:35/255.0 green:158/255.0 blue:171/255.0 alpha:1.0];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"InfoCell"];
    self.tableView.cellLayoutMarginsFollowReadableWidth = YES;
    [self buildInfoItems];
}

- (void)buildInfoItems {
    UIDevice *device = [UIDevice currentDevice];

    NSString *appVersion = @PACKAGE_VERSION;

    NSString *deviceName = TVNCGetRealDeviceName();
    NSString *systemVersion = [NSString stringWithFormat:@"iOS %@", device.systemVersion];
    NSString *deviceModel = TVNCGetDeviceModel();

    NSString *localIP = TVNCGetEn0IPAddress();
    if (!localIP) localIP = @"无法获取";

    NSString *storagePath = @"/var/mobile";
    if (access(storagePath.UTF8String, F_OK) != 0) {
        storagePath = NSHomeDirectory();
    }
    NSDictionary *fsAttrs =
        [[NSFileManager defaultManager] attributesOfFileSystemForPath:storagePath error:nil];
    unsigned long long totalSpace = [fsAttrs[NSFileSystemSize] unsignedLongLongValue];
    unsigned long long freeSpace  = [fsAttrs[NSFileSystemFreeSize] unsignedLongLongValue];
    unsigned long long usedSpace  = totalSpace - freeSpace;
    NSString *storageInfo =
        [NSString stringWithFormat:@"%@ / %@ 可用",
                           TVNCHumanReadableSize(usedSpace),
                           TVNCHumanReadableSize(totalSpace)];

    self.infoItems = @[
        @{ @"title" : @"软件版本",   @"value" : appVersion   },
        @{ @"title" : @"设备名称",   @"value" : deviceName   },
        @{ @"title" : @"系统版本",   @"value" : systemVersion },
        @{ @"title" : @"设备型号",   @"value" : deviceModel   },
        @{ @"title" : @"局域网 IP",  @"value" : localIP      },
        @{ @"title" : @"存储空间",   @"value" : storageInfo  },
    ];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.infoItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"设备信息";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"InfoCell"
                                                            forIndexPath:indexPath];

    // registerClass: 注册的是 UITableViewCell，默认 UITableViewCellStyleDefault
    // 没有 detailTextLabel，需要重新创建带 Value1 样式的 cell
    if (!cell.detailTextLabel) {
        // 从复用池里拿到的是 Default 样式，重新创建
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                     reuseIdentifier:@"InfoCell"];
    }

    NSDictionary<NSString *, NSString *> *item = self.infoItems[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.text = item[@"value"];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.textColor = self.primaryColor ?: [UIColor darkGrayColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    NSDictionary<NSString *, NSString *> *item = self.infoItems[indexPath.row];
    NSString *value = item[@"value"];
    if (!value) return;

    // 复制到粘贴板
    [UIPasteboard generalPasteboard].string = value;

    // 视觉反馈：临时显示「已复制 ✓」
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *originalText = cell.detailTextLabel.text;
    cell.detailTextLabel.text = @"已复制 ✓";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       cell.detailTextLabel.text = originalText;
                   });
}

@end
