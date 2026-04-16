import json
with open('f:/workbuddy/TrollVNC/job.json', encoding='utf-8') as f:
    d = json.load(f)
for s in d['steps']:
    print(f"{s['number']:2d}. {s['name']:50s} {s.get('status',''):15s} {s.get('conclusion',''):15s}")
