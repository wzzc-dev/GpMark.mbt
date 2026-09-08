#!/usr/bin/env bash
# 构建 md_mbt demo：
# moon build --target native 时，third_party/gpui-moonbit 的 link 子包 prebuild
# 钩子（moonbit-bindings/build.py）会先用 cargo 构建 gpui-sys staticlib 并注入
# 链接参数，无需在脚本里手动预热（冷缓存 CI 同样成立）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "[build] moon build (native)…"
cd "$ROOT"
moon build --target native
echo "[build] OK: $ROOT/_build/native/debug/build/mdmbt/main/main.exe"
