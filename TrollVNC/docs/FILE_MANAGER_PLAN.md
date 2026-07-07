# TrollVNC 文件管理器功能实现方案（完整版）

## 1. 目标与定位

### 1.1 功能定位
在 TrollVNC 中集成一个 **Filza 风格的文件管理器**，核心能力：

| 功能 | Filza 原生 | 本方案 |
|------|------------|--------|
| 目录浏览 | ✅ | ✅ |
| 文件/目录删除 | ✅ | ✅ |
| 权限修改 (chmod) | ✅ | ✅ |
| 重命名 | ✅ | ✅ |
| 复制/粘贴/移动 | ✅ | ✅ |
| 创建目录 | ✅ | ✅ |
| 文件详情 | ✅ | ✅ |
| 压缩/解压 | ❌ | ❌ |
| 网络文件访问 | ❌ | ❌ |

**目标**：解决 Matisu 脚本创建的 700 权限目录无法被其他 IPA 操作的问题，同时作为通用文件工具。

### 1.2 技术可行性判断

TrollVNC entitlements 关键条目：

```xml
<key>com.apple.private.security.no-container</key>     <!-- 无沙盒容器限制 -->
<key>com.apple.private.security.storage-exempt.heritable</key>  <!-- 存储访问豁免 -->
<key>platform-application</key>                       <!-- 平台应用 -->
<key>com.apple.rootless.critical</key>                <!-- rootless 绕过 -->
<key>com.apple.rootless.install</key>                  <!-- 安装绕过 -->
```

**结论**：可以直接使用 POSIX 系统调用（`unlink`, `rmdir`, `chmod`, `rename`, `mkdir` 等），无需 `posix_spawn` 提权。与 Filza 等效。

---

## 2. 系统架构

### 2.1 架构图

```
┌─────────────────────────────────────────────────────────┐
│                    TrollVNC App                         │
├─────────────────────────────────────────────────────────┤
│  TVNCViewController (Preferences UI)                    │
│    └── TVNCRootListController (设置列表)                 │
│          └── [新增] 文件管理器 按钮 ──→ TVNCFileManagerController │
│                                                          │
│  TVNCClientListController (VNC 客户端)                   │
│                                                          │
│  [新增] TVNCFileManagerController (UIKit, 独立导航)      │
│    ├── TVNCFileManagerController   主视图（文件列表）    │
│    ├── TVNCFileDetailController     文件详情             │
│    └── TVNCFileOperationController  操作菜单             │
│                                                          │
│  [新增] TVNCFileSystemService    文件操作核心（单例）    │
│    ├── unlink() / rmdir()          删除                  │
│    ├── chmod() / chmod_r()         权限修改               │
│    ├── rename()                    重命名                │
│    ├── mkdir()                     创建目录              │
│    └── copy/move                   复制/移动             │
│                                                          │
│  [新增] TVNCFileItem               数据模型              │
└─────────────────────────────────────────────────────────┘
```

### 2.2 文件变更清单

```
新增文件：
  app/TrollVNC/TrollVNC/TVNCFileItem.h              数据模型
  app/TrollVNC/TrollVNC/TVNCFileItem.m
  app/TrollVNC/TrollVNC/TVNCFileSystemService.h     文件操作服务
  app/TrollVNC/TrollVNC/TVNCFileSystemService.m
  app/TrollVNC/TrollVNC/TVNCFileManagerController.h 主文件管理器
  app/TrollVNC/TrollVNC/TVNCFileManagerController.m
  app/TrollVNC/TrollVNC/TVNCFileDetailController.h  文件详情
  app/TrollVNC/TrollVNC/TVNCFileDetailController.m

修改文件：
  app/TrollVNC/TrollVNC/TVNCRootListController.m   添加入口按钮
  app/TrollVNC/TrollVNC/zh-Hans.lproj/Root.strings 添加中文文案
  app/TrollVNC/TrollVNC/en.lproj/Root.strings      添加英文文案
  app/TrollVNC/TrollVNC.xcodeproj/project.pbxproj  添加新文件引用
```

---

## 3. 详细设计

### 3.1 TVNCFileItem（数据模型）

