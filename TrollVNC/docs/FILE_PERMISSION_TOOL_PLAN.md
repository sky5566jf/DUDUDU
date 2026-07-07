# TrollVNC 文件权限工具实现方案

## 1. 背景与目标

### 1.1 问题
- Matisu脚本0.0.9.ipa 在 `/var/mobile/Media` 创建的文件夹权限为 `700`（仅创建者 owner 可操作）
- 其他 IPA（包括普通 App）无法对这些文件夹执行删除操作
- 需要一个工具来修改指定目录的 POSIX 权限，使其对所有进程可访问

### 1.2 目标
在 TrollVNC 中增加一个「文件权限工具」，实现：
1. 浏览 `/var/mobile/Media` 目录结构
2. 选择指定文件夹，将其权限修改为 `777`（rwxrwxrwx）
3. 可选：递归应用到所有子目录
4. 显示操作结果（成功/失败）

### 1.3 技术可行性
TrollVNC 的 entitlements 已包含：
- `com.apple.private.security.no-container` — 无沙盒限制
- `com.apple.private.security.storage-exempt.heritable` — 存储访问豁免
- `platform-application` — 平台应用权限
- `com.apple.rootless.critical` — rootless 绕过

理论上可直接执行 `chmod` 系统调用，**不需要 `posix_spawn` 提权**。这是比普通 TrollStore IPA 更强的地方。

---

## 2. 功能规格

### 2.1 功能列表

| 功能 | 描述 | 优先级 |
|------|------|--------|
| 目录浏览 | 展示 `/var/mobile/Media` 下的文件夹列表 | P0 |
| 权限预览 | 显示当前文件夹的 POSIX 权限（drwxr-xr-x 等）和 owner | P0 |
| 设置 777 | 将选中文件夹权限改为 `777`（rwxrwxrwx） | P0 |
| 递归应用 | 递归修改所有子目录和文件的权限 | P1 |
| 操作日志 | 显示 chmod 命令执行结果（成功/失败信息） | P1 |
| 快捷路径 | 预设常用路径：Media、Documents、tmp | P2 |

### 2.2 UI 交互流程

```
┌─────────────────────────────────────┐
│  ◀ 文件权限工具           [应用全部]  │  ← 导航栏
├─────────────────────────────────────┤
│  📁 /var/mobile/Media               │  ← 路径栏（可点击）
├─────────────────────────────────────┤
│  ☐ 📁 Matisu_Output       drwx------│  ← 目录列表
│  ☐ 📁 Recordings          drwx------│
│  ☐ 📁 Screenshots         drwxr-xr-x│
│  ☐ 📁 DCIM                 drwxr-xr-x│
├─────────────────────────────────────┤
│  [ 设为 777 ]  [ 递归设为 777 ]      │  ← 底部操作按钮
│  [ 查看权限详情 ]                     │
└─────────────────────────────────────┘

点击某个目录进入子目录，长按可选中（多选），选中后底部按钮激活。
```

### 2.3 状态定义

| 状态 | 颜色 | 含义 |
|------|------|------|
| `drwx------` (700) | 🔴 红色 | 仅 owner 可访问，其他 App 无法操作 |
| `drwxr-xr-x` (755) | 🟡 黄色 | owner 可写，其他可读可执行 |
| `drwxrwxrwx` (777) | 🟢 绿色 | 所有进程可读写执行 |

### 2.4 错误处理

- 目录不存在 → 显示 alert "路径不存在"
- 权限不足 → 显示 alert "权限不足，无法修改"（理论上不会发生）
- 操作失败 → 显示具体错误信息（`strerror(errno)`）

---

## 3. 技术方案

### 3.1 文件变更清单

