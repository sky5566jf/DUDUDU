#!/usr/bin/env python3
"""
用法: python download_artifact.py <artifact_id> <output_path>
例如: python download_artifact.py 6464615311 C:/lmp/release/public/bootstrap.zip

构建完成后，用 gh api 获取最新 artifact ID:
  gh api repos/sky5566jf/TrollVNC/actions/artifacts
"""

import subprocess, urllib.request, sys, os

def download_artifact(artifact_id, output_path):
    token = subprocess.check_output(["gh", "auth", "token"], text=True).strip()

    url = f"https://api.github.com/repos/sky5566jf/TrollVNC/actions/artifacts/{artifact_id}/zip"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"
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
            print(f"Downloading from Azure Blob...")
            with urllib.request.urlopen(blob_url) as r:
                data = r.read()
            os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
            with open(output_path, "wb") as f:
                f.write(data)
            print(f"Saved {len(data)} bytes to {output_path}")
            return True
        else:
            print(f"Error: {e.code} {e.reason}")
            return False

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    success = download_artifact(sys.argv[1], sys.argv[2])
    sys.exit(0 if success else 1)
