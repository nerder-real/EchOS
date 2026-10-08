#!/bin/bash
# 一键编译 ECH for Mac：Go 内核 + SwiftUI 界面 → ECH.app
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/build"
APP="$OUT/EchOS.app"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# 通用二进制（Intel + Apple 芯片都能跑），设 UNIVERSAL=0 只编译当前架构
UNIVERSAL="${UNIVERSAL:-1}"
MIN_MACOS="13.0"

# rm -rf "$OUT"
# Cleanup previous build output - commented out to avoid permission issues
mkdir -p "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# If we need to clean, we should ensure we have write permissions first
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 1/3 编译 Go 内核 x-tunnel"
cd "$ROOT/core"
if [ "$UNIVERSAL" = "1" ]; then
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o "$OUT/x-tunnel-amd64" .
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o "$OUT/x-tunnel-arm64" .
  lipo -create -output "$APP/Contents/Resources/x-tunnel" "$OUT/x-tunnel-amd64" "$OUT/x-tunnel-arm64"
  rm -f "$OUT/x-tunnel-amd64" "$OUT/x-tunnel-arm64"
else
  # go build 拒绝覆盖已存在的输出文件（上次构建留下的 fat binary 不被识别为
  # object 文件，会报 "already exists and is not an object file" 中断整次构建）。
  rm -f "$APP/Contents/Resources/x-tunnel"
  CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$APP/Contents/Resources/x-tunnel" .
fi
chmod +x "$APP/Contents/Resources/x-tunnel"

echo "==> 2/3 编译 SwiftUI 界面"
cd "$ROOT/gui"
SRC=(Sources/*.swift)
SDK="$(xcrun --show-sdk-path)"
if [ "$UNIVERSAL" = "1" ]; then
  swiftc -O -sdk "$SDK" -target x86_64-apple-macos$MIN_MACOS \
      -parse-as-library -o "$OUT/gui-x86_64" "${SRC[@]}"
  swiftc -O -sdk "$SDK" -target arm64-apple-macos$MIN_MACOS \
      -parse-as-library -o "$OUT/gui-arm64" "${SRC[@]}"
  lipo -create -output "$APP/Contents/MacOS/EchOS" "$OUT/gui-x86_64" "$OUT/gui-arm64"
  rm -f "$OUT/gui-x86_64" "$OUT/gui-arm64"
else
  ARCH="$(uname -m)"
  swiftc -O -sdk "$SDK" -target $ARCH-apple-macos$MIN_MACOS \
      -parse-as-library -o "$APP/Contents/MacOS/EchOS" "${SRC[@]}"
fi
chmod +x "$APP/Contents/MacOS/EchOS"

echo "==> 3/3 组装 App"
cp "$ROOT/gui/Info.plist" "$APP/Contents/Info.plist"
# 更新源仓库（owner/repo）：不写死在源码里。默认从当前 git remote 自动获取，
# 因此 fork 后打包会自动指向 fork 自己的仓库，无需改任何代码；
# 也可用环境变量 ECH_UPDATE_REPO 手动覆盖（CI 里由 ${{ github.repository }} 传入）。
# 拿不到仓库地址时不注入该键，界面上的「检查更新」会提示未配置，不暴露地址。
if [ -z "${ECH_UPDATE_REPO:-}" ]; then
  _remote=""
  _remote=$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null) || true
  case "$_remote" in
    git@github.com:*|ssh://git@github.com/*)
      ECH_UPDATE_REPO=$(echo "$_remote" | sed -E 's#.*github\.com[/:]##; s#\.git$##')
      ;;
    https://github.com/*)
      ECH_UPDATE_REPO=$(echo "$_remote" | sed -E 's#https://github\.com/##; s#\.git$##')
      ;;
  esac
fi
if [ -n "${ECH_UPDATE_REPO:-}" ]; then
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :EchOSUpdateRepo" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :EchOSUpdateRepo string '$ECH_UPDATE_REPO'" "$PLIST"
  echo "    更新源已注入：$ECH_UPDATE_REPO"
fi
# 分流数据（跳过中国大陆模式要用）
for d in geoip geosite; do
  if [ -f "$ROOT/assets/$d.dat" ]; then
    cp "$ROOT/assets/$d.dat" "$APP/Contents/Resources/$d.dat"
  else
    echo "    ⚠️  缺少 assets/$d.dat，分流模式将无法工作"
  fi
done
if [ -f "$ROOT/gui/AppIcon.icns" ]; then
  cp "$ROOT/gui/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# 本地临时签名：不签名的话 macOS 会直接拒绝运行
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    （签名跳过，不影响本机使用）"

echo ""
echo "完成：$APP"
lipo -info "$APP/Contents/MacOS/EchOS" 2>/dev/null || true
lipo -info "$APP/Contents/Resources/x-tunnel" 2>/dev/null || true
