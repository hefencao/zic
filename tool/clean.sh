#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/apps/app"

remove_path() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    printf 'REMOVE %s\n' "${path#"$ROOT/"}"
    rm -rf -- "$path"
  fi
}

printf 'Cleaning project build caches under %s\n' "$ROOT"

# Let Flutter remove platform-specific intermediates when available. The
# explicit removals below make the script useful before Flutter is installed
# and cover workspace packages that `flutter clean` does not visit.
if command -v flutter >/dev/null 2>&1 && [[ -f "$APP/pubspec.yaml" ]]; then
  (
    cd "$APP"
    flutter clean
  )
fi

while IFS= read -r -d '' path; do
  remove_path "$path"
done < <(
  find "$ROOT" -type d \
    \( -name .dart_tool -o -name build -o -name .gradle -o -name coverage \
       -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache \
       -o -name .ruff_cache \) \
    -prune -print0
)

remove_path "$ROOT/target"
remove_path "$ROOT/.deps/build"
remove_path "$ROOT/.deps/install"
remove_path "$ROOT/apps/app/android/app/src/main/jniLibs"
remove_path "$ROOT/apps/app/android/app/src/main/assets/third_party/libwebp"
remove_path "$ROOT/apps/app/ios/Pods"
remove_path "$ROOT/apps/app/ios/.symlinks"
remove_path "$ROOT/apps/app/macos/Pods"
remove_path "$ROOT/apps/app/macos/.symlinks"
remove_path "$ROOT/apps/app/.flutter-plugins"
remove_path "$ROOT/apps/app/.flutter-plugins-dependencies"

# Generated dependency metadata is a cache; lock files are deliberately kept.
find "$ROOT" -type f \
  \( -name .packages -o -name '*.dill' -o -name '*.snapshot' -o -name '*.pyc' \) \
  -print0 | while IFS= read -r -d '' path; do
    remove_path "$path"
  done

printf '%s\n' 'Project build caches removed.'
printf '%s\n' 'Next clean build:'
printf '%s\n' '  flutter pub get'
printf '%s\n' '  ./tool/build_android.sh debug'
