#!/usr/bin/env bash
# 干净版：下载 v3.88 run 29336000295 的 4 个 package artifact，重命名并同步 E:\lmp\ipa 与 build_output/
# 方法：curl -sI 取 303 Location(blob 签名 URL) -> curl -sL 直连 blob(无 auth)
set -u
TOKEN=$(grep -o 'ghp_[A-Za-z0-9]*' "$HOME/.git-credentials" | head -1)
REPO="sky5566jf/DUDUDU"
WS="F:/workbuddy/MatisuXCS苹果版"
DL="$WS/build_output/_dl"
mkdir -p "$DL"
API="https://api.github.com/repos/$REPO"

# 固定顺序：id | 目标文件名
ITEMS=(
  "8312016609|MatisuXCS_3.88.tipa"
  "8311995730|MatisuXCS_3.88_iphoneos-arm.deb"
  "8312006530|MatisuXCS_3.88_iphoneos-arm64.deb"
  "8311982245|MatisuXCS_3.88_iphoneos-arm64e.deb"
)

for item in "${ITEMS[@]}"; do
  id="${item%%|*}"; target="${item##*|}"
  zip="$DL/$id.zip"; ext="$DL/$id"; rm -rf "$ext"; mkdir -p "$ext"
  url="$API/actions/artifacts/$id/zip"
  echo "== [$id] -> $target =="
  loc=$(curl -sI --connect-timeout 15 --max-time 60 -H "Authorization: Bearer $TOKEN" "$url" | grep -i '^location:' | tr -d '\r' | awk '{print $2}')
  if [ -z "$loc" ]; then echo "  !! 取不到 location"; continue; fi
  curl -sL --connect-timeout 15 --max-time 180 "$loc" -o "$zip" -w "  dl HTTP %{http_code} size=%{size_download}\n"
  if [ ! -s "$zip" ] || [ "$(stat -c%s "$zip")" -lt 100000 ]; then echo "  !! 下载过小/空，跳过"; continue; fi
  unzip -o -q "$zip" -d "$ext" || { echo "  !! 解压失败"; continue; }
  inner=$(find "$ext" -type f \( -name '*.tipa' -o -name '*.deb' \) | head -1)
  if [ -z "$inner" ]; then echo "  !! 压缩包内无 .tipa/.deb"; continue; fi
  dest="$WS/build_output/$target"
  cp -f "$inner" "$dest"
  mkdir -p /e/lmp/ipa
  cp -f "$dest" /e/lmp/ipa/"$target"
  echo "  ok -> $(stat -c%s "$dest") bytes  [$(basename "$inner")]"
done

echo; echo "===== 校验：E: 盘 ====="
ls -la /e/lmp/ipa/MatisuXCS_3.88.*
echo; echo "===== 校验：build_output ====="
ls -la "$WS/build_output/"MatisuXCS_3.88.*
