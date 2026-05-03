---
name: trollvnc-build-monitor
description: TrollVNC 编译自动监控：推送后自动轮询 GitHub Actions 状态，完成后自动下载产物到 C:\lmp\ipa\，并自动处理嵌套 zip 问题
trigger: 用户说"编译好了帮我下载"、"监控编译"、"下载产物"、推送后需要自动下载
---

# TrollVNC 编译自动监控技能

## 功能

推送代码后，自动完成：
1. 获取 GitHub Actions run ID
2. 每 30 秒轮询编译状态
3. 编译完成后自动下载产物到 `C:\lmp\ipa\`
4. **自动处理嵌套 zip**（GitHub Actions artifact 可能包两层 zip，导致 TrollStore 安装 301 错误）

---

## 使用步骤

### 1. 推送代码并获取 run ID

```bash
git push origin main
# 获取最新的 run ID
gh run list --repo sky5566jf/TrollVNC --limit 1 --json databaseId --jq '.[0].databaseId'
```

### 2. 轮询编译状态

```bash
# 每 30 秒检查一次，直到 completed
while true; do
  status=$(gh run view <run_id> --repo sky5566jf/TrollVNC --json status --jq '.status')
  echo "$(date '+%H:%M:%S') Status: $status"
  if [ "$status" = "completed" ]; then
    # 检查是否成功
    conclusion=$(gh run view <run_id> --repo sky5566jf/TrollVNC --json conclusion --jq '.conclusion')
    echo "Conclusion: $conclusion"
    break
  fi
  sleep 30
done
```

### 3. 下载产物（自动处理嵌套 zip）

**方法 A：使用 devkit/download_artifact.py（推荐）**

```bash
# 获取 artifact ID
gh api repos/sky5566jf/TrollVNC/actions/artifacts --jq '.artifacts[0] | "\(.id) \(.name)"'

# 下载（脚本自动处理嵌套 zip）
python devkit/download_artifact.py <artifact_id> "C:\lmp\ipa\TrollVNC.tipa"
```

**方法 B：使用 gh run download**

```bash
# 下载到当前目录
gh run download <run_id> --repo sky5566jf/TrollVNC

# 检查是否有嵌套 zip，如果有则解包
# 见下方"嵌套 ZIP 处理"章节
```

下载完成后，移动产物到 `C:\lmp\ipa\`：

```bash
mv TrollVNC-*.tipa "C:\lmp\ipa\TrollVNC-v3.1.4.tipa"
```

---

## 嵌套 ZIP 处理（重要！）

**问题**：GitHub Actions artifact 可能将 `.tipa` 再包一层 `.zip`，导致 TrollStore 安装时出现 **301 错误**。

**检测方法**：

```python
import zipfile, io

def is_nested_zip(data):
    """检测是否是嵌套的 zip（外层 zip 里只有一个文件，且是 .tipa 或 .zip）"""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            names = zf.namelist()
            if len(names) == 1 and (names[0].endswith('.tipa') or names[0].endswith('.zip')):
                return True, names[0], zf.read(names[0])
        return False, None, None
    except zipfile.BadZipFile:
        return False, None, None
```

**修复方法**（已集成到 `devkit/download_artifact.py`）：

```python
# 下载到的原始数据
data = urllib.request.urlopen(blob_url).read()

# 检查是否需要解包
nested, inner_name, inner_data = is_nested_zip(data)
if nested:
    # inner_data 才是真正的 tipa，直接保存
    with open(output_path, "wb") as f:
        f.write(inner_data)
    print(f"已解包嵌套 zip，提取内层文件: {inner_name}")
else:
    # 直接保存
    with open(output_path, "wb") as f:
        f.write(data)
```

**手动修复已有的嵌套 zip**：

如果你已经下载了一个嵌套的 zip，可以用下面的 Python 代码修复：

```python
import zipfile, shutil

def fix_nested_tipa(bad_zip_path, output_path):
    with zipfile.ZipFile(bad_zip_path) as zf:
        names = zf.namelist()
        if len(names) == 1:
            # 提取内层文件
            inner_path = zf.extract(names[0], "/tmp")
            shutil.move(inner_path, output_path)
            print(f"修复完成: {output_path}")
        else:
            print("不是嵌套 zip，无需修复")

