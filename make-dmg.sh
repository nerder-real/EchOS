#!/bin/bash
# 把编译好的 EchOS.app 打成可分发的 DMG（含磁盘图标和 Finder 布局）
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/EchOS.app"
VERSION=$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
# 架构标识：universal-x64 = Intel + Apple Silicon 通用二进制。
# 只想打单一架构时传 ARCH=x64 或 ARCH=arm64（需先用 UNIVERSAL=0 ./build.sh 编译）。
ARCH="${ARCH:-universal-x64}"
RWDMG="$ROOT/build/EchOS-mac-$VERSION-$ARCH-rw.dmg"
# 成品 DMG 放项目根目录，方便直接分发/测试；中间临时 rw.dmg 留在 build/。
DMG="$ROOT/EchOS-mac-$VERSION-$ARCH.dmg"
STAGE="/tmp/echos-dmg-stage"
MNT="/tmp/echos-dmg-mnt"
# 卷名带版本号：Finder 按卷名缓存窗口状态，同名卷会沿用上次打开的布局。
# 带上版本号后每个版本都是"新卷"，首次打开必然读 DMG 内嵌的 .DS_Store（竖版布局）。
VOLNAME="EchOS $VERSION"

[ -d "$APP" ] || { echo "找不到 $APP，先运行 ./build.sh"; exit 1; }

rm -rf "$STAGE" "$MNT" "$RWDMG" "$DMG"
mkdir -p "$STAGE" "$MNT"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 预置 Finder 布局：assets/dmg-layout.DS_Store 是竖版布局（EchOS.app 上、Applications 下）。
# CI 没有 GUI 会话，AppleScript 配不了布局，所以这里直接烧一个成品 .DS_Store 进 DMG，
# 用户首次打开就是上下的，不依赖 Finder。
if [ -f "$ROOT/assets/dmg-layout.DS_Store" ]; then
  cp "$ROOT/assets/dmg-layout.DS_Store" "$STAGE/.DS_Store"
fi

# 磁盘图标（从 SVG 生成满铺版，无透明圆角）
if [ -f "$ROOT/assets/icon.svg" ]; then
  VOLICON_SVG="/tmp/echos-volicon.svg"
  sed 's/rx="[0-9]*" //' "$ROOT/assets/icon.svg" > "$VOLICON_SVG"
  qlmanage -t -s 1024 -o /tmp "$VOLICON_SVG" >/dev/null 2>&1
  VOLICON_PNG="/tmp/volicon.svg.png"
  if [ -f "$VOLICON_PNG" ]; then
    mkdir -p /tmp/echos-volicon.iconset
    cp "$VOLICON_PNG" /tmp/echos-volicon.iconset/icon_512x512@2x.png
    for sz in 512 256 128 64 32 16; do
      sips -z $sz $sz "$VOLICON_PNG" --out "/tmp/echos-volicon.iconset/icon_${sz}x${sz}.png" >/dev/null 2>&1
    done
    sips -z 256 256 "$VOLICON_PNG" --out /tmp/echos-volicon.iconset/icon_256x256@2x.png >/dev/null 2>&1
    sips -z 128 128 "$VOLICON_PNG" --out /tmp/echos-volicon.iconset/icon_128x128@2x.png >/dev/null 2>&1
    sips -z 32 32 "$VOLICON_PNG" --out /tmp/echos-volicon.iconset/icon_16x16@2x.png >/dev/null 2>&1
    iconutil -c icns /tmp/echos-volicon.iconset -o /tmp/echos-VolumeIcon.icns 2>/dev/null
    if [ -f /tmp/echos-VolumeIcon.icns ]; then
      cp /tmp/echos-VolumeIcon.icns "$STAGE/.VolumeIcon.icns"
    fi
  fi
fi

# 1) 创建读写 DMG
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW "$RWDMG" >/dev/null

# 2) 挂载到固定路径（避免 AppleScript 找不到卷宗名）
hdiutil attach "$RWDMG" -mountpoint "$MNT" >/dev/null 2>&1

# 3) 设置磁盘图标标记
SetFile -a C "$MNT" 2>/dev/null || true

# 4) Finder 视图配置
# 背景图在 macOS 26 上无法通过 AppleScript 自动套用，不再生成。
PRIV="/private$MNT"
# CI 环境（GitHub Actions）没有 GUI 会话，Finder 布局配了也白配，直接跳过。
# 本地执行时如果 AppleScript 失败也不阻塞打包 —— 只是少个 Finder 布局而已。
if [ "${FINDER_LAYOUT:-1}" = "1" ]; then
  if osascript <<EOF
tell application "Finder"
  open location "file://$PRIV"
  delay 3
  set win to window 1
  set current view of win to icon view
  set icon size of icon view options of win to 128
  set text size of icon view options of win to 12
  set arrangement of icon view options of win to not arranged
  set bounds of win to {100, 100, 540, 620}
  set position of item "EchOS.app" of win to {220, 78}
  set position of item "Applications" of win to {220, 340}
end tell
EOF
  then
    # 给 Finder 留点时间把布局写进卷里的 .DS_Store，写不完就白配置了
    sleep 3
    sync
  else
    echo "（Finder 布局配置跳过，不影响 DMG 内容）"
  fi
fi

# 5) 弹出
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1

# 6) 转成只读 UDZO
hdiutil convert "$RWDMG" -ov -format UDZO -o "$DMG" >/dev/null
rm -f "$RWDMG"
rm -rf "$STAGE" "$MNT"

SIZE=$(du -h "$DMG" | cut -f1)
echo ""
echo "已生成：$DMG（$SIZE）"
echo ""
echo "提示：这个包没有 Apple 开发者签名，默认会被 Gatekeeper 拦下。"
echo "     对方第一次打开时需要右键点图标选「打开」，或到系统设置 → 隐私与安全性里放行。"
