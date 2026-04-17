import urllib.request, json, subprocess

token = subprocess.check_output('gh auth token', shell=True, text=True).strip()
run_id = '24551446158'
req = urllib.request.Request(
    'https://api.github.com/repos/sky5566jf/TrollVNC/actions/runs/' + run_id + '/jobs',
    headers={'Authorization': 'token ' + token, 'Accept': 'application/vnd.github.v3+json'}
)
with urllib.request.urlopen(req) as r:
    d = json.loads(r.read())
    for job in d.get('jobs', []):
        print(job['name'], '|', job.get('conclusion') or job.get('status'))
        if job.get('conclusion') == 'failure':
            for step in job.get('steps', []):
                print(f"  {step['number']:2d}. {step['name']:50s} {step.get('conclusion') or step.get('status')}")
            # Get job ID for log download
            if 'default' in job['name']:
                print('Default job ID:', job['id'])
