import subprocess
import json

r = subprocess.run(['gh', 'api', 'repos/sky5566jf/TrollVNC/actions/runs'], capture_output=True, text=True, encoding='utf-8')
d = json.loads(r.stdout)
print("最近10次构建:")
for x in d['workflow_runs'][:10]:
    print(f"  {x['id']} | {x['conclusion'] or 'running':10} | {x['head_sha'][:8]}")

# 找最近成功的一次
for x in d['workflow_runs']:
    if x['conclusion'] == 'success':
        print(f"\n最近成功: {x['id']} | {x['head_sha']}")
        break
