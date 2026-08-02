//
//  TVNCHttpServer+Reflect.mm
//  TEMPORARY DEBUG ENDPOINT — Plan A (runtime symbol reflection)
//
//  用途：从真机运行时反射 AppleAccount / AuthKit 等私有框架的真实类与方法，
//        以钉死 iOS 13 / iOS 16 上 Apple ID 登录所需的私有 selector。
//        ⚠️ 这是临时调试接口，符号提取完成后必须从 4.45 正式版移除（连同路由与 Makefile 条目）。
//        该接口只读、无副作用、无鉴权；正式账号管理接口必须前置 token 校验。
//

#import "TVNCHttpServer+Handlers.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>

#pragma mark - 私有工具（文件局部，避免跨翻译单元符号冲突）

// 尝试按 rootful / rootless 两种路径 dlopen 私有框架，返回实际加载路径或 nil
static NSString *TVNCLoadFramework(NSString *name) {
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/var/jb/System/Library/PrivateFrameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", name, name],
        [NSString stringWithFormat:@"/var/jb/System/Library/Frameworks/%@.framework/%@", name, name],
    ];
    for (NSString *p in candidates) {
        if (access([p fileSystemRepresentation], F_OK) == 0) {
            dlopen([p fileSystemRepresentation], RTLD_LAZY | RTLD_GLOBAL);
            return p;
        }
    }
    // 即便磁盘上无独立二进制（dyld_shared_cache 合并），仍尝试一次 dlopen 触发共享缓存映射
    NSString *fallback = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
    dlopen([fallback fileSystemRepresentation], RTLD_LAZY | RTLD_GLOBAL);
    fallback = [NSString stringWithFormat:@"/var/jb/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
    dlopen([fallback fileSystemRepresentation], RTLD_LAZY | RTLD_GLOBAL);
    return nil;
}

// 枚举属于某框架镜像的全部类（用于发现真实类名）
static NSArray<NSString *> *TVNCClassesInFramework(NSString *fwk) {
    unsigned int n = objc_getClassList(NULL, 0);
    if (!n) return @[];
    Class *list = (Class *)malloc(sizeof(Class) * n);
    objc_getClassList(list, n);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSString *needle = [NSString stringWithFormat:@"%@.framework", fwk];
    const char *nd = [needle UTF8String];
    for (unsigned i = 0; i < n; i++) {
        const char *img = class_getImageName(list[i]);
        if (img && strstr(img, nd)) {
            [out addObject:NSStringFromClass(list[i])];
        }
    }
    free(list);
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

// 反射单个类的实例/类方法、属性、协议、父类
static NSDictionary *TVNCReflectClass(NSString *name) {
    // 必须先确保私有框架已加载，否则 NSClassFromString 可能仅返回未加载实现的类桩
    // （superclass 为 nil、方法表为空），导致反射无内容。
    TVNCLoadFramework(@"AppleAccount");
    TVNCLoadFramework(@"AuthKit");
    TVNCLoadFramework(@"Accounts");
    Class cls = NSClassFromString(name);
    if (!cls) return @{@"class": name, @"found": @NO};

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"class"] = name;
    d[@"found"] = @YES;
    d[@"superclass"] = NSStringFromClass(class_getSuperclass(cls));

    unsigned int mc = 0;
    Method *ml = class_copyMethodList(cls, &mc);
    NSMutableArray *im = [NSMutableArray array];
    for (unsigned i = 0; i < mc; i++) {
        [im addObject:[NSString stringWithUTF8String:sel_getName(method_getName(ml[i]))]];
    }
    free(ml);
    d[@"instanceMethods"] = im;

    unsigned int cmc = 0;
    Method *cml = class_copyMethodList(object_getClass(cls), &cmc);
    NSMutableArray *cm = [NSMutableArray array];
    for (unsigned i = 0; i < cmc; i++) {
        [cm addObject:[NSString stringWithUTF8String:sel_getName(method_getName(cml[i]))]];
    }
    free(cml);
    d[@"classMethods"] = cm;

    unsigned int pc = 0;
    objc_property_t *pl = class_copyPropertyList(cls, &pc);
    NSMutableArray *props = [NSMutableArray array];
    for (unsigned i = 0; i < pc; i++) {
        NSString *pn = [NSString stringWithUTF8String:property_getName(pl[i])];
        NSString *attrs = [NSString stringWithUTF8String:property_getAttributes(pl[i])];
        [props addObject:@{@"name": pn, @"attrs": attrs}];
    }
    free(pl);
    d[@"properties"] = props;

    unsigned int ptc = 0;
    __unsafe_unretained Protocol **ptl = class_copyProtocolList(cls, &ptc);
    NSMutableArray *protos = [NSMutableArray array];
    for (unsigned i = 0; i < ptc; i++) {
        [protos addObject:NSStringFromProtocol(ptl[i])];
    }
    free(ptl);
    d[@"protocols"] = protos;

    return d;
}

@implementation TVNCHttpServer (Handlers)

#pragma mark - 路由处理

- (TVNCHttpResponse *)handleReflect:(NSDictionary *)query {
    TVNCHttpResponse *resp = [[TVNCHttpResponse alloc] init];
    resp.statusCode = 200;
    resp.contentType = @"application/json; charset=utf-8";

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    out[@"systemVersion"] = [NSString stringWithFormat:@"%ld.%ld.%ld",
                             (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];

    // 预加载账号相关私有框架，确保后续 prefix/class 反射都能拿到完整方法表
    TVNCLoadFramework(@"AppleAccount");
    TVNCLoadFramework(@"AuthKit");
    TVNCLoadFramework(@"Accounts");

    NSString *framework = query[@"framework"];
    NSString *cls = query[@"class"];
    NSString *prefix = query[@"prefix"];

    if (framework) {
        NSString *loaded = TVNCLoadFramework(framework);
        out[@"framework"] = framework;
        out[@"loadedPath"] = loaded ? (id)loaded : (id)[NSNull null];
        out[@"classes"] = TVNCClassesInFramework(framework);
    }
    if (cls) {
        out[@"reflect"] = TVNCReflectClass(cls);
    } else if (!framework && prefix) {
        unsigned int n = objc_getClassList(NULL, 0);
        Class *list = (Class *)malloc(sizeof(Class) * n);
        objc_getClassList(list, n);
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) {
            NSString *nm = NSStringFromClass(list[i]);
            if ([nm hasPrefix:prefix]) [names addObject:nm];
        }
        free(list);
        [names sortUsingSelector:@selector(compare:)];
        out[@"prefix"] = prefix;
        out[@"classes"] = names;
    } else if (!framework && !cls) {
        out[@"hint"] = @"use ?framework=AuthKit | ?class=AKAppleIDSession | ?prefix=AK";
    }

    NSError *e = nil;
    resp.body = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:&e];
    if (!resp.body) {
        resp.body = [[e localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
    }
    return resp;
}

@end
