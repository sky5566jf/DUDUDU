# 质量护栏（Quality Gate）接入与规范

> 配套文件：
> - `.github/workflows/quality-gate.yml` — CI 质量 job
> - `quality/TVNCInputStrategy.{h,c,_test.c}` + `quality/run_tests.sh` — 纯 C 单测骨架
> - 历史规范：`docs/代码评审Checklist.md`、`docs/团队技术能力提升方案.md`

本文档聚焦**如何让质量护栏真正跑起来**，以及把「文本输入反复回归」的历史坑固化成机器可验证的不变式。

---

## 1. 为什么需要质量护栏

v4.01 → v4.10 共 10 个版本都围绕「文本输入级联顺序」打转（HID / UIKeyboardImpl / AX / 剪贴板反复横跳，还出过端口冲突 8183、递归崩溃、自死锁）。根因不是个人能力，而是**工程护栏缺失**：

1. **没有测试** → 改动只能靠真机盲测，回归要等设备实测才暴露；
2. **逻辑耦合在 2657 行的 `TVNCApiManager`** → 级联顺序一改牵一发动全身；
3. **没有决策记录（ADR）** → 每次「凭记忆」重排，导致来回倒退。

质量护栏 = 用自动化把「改动能被验证」这件事固化下来。

---

## 2. 单测骨架（立刻可用，零依赖）

`quality/` 目录是一个**完全独立、不依赖 theos/UIKit** 的纯 C 模块：

| 文件 | 作用 |
|---|---|
| `TVNCInputStrategy.h` | 策略与约束的纯 C 接口 |
| `TVNCInputStrategy.c` | 实现（仅决策，不执行、不返回「成功」） |
| `TVNCInputStrategy_test.c` | 不变式单测（无外部框架，断言计数） |
| `run_tests.sh` | 本地/CI 入口，`-Wall -Wextra -Werror` 严格编译 |

**本地跑：**
```bash
bash quality/run_tests.sh
```

**CI 跑：** `quality-gate.yml` 的 `unit-tests` job 在每次 push/PR 到 `release|main|master` 时自动执行，零 theos 依赖、秒级完成。

### 设计要点：决策与执行分离
`TVNCSelectPrimaryInput()` **只返回「该用哪种方式」，不执行、不返回成功**。
这从设计上杜绝了 v4.02「UIKeyboardImpl 假成功短路级联」类回归——调用方负责执行与回退，
策略函数本身不可能「假成功就 return」。

### 已固化的不变式（来自 CHANGELOG 的真实坑）
| # | 不变式 | 防的回归 |
|---|---|---|
| 1 | daemon 上下文**永不**选 AX | v4.07 daemon 内调 AX 必崩 |
| 2 | 输入转发端口 ≠ 8183 | v4.08 与 daemon Group WS 端口冲突 |
| 3 | 有 App 服务 + 第一响应者 → 第一响应者 | v4.10 终态 |
| 4 | 无焦点 / 无 App 服务 → 剪贴板兜底 | v4.10 统一终态 |
| 5 | App 进程 + 有 AX 授权 → AX（零弹窗） | v4.06 中文通道 |
| 6 | NULL 上下文安全 | 防御性 |

**新增输入相关逻辑时，先在这里加一条不变式，再写实现。**

---

## 3. 静态分析（best-effort）

`quality-gate.yml` 的 `static-analysis` job 目前对纯 C 模块跑 `clang --analyze`（稳、零依赖），
并标记为 `continue-on-error`（best-effort），**不阻塞主构建**。

后续若要深入扫描 daemon 源（`src/*.mm`），需完整 theos + iOS SDK 环境（参考 `build.yml` 的 theos checkout 步骤），
可用 `scan-build` 包裹 `make`。因 theos 子模块偶发拉取失败，建议保持 best-effort 或独立调度，避免污染主构建信号。

---

## 4. 警告预算（Warning Budget）

体检发现编译期信号基本被无视，需收敛：

