#!/bin/bash
# 下载分流规则数据 geoip.dat / geosite.dat（v2ray 格式，来自 Loyalsoldier/v2ray-rules-dat）。
#
# 这两个文件是上游开源二进制，体积大、更新频繁，不进 git 仓库。
# 本地构建前跑一次；GitHub Actions 发版时由 release.yml 自动调用。
#
# 用法：
#   ./fetch-geodata.sh            # 下载到 assets/
#   GEO_SOURCE=https://... ./fetch-geodata.sh   # 自定义下载源
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIR="$ROOT/assets"
mkdir -p "$DIR"

BASE="${GEO_SOURCE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"

for f in geoip.dat geosite.dat; do
  # 本地已存在且非空则跳过（避免每次都全量下载；想强制更新就删掉文件再跑）
  if [ -s "$DIR/$f" ]; then
    echo "==> $f 已存在，跳过（如需强制更新请删除 $DIR/$f 后重跑）"
    continue
  fi
  echo "==> 下载 $f"
  curl -fL --retry 3 -o "$DIR/$f.tmp" "$BASE/$f"
  if [ ! -s "$DIR/$f.tmp" ]; then
    echo "✗ $f 下载失败或为空" >&2
    rm -f "$DIR/$f.tmp"
    exit 1
  fi
  mv "$DIR/$f.tmp" "$DIR/$f"
  ls -la "$DIR/$f"
done

echo "完成：分流数据就绪。"
