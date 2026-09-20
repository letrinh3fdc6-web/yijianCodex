#!/bin/bash

# 在 GitHub Actions 的真实 Mac 架构上核对远程依赖包及其可执行架构。
set -Eeuo pipefail
IFS=$'\n\t'

readonly DOWNLOAD_BASE_URL="${ANYU_DOWNLOAD_BASE_URL:-https://x.ailzd.com/downloads}"
readonly ARCHITECTURE="$(/usr/bin/uname -m)"
TEMP_DIRECTORY="$(/usr/bin/mktemp -d "${RUNNER_TEMP:-/tmp}/anyu-codex-deps.XXXXXX")"
MOUNT_POINT=""

cleanup() {
  [[ -z "$MOUNT_POINT" ]] || /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  /bin/rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

/usr/bin/curl --fail --location --silent --show-error --retry 3 \
  "${DOWNLOAD_BASE_URL}/SHA256SUMS.txt" --output "$TEMP_DIRECTORY/SHA256SUMS.txt"

verify_dmg_architecture() {
  local filename="$1"
  local required_arch="$2"
  local expected dmg app executable_name executable architectures

  expected="$(/usr/bin/awk -v filename="$filename" '$2 == filename { print $1; exit }' "$TEMP_DIRECTORY/SHA256SUMS.txt")"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || {
    printf '缺少 %s 的远程校验值。\n' "$filename" >&2
    exit 1
  }

  dmg="$TEMP_DIRECTORY/$filename"
  /usr/bin/curl --fail --location --silent --show-error --retry 3 \
    "${DOWNLOAD_BASE_URL}/${filename}" --output "$dmg"
  printf '%s  %s\n' "$expected" "$dmg" | /usr/bin/shasum -a 256 -c -

  MOUNT_POINT="$(/usr/bin/mktemp -d "$TEMP_DIRECTORY/mount.XXXXXX")"
  /usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet
  app="$(/usr/bin/find "$MOUNT_POINT" -type d -name '*.app' -print | /usr/bin/head -n 1)"
  [[ -n "$app" ]] || {
    printf '%s 中没有应用包。\n' "$filename" >&2
    exit 1
  }
  executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
  executable="$app/Contents/MacOS/$executable_name"
  [[ -f "$executable" ]] || {
    printf '%s 中没有主程序。\n' "$filename" >&2
    exit 1
  }
  architectures="$(/usr/bin/lipo -archs "$executable")"
  printf '%s: %s\n' "$filename" "$architectures"
  [[ " $architectures " == *" $required_arch "* ]] || {
    printf '%s 不支持当前要求的架构 %s。\n' "$filename" "$required_arch" >&2
    exit 1
  }
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
  /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
  /bin/rmdir "$MOUNT_POINT"
  MOUNT_POINT=""
}

case "$ARCHITECTURE" in
  arm64|aarch64)
    verify_dmg_architecture 'CC-Switch-v3.18.0-macOS.dmg' 'arm64'
    verify_dmg_architecture 'CodexPlusPlus-1.2.43-macos-arm64.dmg' 'arm64'
    ;;
  x86_64)
    verify_dmg_architecture 'CC-Switch-v3.18.0-macOS.dmg' 'x86_64'
    ;;
  *)
    printf '不支持的验证架构：%s\n' "$ARCHITECTURE" >&2
    exit 1
    ;;
esac

printf '远程 macOS 依赖检查通过：%s。\n' "$ARCHITECTURE"
