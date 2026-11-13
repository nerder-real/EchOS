#!/bin/bash
# 本地一键出包：构建 App + 打 DMG。
#
# 授权服务地址（正式包需要）从两个来源取，都不落进仓库任何文件：
#   1. 环境变量 ECH_LICENSE_URL（脚本/终端传入）
#   2. 本机私有配置文件 ~/.echos-build-license（仅一行地址，权限 600，
#      已在 .gitignore 之外且永不入库）
# 两者都没有 → 出「不启用授权」的本地开发包（授权层整体旁路，不拦截）。
#
# 用法：
#   ./build-local.sh                       # 读 ~/.echos-build-license 或出开发包
#   ECH_LICENSE_URL=https://… ./build-local.sh   # 显式传地址
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"

LICENSE_URL="${ECH_LICENSE_URL:-}"
if [ -z "$LICENSE_URL" ] && [ -f "$HOME/.echos-build-license" ]; then
  LICENSE_URL="$(head -1 "$HOME/.echos-build-license" | tr -d '[:space:]')"
fi

if [ -n "$LICENSE_URL" ]; then
  echo "==> 授权服务：已注入（地址不回显）"
  export ECH_LICENSE_URL="$LICENSE_URL"
else
  echo "==> 未配置授权地址：将打出【不启用授权】的本地开发包"
  echo "    （配置方法：echo 地址 > ~/.echos-build-license && chmod 600 该文件）"
fi

"$ROOT/build.sh"
"$ROOT/make-dmg.sh"
