#!/usr/bin/env bash
# 把 main.exe 包进最小 macOS .app。裸 Mach-O 不配作为前台 GUI 应用，
# macOS 不会向它投递键盘事件（GPUI 收不到键入）；带 Info.plist 的 bundle 可修复。
# 直接运行 Contents/MacOS/Runner 同样继承 bundle 身份且保留终端 stdout/stderr，
# 便于调试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
EXE="$ROOT/_build/native/debug/build/main/main.exe"
APP="$ROOT/dist/MdMbt.app"

if [ ! -f "$EXE" ]; then
  echo "未找到可执行文件 — 先运行 ./build.sh" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$EXE" "$APP/Contents/MacOS/MdMbt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MdMbt</string>
  <key>CFBundleDisplayName</key><string>md_mbt — GPUI Markdown WYSIWYG (MoonBit)</string>
  <key>CFBundleIdentifier</key><string>dev.local.md-mbt.editor</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>MdMbt</string>
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
echo "带终端输出: '$APP/Contents/MacOS/MdMbt'"
