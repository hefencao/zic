#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_TOOLCHAINS=0
if [[ "${1:-}" == "--require-toolchains" ]]; then
  REQUIRE_TOOLCHAINS=1
fi

python3 "$ROOT/tool/check_repo.py"

if command -v flutter >/dev/null 2>&1; then
  (cd "$ROOT" && flutter pub get)
  (cd "$ROOT" && dart format apps packages)
  (cd "$ROOT" && flutter analyze)
  for package_dir in \
    "$ROOT/packages/domain" \
    "$ROOT/packages/library" \
    "$ROOT/packages/telemetry" \
    "$ROOT/packages/transport" \
    "$ROOT/packages/storage" \
    "$ROOT/packages/testkit" \
    "$ROOT/packages/pipeline" \
    "$ROOT/packages/sessions" \
    "$ROOT/packages/bridge"; do
    echo "DART TEST: ${package_dir#$ROOT/}"
    (cd "$package_dir" && dart test)
  done
  for package_dir in \
    "$ROOT/packages/reader" \
    "$ROOT/apps/app"; do
    echo "FLUTTER TEST: ${package_dir#$ROOT/}"
    (cd "$package_dir" && flutter test)
  done
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
