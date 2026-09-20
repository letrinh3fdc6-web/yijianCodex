#!/bin/bash

# 在 macOS 上生成 Finder 可直接打开的应用和通用 DMG。
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.0.0"
OUTPUT_NAME="Anyu-One-Click-Codex-macOS-universal"
CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=1
      ;;
    --version)
      VERSION=${2:?缺少版本号}
      shift
      ;;
    --output-name)
      OUTPUT_NAME=${2:?缺少输出名称}
      shift
      ;;
    *)
      printf '未知参数：%s\n' "$1" >&2
      exit 64
      ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]] || {
  printf '版本号格式无效：%s\n' "$VERSION" >&2
  exit 64
}

[[ "$(/usr/bin/uname -s)" == "Darwin" ]] || {
  printf '%s\n' '必须在 macOS 上构建 DMG。' >&2
  exit 1
}

for command in codesign ditto hdiutil plutil; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '系统缺少必要命令：%s\n' "$command" >&2
    exit 1
  }
done

SCRIPT_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIRECTORY=$(cd "$SCRIPT_DIRECTORY/.." && pwd)
SOURCE_INSTALLER="$SCRIPT_DIRECTORY/install.command"
BUILD_DIRECTORY="$PROJECT_DIRECTORY/build"
DIST_DIRECTORY="$PROJECT_DIRECTORY/dist"
DMG_STAGE="$BUILD_DIRECTORY/dmg-stage"
APP_NAME="Anyu AI One-Click Codex"
APP_PATH="$DIST_DIRECTORY/$APP_NAME.app"
DMG_PATH="$DIST_DIRECTORY/$OUTPUT_NAME.dmg"

[[ -f "$SOURCE_INSTALLER" ]] || {
  printf '找不到安装器源码：%s\n' "$SOURCE_INSTALLER" >&2
  exit 1
}

if [[ $CLEAN -eq 1 ]]; then
  /bin/rm -rf "$BUILD_DIRECTORY" "$DIST_DIRECTORY"
fi

/bin/rm -rf "$APP_PATH" "$DMG_PATH" "$DMG_STAGE"
/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$DIST_DIRECTORY" "$DMG_STAGE"

/bin/cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Anyu AI One-Click Codex</string>
  <key>CFBundleExecutable</key>
  <string>AnyuAIOneClickCodex</string>
  <key>CFBundleIdentifier</key>
  <string>ai.anyu.oneclickcodex</string>
  <key>CFBundleName</key>
  <string>Anyu AI One-Click Codex</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION%%[-.][A-Za-z]*}</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

/bin/cat > "$APP_PATH/Contents/MacOS/AnyuAIOneClickCodex" <<'LAUNCHER'
#!/bin/bash

set -Eeuo pipefail

APP_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALLER="$APP_ROOT/Contents/Resources/install.command"

if [[ ! -x "$INSTALLER" ]]; then
  /usr/bin/osascript -e 'display dialog "找不到安装器文件，请重新下载。" buttons {"确定"} default button "确定" with icon stop'
  exit 1
fi

exec /usr/bin/open -a Terminal "$INSTALLER"
LAUNCHER

/usr/bin/ditto "$SOURCE_INSTALLER" "$APP_PATH/Contents/Resources/install.command"
/bin/chmod 0755 "$APP_PATH/Contents/MacOS/AnyuAIOneClickCodex" "$APP_PATH/Contents/Resources/install.command"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

# 使用临时签名保持应用包结构完整；正式公证可在以后接入开发者证书。
/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

/usr/bin/ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_STAGE/Applications"
/bin/cat > "$DMG_STAGE/使用说明.txt" <<'README'
安域一键配置 Codex

1. 将 Anyu AI One-Click Codex.app 拖入“应用程序”。
2. 双击应用，终端会询问网关、模型和 API Key。
3. 跟随提示直到显示“全部完成”。

如果 macOS 阻止首次打开，请执行：
xattr -cr "/Applications/Anyu AI One-Click Codex.app"
README

/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG_PATH"

MOUNT_POINT=$(/usr/bin/mktemp -d "$BUILD_DIRECTORY/mount.XXXXXX")
cleanup() {
  /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  /bin/rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_POINT" -quiet
[[ -d "$MOUNT_POINT/$APP_NAME.app" ]] || {
  printf '生成的 DMG 中缺少应用。\n' >&2
  exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$APP_NAME.app"
/usr/bin/shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

printf '已生成 macOS 通用安装器：%s\n' "$DMG_PATH"
