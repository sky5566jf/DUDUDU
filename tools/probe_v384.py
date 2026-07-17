import paramiko, time, json, sys

HOST="192.69.0.99"; USER="mobile"; PW="12345678"; PORT=22
API="192.69.0.99:8182"

def ssh_run(client, cmd, timeout=15):
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors="replace")
    err = stderr.read().decode(errors="replace")
    return out, err

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PW, timeout=10)
print("=== SSH connected ===")

# 1. process
out,err = ssh_run(c, "ps -ax | grep -E 'trollvncserver|trollvncmanager' | grep -v grep")
print("=== PROCESSES ===\n"+out.strip())

# 2. API status (responsive?)
print("\n=== API /api/status (max 8s) ===")
try:
    out,err = ssh_run(c, f"curl -s --max-time 8 http://{API}/api/status; echo EXIT=$?", timeout=12)
    print(out.strip())
except Exception as e:
    print("STATUS FETCH FAIL:", e)

# 3. screenshot responsiveness (deadlock would hang)
print("\n=== API /api/screenshot (max 10s) ===")
t0=time.time()
try:
    out,err = ssh_run(c, f"curl -s --max-time 10 -o /tmp/probe_shot.jpg -w 'HTTP=%{{http_code}} SIZE=%{{size_download}} TIME=%{{time_total}}' http://{API}/api/screenshot?format=jpeg&quality=0.3&scale=0.3; echo", timeout=15)
    print(out.strip(), f"(waited {time.time()-t0:.1f}s)")
except Exception as e:
    print("SCREENSHOT FETCH FAIL (likely HUNG/deadlock):", e, f"(waited {time.time()-t0:.1f}s)")

# 4. recent crash reports with timestamps
print("\n=== RECENT CRASH REPORTS (top 12 by mtime) ===")
out,err = ssh_run(c, "ls -t /var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | head -12")
files=out.strip().split("\n")
for f in files:
    if not f.strip(): continue
    meta,err = ssh_run(c, f"stat -f '%Sm' -t '%m-%d %H:%M' '{f}'; echo '::'; head -1 '{f}' | grep -o '\"timestamp\":\"[^\"]*\"' | head -1")
    # get captureTime from json body
    body,err2 = ssh_run(c, f"grep -m1 'captureTime' '{f}' | head -c 120")
    print(f"- {f.split('/')[-1]}\n    stat:{meta.strip()[:60]}\n    {body.strip()[:110]}")

# 5. is the trollvncserver main thread spinning? sample it
print("\n=== sample trollvncserver (thread states) ===")
out,err = ssh_run(c, "PID=$(ps -ax | grep trollvncserver | grep -v grep | head -1 | awk '{print $1}'); if [ -n \"$PID\" ]; then echo \"PID=$PID\"; ps -M -o state,thread,time,command -p $PID 2>/dev/null | head -20; echo '--- sample 1s ---'; sample 1 -mayDie $PID 2>/dev/null | head -15; fi", timeout=20)
print(out.strip())

c.close()
print("\n=== DONE ===")
