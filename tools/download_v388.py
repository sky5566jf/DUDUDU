#!/usr/bin/env python3
# 监控 GitHub Actions(run head=75f34c9) → 完成后下载 4 个 artifact → 重命名 MatisuXCS_3.88.* → 落工作区 build_output/
# 注：真实 E: 盘复制由配套 Git Bash 命令完成（managed Python 的 /e 是隔离层）。
import os, sys, time, json, zipfile, glob, urllib.request, urllib.error

REPO = "sky5566jf/DUDUDU"
HEAD = "75f34c9"
API = "https://api.github.com/repos/" + REPO
OUT = r"F:\workbuddy\MatisuXCS苹果版\build_output"
DL = os.path.join(OUT, "_dl")
os.makedirs(DL, exist_ok=True)

# artifact 名 → 目标文件名
MAP = {
    "packages-bootstrap": "MatisuXCS_3.88.tipa",
    "packages-default":   "MatisuXCS_3.88_iphoneos-arm.deb",
    "packages-rootless":  "MatisuXCS_3.88_iphoneos-arm64.deb",
    "packages-roothide":  "MatisuXCS_3.88_iphoneos-arm64e.deb",
}

def token():
    with open(os.path.expanduser("~/.git-credentials"), "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            m = __import__("re").search(r"ghp_[A-Za-z0-9]+", line)
            if m: return m.group(0)
    raise SystemExit("no token")

TOK = token()

class StripAuthRedirect(urllib.request.HTTPRedirectHandler):
    """重定向时剥掉 Authorization，避免签名 URL 主机拒收。"""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)
        if new and "Authorization" in new.headers:
            del new.headers["Authorization"]
        return new

opener = urllib.request.build_opener(StripAuthRedirect)
def get(url, binary=False, raw=False):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOK, "Accept": "application/vnd.github+json"})
    with opener.open(req, timeout=120) as r:
        data = r.read()
    if raw: return data
    return data if binary else data.decode("utf-8", "replace")

# 1) 轮询 run
print("== 轮询 Actions run (head=%s) ==" % HEAD)
run_id = None
for i in range(90):  # 最多 ~30 分钟
    try:
        d = json.loads(get(API + "/actions/runs?head_sha=%s&per_page=5" % HEAD))
        rs = d.get("workflow_runs", [])
        if rs:
            run_id = rs[0]["id"]; st = rs[0]["status"]; concl = rs[0].get("conclusion")
            print("  [%ds] run=%s status=%s concl=%s" % (i*20, run_id, st, concl))
            if st == "completed":
                if concl != "success":
                    raise SystemExit("BUILD FAILED: conclusion=%s" % concl)
                break
    except Exception as e:
        print("  poll err: %s" % e)
    time.sleep(20)
else:
    raise SystemExit("TIMEOUT waiting for run")
print("== run %s completed success ==" % run_id)

# 2) 列出 artifacts
arts = json.loads(get(API + "/actions/runs/%s/artifacts" % run_id)).get("artifacts", [])
print("== artifacts: %s ==" % [a["name"] for a in arts])

for a in arts:
    name = a["name"]
    if name not in MAP:
        print("  跳过未映射 artifact: %s" % name); continue
    target = MAP[name]
    zpath = os.path.join(DL, name + ".zip")
    print("  下载 %s -> %s" % (name, target))
    blob = get(API + "/actions/artifacts/%s/zip" % a["id"], raw=True)
    with open(zpath, "wb") as f: f.write(blob)
    # 解压并找内部文件
    with zipfile.ZipFile(zpath) as z:
        z.extractall(DL)
    inner = None
    for ext in (".tipa", ".deb"):
        hits = glob.glob(os.path.join(DL, "**", "*" + ext), recursive=True)
        if hits:
            inner = hits[0]; break
    if not inner:
        raise SystemExit("artifact %s 内未找到 .tipa/.deb" % name)
    dest = os.path.join(OUT, target)
    if os.path.exists(dest): os.remove(dest)
    os.replace(inner, dest)
    print("  -> %s (%d bytes)" % (dest, os.path.getsize(dest)))

print("== 下载完成，文件清单 ==")
for f in MAP.values():
    p = os.path.join(OUT, f)
    print("  %s  exists=%s" % (f, os.path.exists(p)))