- **9 处 `#warning` → 已升级为 `#error`**：原为 `#if !__has_feature(objc_arc)` 保护的
  `This file must be compiled with ARC`。现已改为 `#error`——正常 ARC 构建下 `#if` 为假不触发；
  若有人误以非 ARC 编译，直接编译失败（比弱 warning 更严，符合「暴露而非隐藏」）。涉及 8 个真实源文件
  （`.bak` 副本保留原样）。
- **`-Wno-unused-but-set-variable`（Makefile）已删除**：不再抑制「已赋值未使用变量」，让潜在未初始化/死代码
  告警暴露。CI 若出现相关告警应修代码而非重新抑制。
- **目标**：逐步把 `make` 的告警数收敛到 0，并可考虑对纯 C 模块强制 `-Werror`（已在 `run_tests.sh` 启用）。

---

## 5. 版本号与还原约定

- 改造前已打备份 tag：`v4.17`（指向 `062e6ee`，含未提交开发改动）。
  还原：`git fetch origin && git checkout v4.17`。
- ⚠️ **发版冲突提醒**：`build.yml` 的 `release` job 会在 push 到 `release` 分支时读 `Makefile` 的
  `PACKAGE_VERSION` 自动创建 `vX.XX` tag 并建 GitHub Release。**发版前务必先把 `Makefile` 版本号 +1**
  （如 4.17 → 4.18），否则会与手动备份 tag 冲突。这本来就是发版铁律要求。

---

## 6. 与既有规范的关系

- `docs/代码评审Checklist.md`：Code Review 时逐条核对。
- `docs/团队技术能力提升方案.md`：团队整体提升路线图。
- 本文件：聚焦**质量护栏的技术接入**与**输入级联不变式**。

---

## 7. 已落地进展（架构解耦第一步）

`TVNCInputStrategy` 已从「仅 CI 单测」升级为 **daemon 真实决策引擎**：

- `Makefile`：将 `quality/TVNCInputStrategy.c` 链入 `trollvncserver` 构建，并加 `-Iquality` 使 `src/*.mm` 可 `#include "TVNCInputStrategy.h"`。
- `src/TVNCApiManager.mm` 的 `inputText:` 改为**先查 `TVNCSelectPrimaryInput()` 决策、再调保留的执行方法**；
  第一响应者插入抽成 `tvncInsertViaFirstResponder:`，决策上下文由 `tvncBuildInputContextForText:` 构建。
- 行为完全保持（daemon 下有焦点走第一响应者、否则走剪贴板兜底），但「选通道」这一步现在由已单测验证的策略统一决定，
  从根上消除 v4.01–v4.10 的级联顺序反复横跳。

> 这是「逐步迁移」的第一步：决策已策略化，后续可把 HID/AX/剪贴板等执行方法也按需收敛，进一步削薄巨文件。

## 8. 群控前端现代化（已落地）

`group-control/relay-server/relay-server.js` 与 `pc_group_control.html`：

- **WS 鉴权（可选）**：relay 读取环境变量 `RELAY_TOKEN`，设置后所有 WS 连接须带 `?token=XXX`，否则 401 拒绝；
  未设置则向后兼容历史客户端。浏览器端新增 Token 输入框并随连接 URL 带上、本地保存。
- **真实设备名**：relay 新增 `GET /api/device?ip=` 代理（转发到手机 REST `:8182/api/device`）；
  浏览器在设备加载/中继连接成功后经该代理拉取真实设备名，替换扫码占位名（失败保留原名，不阻断）。
- 两文件均通过语法校验（relay `node --check`、HTML 内联 JS `new Function` 解析均 0 错误）。

**落地顺序建议**：先让 `quality-gate.yml` + `quality/` 单测在 CI 跑绿（护栏就位）→
再把 daemon 输入级联逻辑逐步迁移到 `TVNCInputStrategy` 决策接口（解耦）→
最后清理 `-Wno` 与 `#warning`（警告清零）。每一步都有测试兜底，避免新回归。
