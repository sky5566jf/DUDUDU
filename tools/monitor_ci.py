#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
轮询 GitHub Actions 构建状态，直到 completed。
用法: python tools/monitor_ci.py <head_sha> [repo]
- 自动从 ~/.git-credentials 提取 ghp_ token
- 找到指定 head_sha 的最新 run，循环打印 status/conclusion
- 完成后打印每个 job 的状态，exit
"""
import os, re, sys, json, time, urllib.request, urllib.error

def load_token():
    p = os.path.expanduser("~/.git-credentials")
    try:
        with open(p, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                m = re.search(r"gh[pousr]_[A-Za-z0-9]{20,}", line)
                if m:
                    return m.group(0)
    except FileNotFoundError:
        pass
    return None

HEAD = sys.argv[1] if len(sys.argv) > 1 else "7d402e8"
REPO = sys.argv[2] if len(sys.argv) > 2 else "sky5566jf/DUDUDU"
API = "https://api.github.com"
TOK = load_token()
if not TOK:
    print("ERROR: no github token found"); sys.exit(2)

HDR = {"Authorization": f"Bearer {TOK}",
       "Accept": "application/vnd.github+json",
       "X-GitHub-Api-Version": "2022-11-28"}

def get(url, tries=5):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers=HDR)
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 403:
                time.sleep(5); continue
            raise
        except Exception:
            if i == tries-1: raise
            time.sleep(3)

def find_run():
    data = get(f"{API}/repos/{REPO}/actions/runs?per_page=30&head_sha={HEAD}")
    runs = data.get("workflow_runs", [])
    if runs:
        return runs[0]
    return None

print(f"[monitor] HEAD={HEAD} REPO={REPO}")
run = None
for _ in range(20):
    run = find_run()
    if run:
        break
    print("[monitor] run not created yet, waiting 10s...")
    time.sleep(10)

if not run:
    print("[monitor] ERROR: no run found for head_sha"); sys.exit(3)

run_id = run["id"]
print(f"[monitor] RUN_ID={run_id} start_status={run['status']}")

while True:
    r = get(f"{API}/repos/{REPO}/actions/runs/{run_id}")
    st, con = r["status"], r.get("conclusion")
    print(f"[{time.strftime('%H:%M:%S')}] status={st} conclusion={con}")
    if st == "completed":
        jobs = get(f"{API}/repos/{REPO}/actions/runs/{run_id}/jobs")
        print(f"[monitor] === jobs ({len(jobs.get('jobs', []))}) ===")
        for j in jobs.get("jobs", []):
            print(f"  - {j['name']}: {j['status']} / {j.get('conclusion')}")
        # 汇总
        bad = [j['name'] for j in jobs.get('jobs', []) if j.get('conclusion') not in ('success', None)]
        if bad:
            print(f"[monitor] FAILED_JOBS={bad}")
            sys.exit(1)
        print("[monitor] ALL_GREEN")
        sys.exit(0)
    time.sleep(30)
