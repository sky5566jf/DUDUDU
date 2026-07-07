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
            # 检查是否是嵌套 zip（artifact 可能包了两层）
            import io, zipfile
            data_io = io.BytesIO(data)
            try:
                with zipfile.ZipFile(data_io) as zf:
                    names = zf.namelist()
                    # 如果 zip 里只有一个文件且以 .tipa/.zip 结尾，需要解包
                    if len(names) == 1 and (names[0].endswith('.tipa') or names[0].endswith('.zip')):
                        inner_data = zf.read(names[0])
                        inner_io = io.BytesIO(inner_data)
                        try:
                            with zipfile.ZipFile(inner_io) as zf2:
                                # 内层是正常 zip（含 Payload/）→ 这才是真正的 tipa
                                os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
                                with open(output_path, "wb") as f:
                                    f.write(inner_data)
                                print(f"Extracted inner archive: {len(inner_data)} bytes to {output_path}")
                                return True
                        except zipfile.BadZipFile:
                            os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
                            with open(output_path, "wb") as f:
                                f.write(inner_data)
                            print(f"Saved (inner non-zip): {len(inner_data)} bytes to {output_path}")
                            return True
                    else:
                        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
                        with open(output_path, "wb") as f:
                            f.write(data)
                        print(f"Saved {len(data)} bytes to {output_path}")
                        return True
            except zipfile.BadZipFile:
                os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
                with open(output_path, "wb") as f:
                    f.write(data)
                print(f"Saved {len(data)} bytes to {output_path}")
                return True
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