```objc
// TVNCFileItem.h
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVNCFileItem : NSObject

@property (nonatomic, copy, readonly) NSString *name;          // 文件名
@property (nonatomic, copy, readonly) NSString *path;           // 完整路径
@property (nonatomic, assign, readonly) BOOL isDirectory;       // 是否目录
@property (nonatomic, assign, readonly) BOOL isSymbolicLink;    // 是否符号链接
@property (nonatomic, assign, readonly) mode_t permissions;    // POSIX 权限位
@property (nonatomic, assign, readonly) uid_t ownerUID;        // owner uid
@property (nonatomic, assign, readonly) gid_t ownerGID;        // owner gid
@property (nonatomic, assign, readonly) unsigned long long size; // 文件大小
@property (nonatomic, strong, readonly) NSDate *modificationDate;
@property (nonatomic, copy, readonly) NSString *ownerName;     // owner 用户名
@property (nonatomic, copy, readonly) NSString *groupName;     // group 名

// 权限显示
- (NSString *)permissionString;        // 如 "drwxr-xr-x"
- (NSString *)permissionOctal;         // 如 "755" 或 "700"
- (NSString *)permissionDescription;   // 如 "rwxr-xr-x (755)"

// 危险等级（用于颜色标记）
// 0 = 安全（777）
// 1 = 注意（755）
// 2 = 危险（700 或更低）
- (NSInteger)dangerLevel;

// 显示用属性
- (NSString *)displaySize;             // 如 "1.2 MB"
- (NSString *)displayDate;              // 如 "2026-04-14 16:00"
- (NSString *)iconName;                 // SF Symbol 名称

// 从路径构造
+ (nullable instancetype)itemWithPath:(NSString *)path error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
```

### 3.2 TVNCFileSystemService（文件操作核心）

```objc
// TVNCFileSystemService.h
#import <Foundation/Foundation.h>

@class TVNCFileItem;

NS_ASSUME_NONNULL_BEGIN

typedef void (^TVNCFileOperationCompletion)(BOOL success, NSError *_Nullable error);
typedef void (^TVNCFileProgressCallback)(NSString *currentPath, NSUInteger completed, NSUInteger total);

@interface TVNCFileSystemService : NSObject

+ (instancetype)sharedService;

// 目录操作
- (NSArray<TVNCFileItem *> *)contentsOfDirectoryAtPath:(NSString *)path
                                                 error:(NSError **)error;
- (nullable NSArray<NSString *> *)subpathsOfDirectoryAtPath:(NSString *)path
                                                       error:(NSError **)error;

// 文件操作
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)removeItemAtPath:(NSString *)path
            withProgress:(nullable TVNCFileProgressCallback)progress
              completion:(nullable TVNCFileOperationCompletion)completion;

- (BOOL)renameItemAtPath:(NSString *)oldPath
                   toPath:(NSString *)newPath
                    error:(NSError **)error;

- (BOOL)createDirectoryAtPath:(NSString *)path
             withPermissions:(mode_t)mode
                        error:(NSError **)error;

// 权限操作
- (BOOL)setPermissions:(mode_t)mode forItemAtPath:(NSString *)path error:(NSError **)error;
- (BOOL)setPermissions:(mode_t)mode
          forItemAtPath:(NSString *)path
         withRecursive:(BOOL)recursive
                 error:(NSError **)error;

// 批量操作
- (BOOL)removeItemsAtPaths:(NSArray<NSString *> *)paths
                     error:(NSError **)error
             failedPaths:(NSArray<NSString *> * _Nullable * _Nullable)failedPaths;

- (BOOL)setPermissions:(mode_t)mode
         forItemsAtPaths:(NSArray<NSString *> *)paths
          withRecursive:(BOOL)recursive
                    error:(NSError **)error
              failedPaths:(NSArray<NSString *> * _Nullable * _Nullable)failedPaths;

// 权限值快捷常量
+ (mode_t)permission777;
+ (mode_t)permission755;
+ (mode_t)permission644;
+ (mode_t)permission700;

@end

NS_ASSUME_NONNULL_END
```

### 3.3 TVNCFileManagerController（主视图）

#### 导航结构
- 作为 `UINavigationController` 的 rootViewController
- 导航栏：标题 = 当前路径（可点击展开路径选择器）
- 右BarButtonItem：「编辑」按钮（切换多选模式）
- 左BarButtonItem：返回按钮（返回上一级或退出）

