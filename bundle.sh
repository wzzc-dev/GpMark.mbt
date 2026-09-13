#!/usr/bin/env bash
# 把 main.exe 包进最小 macOS .app（产品名 GpMark）。裸 Mach-O 不配作为前台
# GUI 应用，macOS 不会向它投递键盘事件（GPUI 收不到键入）；带 Info.plist 的
# bundle 可修复。直接运行 Contents/MacOS/GpMark 同样继承 bundle 身份且保留
# 终端 stdout/stderr，便于调试。
#
# 产品名与内部包名有意分开：`mdmbt/*` 是 workspace 里的模块 id（core /
# adapter / main / selftest），改名会牵动所有 import 与 CI 产物路径，而用户
# 看到的只有 bundle 名、窗口标题和发行包名——那些统一叫 GpMark。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PRODUCT="GpMark"
EXE="$ROOT/_build/native/debug/build/mdmbt/main/main.exe"
APP="$ROOT/dist/$PRODUCT.app"

if [ ! -f "$EXE" ]; then
  echo "未找到可执行文件 — 先运行 ./build.sh" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$EXE" "$APP/Contents/MacOS/$PRODUCT"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$PRODUCT</string>
  <key>CFBundleDisplayName</key><string>GpMark — GPUI Markdown WYSIWYG (MoonBit)</string>
  <key>CFBundleIdentifier</key><string>dev.local.gpmark.editor</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>$PRODUCT</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

echo "打包完成: $APP"
echo "GUI 启动:   open '$APP'"
echo "带终端输出: '$APP/Contents/MacOS/$PRODUCT'"
