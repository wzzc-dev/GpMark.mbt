#!/usr/bin/env bash
# 构建 md_mbt demo：
# 1) 通过 third_party/gpui-moonbit 的构建驱动确保 Rust staticlib（gpui-sys）就绪；
# 2) moon build --target native 生成 main.exe（link 子包会把静态库参数带进来）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
GPUI="$ROOT/third_party/gpui-moonbit"
STATICLIB="$GPUI/gpui-sys/target/aarch64-apple-darwin/debug/libgpui_sys.a"

if [ ! -f "$STATICLIB" ]; then
  echo "[build] gpui-sys staticlib 缺失，调用上游构建驱动…"
  (cd "$GPUI" && ./build.sh --no-run) || (cd "$GPUI" && cargo build -p gpui-sys)
fi

echo "[build] moon build (native)…"
cd "$ROOT"
moon build --target native
echo "[build] OK: $ROOT/_build/native/debug/build/mdmbt/main/main.exe"