```
修改文件：
  app/TrollVNC/TrollVNC/TVNCRootListController.m   ← 在 specifiers 中注册新入口按钮
  app/TrollVNC/TrollVNC/zh-Hans.lproj/Root.strings  ← 添加中文文案
  app/TrollVNC/TrollVNC/en.lproj/Root.strings       ← 添加英文文案
  app/TrollVNC/TrollVNC/Base.lproj/Root.strings    ← 添加英文文案

新增文件：
  app/TrollVNC/TrollVNC/TVNCPermissionToolController.h   ← 头文件
  app/TrollVNC/TrollVNC/TVNCPermissionToolController.m   ← 实现文件
  app/TrollVNC/TrollVNC/TVNCFileSystemItem.h              ← 目录项数据模型
  app/TrollVNC/TrollVNC/TVNCFileSystemItem.m              ←
```

### 3.2 类设计

#### TVNCFileSystemItem
目录项数据模型，封装单个文件/目录的元信息：

```objc
@interface TVNCFileSystemItem : NSObject

@property (nonatomic, copy)   NSString *name;         // 文件名
@property (nonatomic, copy)   NSString *path;         // 完整路径
@property (nonatomic, assign) BOOL isDirectory;       // 是否目录
@property (nonatomic, assign) mode_t permissions;   // POSIX 权限位
@property (nonatomic, assign) uid_t ownerUID;        // owner uid
@property (nonatomic, assign) gid_t ownerGID;        // owner gid
@property (nonatomic, assign) unsigned long long size; // 文件大小
@property (nonatomic, strong) NSDate *modificationDate; // 修改时间

// 权限显示字符串（如 "drwxr-xr-x"）
- (NSString *)permissionString;

// 权限危险等级：0=安全(777) 1=警告(755) 2=危险(700)
- (NSInteger)dangerLevel;

// 权限数值（八进制，如 0755）
- (NSString *)permissionOctal;

@end
```

#### TVNCPermissionToolController
权限工具主控制器，继承 `PSListController`（与 TVNCRootListController 风格一致）：

```objc
@interface TVNCPermissionToolController : PSListController

@property (nonatomic, strong) NSString *currentPath;    // 当前浏览路径
@property (nonatomic, strong) NSMutableArray<TVNCFileSystemItem *> *items; // 当前目录项列表
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedPaths; // 选中的路径集合
@property (nonatomic, strong) UIColor *primaryColor;      // 主题色（从 RootListController 传入）

// 导航到子目录
- (void)navigateToPath:(NSString *)path;

// 返回上级目录
- (void)navigateUp;

// 刷新当前目录
- (void)refresh;

// 设置选中项为 777（不含递归）
- (void)setSelectedTo777;

// 设置选中项及子项为 777（递归）
- (void)setSelectedTo777Recursive;

// 显示选中项的权限详情
- (void)showPermissionDetail;

// 权限描述（中英文）
+ (NSString *)localizedPermissionString:(mode_t)mode;
+ (NSString *)localizedDangerLevelString:(NSInteger)level;

@end
```

### 3.3 chmod 实现（核心）

TrollVNC 的 entitlements 允许直接绕过沙盒，**直接使用系统调用**：

```objc
// 方案 A：直接 system() 调用（最简单）
int result = system("chmod -R 777 '/path/to/dir'");

// 方案 B：chmod() 系统调用（更安全）
// chmod() 是 libc 函数，iOS 上不受沙盒限制（因为 entitlements 已绕过沙盒）
int result = chmod(path, 0777);

// 递归版本
int chmod_r(const char *path, mode_t mode) {
    DIR *dir = opendir(path);
    if (!dir) return chmod(path, mode); // 文件直接 chmod

    int ret = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
            continue;

        char subpath[PATH_MAX];
        snprintf(subpath, sizeof(subpath), "%s/%s", path, entry->d_name);
        struct stat st;
        if (lstat(subpath, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                ret |= chmod_r(subpath, mode);
            }
            ret |= chmod(subpath, mode);
        }
    }
    closedir(dir);
    return ret;
}
```

**推荐方案 B**，不依赖外部命令，更可靠。

