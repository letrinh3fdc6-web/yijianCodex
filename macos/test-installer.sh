#!/bin/bash

# 对安装脚本和构建脚本执行不修改系统的静态回归检查。
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALLER="$SCRIPT_DIRECTORY/install.command"
BUILDER="$SCRIPT_DIRECTORY/build-dmg.sh"

/bin/bash -n "$INSTALLER"
/bin/bash -n "$BUILDER"

require_text() {
  local file="$1"
  local text="$2"
  /usr/bin/grep -Fq "$text" "$file" || {
    printf '缺少必要配置：%s\n' "$text" >&2
    exit 1
  }
}

require_text "$INSTALLER" 'codex login --with-api-key'
require_text "$INSTALLER" 'sandbox_mode = "danger-full-access"'
require_text "$INSTALLER" 'approval_policy = "never"'
require_text "$INSTALLER" 'ccswitch://v1/import'
require_text "$INSTALLER" 'CC-Switch-v3.18.0-macOS.dmg'
require_text "$INSTALLER" 'CodexPlusPlus-1.2.43-macos-arm64.dmg'
require_text "$INSTALLER" '当前为 Intel Mac'
require_text "$INSTALLER" 'shasum -a 256'
require_text "$BUILDER" 'LSMinimumSystemVersion'
require_text "$BUILDER" 'codesign --verify --deep --strict'

if /usr/bin/grep -Eq 'curl.*ANYU_API_KEY|ANYU_API_KEY=.*curl' "$INSTALLER"; then
  printf '检测到 API Key 可能进入下载请求。\n' >&2
  exit 1
fi

printf '安装器静态检查通过。\n'