# 用法
fix_nested_tipa("C:/lmp/ipa/bad.zip", "C:/lmp/ipa/TrollVNC.tipa")
```

---

## 完整自动化脚本

把以下内容保存为 `devkit/auto_download.py`，推送后运行即可自动完成所有步骤：

```python
#!/usr/bin/env python3
"""
自动监控编译并下载产物，自动处理嵌套 zip
用法: python auto_download.py <run_id>
"""
import subprocess, time, sys, os, io, zipfile, urllib.request

REPO = "sky5566jf/TrollVNC"
OUTPUT_DIR = "C:/lmp/ipa"

def get_token():
    return subprocess.check_output(["gh", "auth", "token"], text=True).strip()

def wait_for_completion(run_id):
    """等待编译完成，每 30 秒检查一次"""
    while True:
        result = subprocess.run(
            ["gh", "run", "view", run_id, "--repo", REPO, "--json", "status,conclusion"],
            capture_output=True, text=True
        )
        import json
        data = json.loads(result.stdout)
        status = data.get("status")
        print(f"[{time.strftime('%H:%M:%S')}] Status: {status}")
        if status == "completed":
            conclusion = data.get("conclusion")
            print(f"编译完成！结果: {conclusion}")
            return conclusion == "success"
        time.sleep(30)

def download_artifact(run_id):
    """下载产物，自动处理嵌套 zip"""
    # 获取 artifact ID
    result = subprocess.run(
        ["gh", "api", f"repos/{REPO}/actions/runs/{run_id}/artifacts"],
        capture_output=True, text=True
    )
    import json
    artifacts = json.loads(result.stdout).get("artifacts", [])
    if not artifacts:
        print("没有找到 artifact")
        return False

    artifact_id = artifacts[0]["id"]
    print(f"下载 artifact: {artifact_id}")

    token = get_token()
    url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{artifact_id}/zip"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
    })

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    opener = urllib.request.build_opener(NoRedirect)
    try:
        opener.open(req)
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308):
            blob_url = e.headers.get("Location")
            with urllib.request.urlopen(blob_url) as r:
                data = r.read()

            # 处理嵌套 zip
            data_io = io.BytesIO(data)
            try:
                with zipfile.ZipFile(data_io) as zf:
                    names = zf.namelist()
                    if len(names) == 1 and (names[0].endswith('.tipa') or names[0].endswith('.zip')):
                        inner_data = zf.read(names[0])
                        output_path = os.path.join(OUTPUT_DIR, "TrollVNC.tipa")
                        os.makedirs(OUTPUT_DIR, exist_ok=True)
                        with open(output_path, "wb") as f:
                            f.write(inner_data)
                        print(f"已下载（解包嵌套 zip）: {output_path}")
                        return True
            except zipfile.BadZipFile:
                pass

            # 不是嵌套 zip，直接保存
            output_path = os.path.join(OUTPUT_DIR, "TrollVNC.tipa")
            os.makedirs(OUTPUT_DIR, exist_ok=True)
            with open(output_path, "wb") as f:
                f.write(data)
            print(f"已下载: {output_path}")
            return True
    return False

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python auto_download.py <run_id>")
        sys.exit(1)

    run_id = sys.argv[1]
    print(f"监控编译 run_id={run_id}")

    if wait_for_completion(run_id):
        download_artifact(run_id)
    else:
        print("编译失败，不下载")
        sys.exit(1)
```

---

## 常见问题

### Q: 安装时提示 301 错误
**A**: 产物是嵌套 zip，用上面的方法解包后得到真正的 `.tipa` 文件再安装。

### Q: 产物下载到哪里？
**A**: `C:\lmp\ipa\`，这是规定的统一目录。

### Q: 如何确认 tipa 不是嵌套 zip？
**A**: 用 `zipfile.is_zipfile()` 检测，如果外层是 zip 但内层还是 zip，就是嵌套的。

---

## 版本历史

- **v1.1** (2026-05-03): 新增嵌套 zip 自动处理，修复 301 安装错误
- **v1.0** (2026-05-03): 初始版本，支持编译监控和自动下载