### 3.4 UI 集成方式

在 TVNCRootListController 的 specifiers 中增加一个按钮：

```objc
// 现有 specifiers 末尾追加
[specifiers addObject:[PSSpecifier groupSpecifierWithName:@"Tools"]];
[specifiers addObject:[PSSpecifier preferenceSpecifierNamed:@"文件权限工具"
                                                    target:self
                                                 setSelector:@selector(openPermissionTool)
                                                 getSelector:nil
                                                  detailClass:[TVNCPermissionToolController class]
                                                    cellType:PSButtonCell]];
```

### 3.5 国际化文案

```
// zh-Hans.lproj/Root.strings 新增
"文件权限工具" = "文件权限工具";
"设置 777" = "设为 777";
"递归设为 777" = "递归设为 777";
"权限详情" = "权限详情";
"操作成功" = "操作成功";
"操作失败" = "操作失败：%@";
"权限不足" = "权限不足，无法修改此目录";
"路径不存在" = "路径不存在：%@";
"确认操作" = "确认操作";
"确定要将选中的 %lu 个项目权限设为 777 吗？" = "确定要将选中的 %lu 个项目权限设为 777 吗？";
"递归模式会将所有子目录和文件也设为 777" = "递归模式会将所有子目录和文件也设为 777";
"权限已更新" = "权限已更新";
"权限预览" = "权限预览";
"所有者" = "所有者";
"修改时间" = "修改时间";
```

---

## 4. 实现步骤

### Step 1：创建数据模型
- 新建 `TVNCFileSystemItem.h/m`
- 实现目录项的读取和解析
- 实现 `permissionString`、`dangerLevel` 等辅助方法

### Step 2：创建主控制器框架
- 新建 `TVNCPermissionToolController.h/m`
- 实现 `viewDidLoad` 初始化 UI
- 实现 `specifiers` 返回目录列表
- 实现目录导航逻辑

### Step 3：实现权限修改核心
- 实现 `chmod()` 和 `chmod_r()` 递归修改
- 添加结果回调和错误处理
- 集成到 UI 按钮响应

### Step 4：集成到主界面
- 修改 `TVNCRootListController.m`，在 specifiers 中注册入口按钮
- 添加国际化文案

### Step 5：测试
- 编译后安装到设备
- 验证对 `/var/mobile/Media` 下各目录的权限修改
- 验证递归修改功能
- 验证 Matisu 文件夹修改后其他 IPA 可正常操作

---

## 5. 编译与构建

### 5.1 构建命令
项目使用 Makefile 构建（Theos 风格）：

```bash
# 在项目根目录
make
```

输出：`app/TrollVNC/TrollVNC/TrollVNC.ipa`

### 5.2 签名方式
TrollStore 签名使用 `ldid`：

```bash
ldid -S \
  -E TrollVNC/TrollVNC/TrollVNC.entitlements \
  -M \
  app/TrollVNC/TrollVNC/TrollVNC
```

### 5.3 打包
```bash
make package
```

---

## 6. 风险与限制

| 风险 | 说明 | 应对 |
|------|------|------|
| 权限修改后无法恢复 | chmod 不可逆 | 无自动回滚，用户需自行用 Filza 恢复 |
| 递归 chmod 耗时 | 大目录可能卡住 UI | 异步执行，用 `dispatch_async` |
| 符号链接循环 | `chmod_r` 可能陷入死循环 | 用 `lstat` 而非 `stat`，跳过符号链接目录 |
| 系统目录误操作 | 修改系统路径导致异常 | 限定操作范围在 `/var/mobile/Media` 内 |

---

## 7. 后续扩展

- **文件分享**：增加「通过 AirDrop/微信分享文件」功能
- **批量重命名**：对选中文件批量重命名
- **隐藏文件显示**：增加「显示隐藏文件」开关
- **权限模板**：预设 755、644、700 等常用权限组合
