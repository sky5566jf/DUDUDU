#!/bin/bash
set -e
REPO=sky5566jf/DUDUDU
RUN=29335040833
PY=/c/Users/Administrator/.workbuddy/binaries/python/versions/3.13.12/python.exe
TOKEN=$(grep -o 'ghp_[A-Za-z0-9]*' "$HOME/.git-credentials" | head -1)
API=https://api.github.com/repos/$REPO/actions/runs/$RUN

echo ">>> 轮询 run $RUN 直到 completed (最多 ~9 分钟)..."
STATUS=""
CONCL=""
for i in $(seq 1 27); do
  RESP=$(curl -s -H "Authorization: Bearer $TOKEN" "$API")
  STATUS=$(echo "$RESP" | "$PY" -c "import sys,json;print(json.load(sys.stdin).get('status'))")
  CONCL=$(echo "$RESP"  | "$PY" -c "import sys,json;print(json.load(sys.stdin).get('conclusion'))")
  echo "  [$i] status=$STATUS conclusion=$CONCL"
  if [ "$STATUS" = "completed" ]; then break; fi
  sleep 20
done

if [ "$STATUS" != "completed" ]; then echo "!!! 超时未完成 (status=$STATUS)"; exit 2; fi
if [ "$CONCL" != "success" ]; then echo "!!! 构建失败 conclusion=$CONCL"; exit 3; fi
echo ">>> 构建成功，开始下载产物"

TMP=/tmp/v388_sync
rm -rf "$TMP"; mkdir -p "$TMP"
DEST=/e/lmp/ipa
mkdir -p "$DEST" "$DEST/build_output"

# 取 artifacts id+name（用 python 走 API，规避 curl 跟随重定向带鉴权到 S3 的 401）
ARTS=$("$PY" -c "
import json,urllib.request,re,os
tok=open(os.path.expanduser('~/.git-credentials')).read()
tok=re.search(r'ghp_[A-Za-z0-9]+',tok).group(0)
req=urllib.request.Request('$API/artifacts', headers={'Authorization':'Bearer '+tok})
d=json.load(urllib.request.urlopen(req))
for a in d['artifacts']:
    print(a['id'], a['name'])
")

echo "$ARTS" | while read -r AID NAME; do
  case "$NAME" in
    packages-bootstrap) TGT=MatisuXCS_3.88.tipa ;;
    packages-default)   TGT=MatisuXCS_3.88_default.deb ;;
    packages-rootless)  TGT=MatisuXCS_3.88_rootless.deb ;;
    packages-roothide)  TGT=MatisuXCS_3.88_roothide.deb ;;
    *) continue ;;
  esac
  echo ">>> 下载 $NAME -> $TGT (artifact $AID)"
  curl -sL -H "Authorization: Bearer $TOKEN" "$API/artifacts/$AID/zip" -o "$TMP/$NAME.zip"
  rm -rf "$TMP/$NAME"; mkdir -p "$TMP/$NAME"
  unzip -o -q "$TMP/$NAME.zip" -d "$TMP/$NAME"
  PKG=$(find "$TMP/$NAME" -type f \( -name '*.tipa' -o -name '*.deb' \) | head -1)
  if [ -z "$PKG" ]; then echo "  !! $NAME 内未找到 .tipa/.deb"; continue; fi
  cp "$PKG" "$DEST/$TGT"
  cp "$PKG" "$DEST/build_output/$TGT"
  echo "  OK -> $DEST/$TGT ($(stat -c%s "$PKG") bytes)"
done

echo ">>> 完成，产物列表:"
ls -la "$DEST"/MatisuXCS_3.88.*