#### 工具栏（Toolbar）
```
[删除] [权限] [重命名] [复制] [移动] [新建文件夹]  ← 选中后激活
```

#### 路径栏
点击路径栏弹出路径选择器（模拟 Filza 的路径导航）：
```
/var/mobile/Media ▶ Matisu_Output ▶ logs
```
可点击任意层级跳转。

#### 列表视图（UITableView）
- 目录排在前面，文件排在后面
- 每行显示：图标 | 文件名 | 权限标识 | 大小 | 日期
- 权限标识颜色：
  - 🟢 绿色 dot = 777（安全）
  - 🟡 黄色 dot = 755（注意）
  - 🔴 红色 dot = 700 或更低（危险）
- 目录显示 `>` 箭头表示可进入
- 长按显示上下文菜单（同工具栏功能）

#### 多选模式
- 进入多选后，每个 cell 左侧出现勾选框
- 底部显示已选中数量
- 工具栏按钮全部激活

#### 搜索
- 导航栏 search bar（折叠在 scroll 下）
- 搜索文件名（不搜索内容）
- 支持当前目录递归搜索

#### 空状态
- 目录为空时显示：「文件夹为空」
- 路径不存在时显示：「路径不存在」

---

### 3.4 TVNCFileDetailController（文件详情）

```
┌─────────────────────────────────────────┐
│  ← 文件详情                              │
├─────────────────────────────────────────┤
│  📄 example.log                         │
│  路径: /var/mobile/Media/logs/example.log│
├─────────────────────────────────────────┤
│  类型           普通文件                 │
│  大小           1.2 MB                  │
│  修改时间       2026-04-14 16:00        │
│  权限           drwxr-xr-x (755)        │
│  所有者         mobile (uid=501)        │
│  所属组         mobile (gid=501)        │
├─────────────────────────────────────────┤
│  [设为 777]  [设为 755]  [设为 644]     │
│  [设为 700]  [自定义权限]               │
├─────────────────────────────────────────┤
│  [重命名]  [复制路径]  [分享]           │
│  [删除]                                 │
└─────────────────────────────────────────┘
```

---

### 3.5 权限修改弹窗

```
┌─────────────────────────────────────────┐
│  修改权限                           [完成]│
├─────────────────────────────────────────┤
│  /var/mobile/Media/Matisu_Output        │
│  当前权限: drwx------ (700)             │
├─────────────────────────────────────────┤
│  预设:                                  │
│  ○ 777 (rwxrwxrwx) — 完全开放          │
│  ● 755 (rwxr-xr-x) — 推荐               │
│  ○ 644 (rw-r--r--) — 只读               │
│  ○ 700 (drwx------) — 私有              │
├─────────────────────────────────────────┤
│  ☑ 应用到所有子目录和文件               │
└─────────────────────────────────────────┘
```

---

## 4. 集成方式

### 4.1 入口接入 TVNCRootListController

在 `TVNCRootListController.m` 的 specifiers 中追加：

```objc
// 在 specifiers 末尾找到 Tools 分组，追加按钮
[specifiers addObject:[PSSpecifier groupSpecifierWithName:@"Tools"]];
[specifiers addObject:[PSSpecifier preferenceSpecifierNamed:@"文件管理器"
                                                    target:self
                                                 setSelector:nil
                                                 getSelector:nil
                                                  detailClass:[TVNCFileManagerController class]
                                                    cellType:PSButtonCell]];
```

`detailClass` 设为 `TVNCFileManagerController`，点击后自动 push 到新视图。

### 4.2 TVNCFileManagerController 需要兼容 PSListController

由于入口通过 `PSSpecifier` 调用，`TVNCFileManagerController` 需要：
- 继承 `PSListController`（或直接继承 `UITableViewController`）
- 如果继承 `UITableViewController`，需要单独处理按钮点击

**推荐**：直接继承 `UITableViewController`，在按钮点击时手动 present/push：

```objc
// 在 TVNCRootListController.m 中：
- (void)openFileManager {
    TVNCFileManagerController *fm = [[TVNCFileManagerController alloc] init];
    fm.defaultPath = @"/var/mobile/Media";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:fm];
    [self presentViewController:nav animated:YES completion:nil];
}
```

---

## 5. 核心实现：TVNCFileSystemService

