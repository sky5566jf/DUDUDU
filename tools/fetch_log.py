import urllib.request, re, os, sys

tok = re.search(r'ghp_[A-Za-z0-9]+', open(os.path.expanduser('~/.git-credentials')).read()).group(0)
JOB = sys.argv[1] if len(sys.argv) > 1 else "87092054617"
url = f"https://api.github.com/repos/sky5566jf/DUDUDU/actions/jobs/{JOB}/logs"

class NoRedir(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

req = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + tok, 'Accept': 'application/vnd.github+json'})
opener = urllib.request.build_opener(NoRedir)
try:
    resp = opener.open(req)
    data = resp.read()
except urllib.error.HTTPError as e:
    if e.code in (301, 302, 303, 307, 308):
        loc = e.headers.get('Location')
        data = urllib.request.urlopen(loc).read()
    else:
        raise

text = data.decode('utf-8', 'replace')
open('v388_job.log', 'w', encoding='utf-8').write(text)
lines = text.splitlines()
print(f"=== LOG lines: {len(lines)} ===")
print("=== ERROR/FAIL lines ===")
for ln in lines:
    low = ln.lower()
    if ('error' in low or 'undefined' in low or 'redefinition' in low or 'expected' in low
            or 'not found' in low or 'no such' in low or 'fail' in low) \
            and 'warning' not in low and 'note:' not in low:
        print(ln)
print("=== TAIL (last 50) ===")
for ln in lines[-50:]:
    print(ln)
