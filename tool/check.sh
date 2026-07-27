#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_TOOLCHAINS=0
if [[ "${1:-}" == "--require-toolchains" ]]; then
  REQUIRE_TOOLCHAINS=1
fi

python3 "$ROOT/tool/check_repo.py"
"$ROOT/tool/check_native_header.sh"
if command -v pkg-config >/dev/null 2>&1 && \
   pkg-config --exists libwebp libwebpdemux; then
  "$ROOT/tool/check_webp.sh"
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "libwebp development files are required" >&2
  exit 1
else
  echo "SKIP: libwebp development files are not installed"
fi

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT" && flutter pub get)
  (cd "$ROOT" && dart format apps packages)
  "$ROOT/tool/analyze.sh"
  "$ROOT/tool/test_dart.sh"
  "$ROOT/tool/test_flutter.sh"
  "$ROOT/tool/build_android.sh" debug
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "Flutter SDK is required" >&2
  exit 1
else
  echo "SKIP: Flutter SDK is not installed"
fi

if command -v cargo >/dev/null 2>&1; then
  (cd "$ROOT" && cargo fmt --all -- --check)
  (cd "$ROOT" && cargo test --workspace)
elif [[ "$REQUIRE_TOOLCHAINS" -eq 1 ]]; then
  echo "Rust toolchain is required" >&2
  exit 1
else
  echo "SKIP: Rust toolchain is not installed"
fi
