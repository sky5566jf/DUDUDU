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

#import "GitHubReleaseUpdater.h"

// ver.txt URL — HTTPS GitHub raw (ATS safe), contains latest version number (e.g., "3.4")
NSString *const kVerTxtURL = @"https://raw.githubusercontent.com/sky5566jf/TrollVNC-main/release/ver.txt";
// tipa download URL — fixed HTTP address (TrollStore handles the download, ATS doesn't apply)
NSString *const kTipaDownloadURL = @"http://106.15.63.124:8888/down/jccM2Fl6Sn1l.tipa";

#if DEBUG
#define TVNCUpLog(fmt, ...) NSLog((@"[TVNCUpdater] " fmt), ##__VA_ARGS__)
#else
#define TVNCUpLog(fmt, ...) do {} while (0)
#endif

#pragma mark - TVNCUpdateInfo

@implementation TVNCUpdateInfo
@end

#pragma mark - TVNCVersionChecker

@interface TVNCVersionChecker ()
@property(nonatomic, copy) NSString *currentVersion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation TVNCVersionChecker

+ (instancetype)shared {
    static TVNCVersionChecker *inst;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[TVNCVersionChecker alloc] initPrivate];
    });
    return inst;
}

- (instancetype)initPrivate {
    if (self = [super init]) {
        _queue = dispatch_queue_create("com.82flex.trollvnc.TVNCVersionChecker.queue", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 15;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (instancetype)init {
    NSAssert(NO, @"Use +shared");
    return nil;
}

- (void)setCurrentVersion:(NSString *)version {
    _currentVersion = [version copy] ?: @"";
}

#pragma mark - Public API

- (void)checkNowWithCompletion:(TVNCUpdateCheckCompletion)completion {
    dispatch_async(self.queue, ^{
        [self _performCheckLockedWithCompletion:completion];
    });
}

#pragma mark - Internals

- (void)_performCheckLockedWithCompletion:(TVNCUpdateCheckCompletion)completion {
    // Cancel any in-flight request
    if (self.task && self.task.state == NSURLSessionTaskStateRunning) {
        [self.task cancel];
    }
    self.task = nil;

    NSURL *url = [NSURL URLWithString:kVerTxtURL];
    if (!url) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"TVNCVersionChecker" code:400
                                           userInfo:@{NSLocalizedDescriptionKey: @"Invalid ver.txt URL"}];
            completion(nil, err);
        }
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    // Add cache-busting query param
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *cacheBust = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970] * 1000];
    if (!components.queryItems) {
        components.queryItems = @[[NSURLQueryItem queryItemWithName:@"_t" value:cacheBust]];
    } else {
        NSMutableArray *items = [components.queryItems mutableCopy];
        [items addObject:[NSURLQueryItem queryItemWithName:@"_t" value:cacheBust]];
        components.queryItems = items;
    }
    req.URL = components.URL;

    TVNCUpLog("Checking ver.txt at %@...", req.URL);

    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;

        if (error) {
            TVNCUpLog("Network error: %@", error);
            if (completion) completion(nil, error);
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString *msg = [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
            TVNCUpLog("HTTP error: %@", msg);
            NSError *err = [NSError errorWithDomain:@"TVNCVersionChecker" code:http.statusCode
                                           userInfo:@{NSLocalizedDescriptionKey: msg}];
            if (completion) completion(nil, err);
            return;
        }

        // Parse ver.txt content — expect a single version string like "3.3" or "3.4"
        NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *latestVersion = [content stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Validate: must match X.Y format (e.g. "3.4")
        NSRegularExpression *verRe = [NSRegularExpression
            regularExpressionWithPattern:@"^\\d+(\\.\\d+)?$"
                                 options:0 error:nil];
        NSTextCheckingResult *match = [verRe firstMatchInString:latestVersion
                                                         options:0 range:NSMakeRange(0, latestVersion.length)];
        if (!match) {
            NSError *err = [NSError errorWithDomain:@"TVNCVersionChecker" code:500
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                       [NSString stringWithFormat:@"ver.txt 返回格式错误: %@", latestVersion]}];
            if (completion) completion(nil, err);
            return;
        }

        TVNCUpLog("ver.txt returned: %@, current: %@", latestVersion, s.currentVersion);

        TVNCUpdateInfo *info = [[TVNCUpdateInfo alloc] init];
        info.latestVersion = latestVersion;
        info.currentVersion = s.currentVersion;
        info.isNewer = [s _isVersion:latestVersion newerThan:s.currentVersion];

        if (completion) completion(info, nil);
    }];
    [self.task resume];
}

- (BOOL)_isVersion:(NSString *)remote newerThan:(NSString *)current {
    if (!remote || !current)
        return NO;

    // Parse as float for simple 3.3 vs 3.4 comparison
    double remoteVal = [remote doubleValue];
    double currentVal = [current doubleValue];

    if (remoteVal == 0.0 || currentVal == 0.0) {
        // Fallback: string comparison
        return ([remote compare:current options:NSNumericSearch] == NSOrderedDescending);
    }

    return remoteVal > currentVal;
}

@end