```objc
// 删除（直接调用 unlink/rmdir，无需提权）
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    struct stat st;
    if (lstat([path fileSystemRepresentation], &st) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
        return NO;
    }

    int ret;
    if (S_ISDIR(st.st_mode)) {
        ret = rmdir([path fileSystemRepresentation]);
    } else {
        ret = unlink([path fileSystemRepresentation]);
    }

    if (ret != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
        return NO;
    }
    return YES;
}

// 递归 chmod（核心功能，解决 Matisu 目录权限问题）
- (BOOL)setPermissions:(mode_t)mode
          forItemAtPath:(NSString *)path
         withRecursive:(BOOL)recursive
                 error:(NSError **)error {
    if (!recursive) {
        if (chmod([path fileSystemRepresentation], mode) != 0) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                    code:errno
                                                userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
            return NO;
        }
        return YES;
    }

    return [self chmod_r:path mode:mode error:error];
}

- (BOOL)chmod_r:(NSString *)path mode:(mode_t)mode error:(NSError **)error {
    if (chmod([path fileSystemRepresentation], mode) != 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{NSLocalizedDescriptionKey: @(strerror(errno))}];
        return NO;
    }

    DIR *dir = opendir([path fileSystemRepresentation]);
    if (!dir) return YES; // 不是目录，直接返回

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;

        char subpath[PATH_MAX];
        snprintf(subpath, sizeof(subpath), "%s/%s", [path fileSystemRepresentation], entry->d_name);

        struct stat st;
        if (lstat(subpath, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            if (![self chmod_r:@(subpath) mode:mode error:error])
                return NO;
        } else {
            if (chmod(subpath, mode) != 0) {
                // 单文件失败不中断，继续
            }
        }
    }
    closedir(dir);
    return YES;
}
```

---

## 6. UI 风格规范

### 6.1 颜色主题（复用 TrollVNC 主色）
```objc
UIColor *primaryColor = [UIColor colorWithRed:35/255.0 green:158/255.0 blue:171/255.0 alpha:1.0];
// #233E9B — TrollVNC 主色调（深蓝绿色）
```

### 6.2 权限危险度颜色
```objc
// 危险度颜色
[UIColor systemGreenColor]    // 777 — 安全
[UIColor systemYellowColor]   // 755 — 注意
[UIColor systemRedColor]      // 700 或更低 — 危险
```

### 6.3 文件图标
```objc
// SF Symbols
isDirectory  ? @"folder.fill"        : @"doc.fill"
isSymbolicLink ? @"link"             : nil
```

---

## 7. 实现步骤

### Phase 1：基础框架（第 1-2 步）
1. 创建 `TVNCFileItem.h/m` — 数据模型
2. 创建 `TVNCFileSystemService.h/m` — 文件操作核心（先写完删除和 chmod）

### Phase 2：主视图（第 3-4 步）
3. 创建 `TVNCFileManagerController.h/m` — 主列表视图
4. 创建 `TVNCFileDetailController.h/m` — 详情视图

### Phase 3：集成（第 5 步）
5. 修改 `TVNCRootListController.m` — 添加入口按钮
6. 修改 `project.pbxproj` — 添加文件引用
7. 添加国际化文案

### Phase 4：完善（第 6 步）
6. 复制/移动/重命名功能
7. 搜索功能
8. 路径快速跳转

---

## 8. 编译

```bash
cd F:\workbuddy\TrollVNC
make
```

输出：`app/TrollVNC/TrollVNC/TrollVNC.ipa`

签名由 Makefile 中的 "Pseudo Sign" phase 自动调用 `ldid` 完成。

---

## 9. 关键风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 递归删除误操作 | 用户选中整个 Media 目录后点删除 | 确认弹窗 + 路径校验（限制操作在 `/var/mobile` 以内） |
| 权限不足 | 虽然 entitlements 很强，但仍可能有个别路径受限 | 用 `strerror(errno)` 显示具体错误 |
| 阻塞主线程 | 大目录递归操作 | 所有文件操作在 `dispatch_async(dispatch_get_global_queue(...))` 中执行 |
| 符号链接循环 | 目录树中有循环链接 | 用 `lstat` 而非 `stat`，`S_ISLNK` 判断后跳过子目录递归 |
