#!/bin/bash

# 安域一键 Codex macOS 安装器：所有密钥只在本机登录和配置流程中处理。
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP_NAME="安域一键配置 Codex"
readonly DOWNLOAD_BASE_URL="${ANYU_DOWNLOAD_BASE_URL:-https://x.ailzd.com/downloads}"
readonly DEFAULT_GATEWAY="${ANYU_GATEWAY:-https://x.ailzd.com}"
readonly DEFAULT_MODEL="${ANYU_MODEL:-gpt-5.4}"
readonly NPM_REGISTRY="https://registry.npmmirror.com"
readonly NODE_VERSION="22.18.0"
readonly NODE_PACKAGE="node-v${NODE_VERSION}.pkg"
readonly NODE_DIST_URL="https://nodejs.org/dist/v${NODE_VERSION}"
readonly CACHE_DIRECTORY="${HOME}/Library/Caches/Anyu-One-Click-Codex"
readonly CODEX_PLUS_SETTINGS="${HOME}/.codex-session-delete/settings.json"

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

MOUNT_POINTS=()
API_KEY=""
GATEWAY=""
MODEL=""

log() {
  printf '[%s] %s\n' "$APP_NAME" "$*" >&2
}

fail() {
  printf '[%s] 错误：%s\n' "$APP_NAME" "$*" >&2
  exit 1
}

cleanup() {
  local mount_point
  for mount_point in "${MOUNT_POINTS[@]}"; do
    /usr/bin/hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
    /bin/rmdir "$mount_point" >/dev/null 2>&1 || true
  done
  API_KEY=""
  unset ANYU_API_KEY
}

finish() {
  local status=$?
  trap - EXIT
  cleanup
  if [[ -t 0 ]]; then
    if [[ $status -eq 0 ]]; then
      printf '\n配置完成。按回车键关闭窗口。'
    else
      printf '\n配置未完成，请保留上方错误信息。按回车键关闭窗口。'
    fi
    read -r _ || true
  fi
  exit "$status"
}
trap finish EXIT

require_macos() {
  [[ "$(/usr/bin/uname -s)" == "Darwin" ]] || fail "此安装器只能在 macOS 上运行。"

  local major_version architecture command
  major_version="$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')"
  [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 12 )) || fail "需要 macOS 12 或更高版本。"

  architecture="$(/usr/bin/uname -m)"
  case "$architecture" in
    arm64|aarch64|x86_64) ;;
    *) fail "暂不支持当前 Mac 架构：${architecture}。" ;;
  esac

  for command in curl shasum hdiutil codesign ditto open awk find osascript plutil; do
    command -v "$command" >/dev/null 2>&1 || fail "系统缺少必要命令：${command}。"
  done
  /bin/mkdir -p "$CACHE_DIRECTORY"
}

normalize_token() {
  printf '%s' "$1" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]' | LC_ALL=C /usr/bin/tr -cd '[:alnum:]'
}

refresh_download_checksums() {
  local temporary_path="${CACHE_DIRECTORY}/SHA256SUMS.txt.download"
  /usr/bin/curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 90 \
    "${DOWNLOAD_BASE_URL}/SHA256SUMS.txt" \
    --output "$temporary_path"
  /bin/mv -f "$temporary_path" "${CACHE_DIRECTORY}/SHA256SUMS.txt"
}

expected_download_sha256() {
  local filename="$1"
  [[ -f "${CACHE_DIRECTORY}/SHA256SUMS.txt" ]] || refresh_download_checksums
  /usr/bin/awk -v filename="$filename" '$2 == filename { print $1; exit }' "${CACHE_DIRECTORY}/SHA256SUMS.txt"
}

download_server_file() {
  local filename="$1"
  local destination="${CACHE_DIRECTORY}/${filename}"
  local temporary_path="${destination}.download"
  local expected actual

  expected="$(expected_download_sha256 "$filename")"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "服务器没有发布 ${filename} 的 SHA-256。"

  if [[ -f "$destination" ]]; then
    actual="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
    if [[ "$(normalize_token "$actual")" == "$(normalize_token "$expected")" ]]; then
      printf '%s' "$destination"
      return
    fi
    /bin/rm -f "$destination"
  fi

  log "正在下载 ${filename}。"
  /usr/bin/curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 1800 \
    "${DOWNLOAD_BASE_URL}/${filename}" \
    --output "$temporary_path"

  actual="$(/usr/bin/shasum -a 256 "$temporary_path" | /usr/bin/awk '{print $1}')"
  if [[ "$(normalize_token "$actual")" != "$(normalize_token "$expected")" ]]; then
    /bin/rm -f "$temporary_path"
    fail "${filename} 的 SHA-256 校验失败。"
  fi
  /bin/mv -f "$temporary_path" "$destination"
  printf '%s' "$destination"
}

ensure_node() {
  local node_major=""
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    if [[ "$node_major" =~ ^[0-9]+$ ]] && (( node_major >= 20 )); then
      log "已检测到 Node.js $(node --version)。"
      return
    fi
  fi

  local package_path="${CACHE_DIRECTORY}/${NODE_PACKAGE}"
  local manifest_path="${CACHE_DIRECTORY}/node-SHASUMS256.txt"
  local temporary_manifest="${manifest_path}.download"
  local expected actual

  log "正在安装 Node.js ${NODE_VERSION} 官方通用安装包。"
  /usr/bin/curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 90 \
    "${NODE_DIST_URL}/SHASUMS256.txt" \
    --output "$temporary_manifest"
  /bin/mv -f "$temporary_manifest" "$manifest_path"
  expected="$(/usr/bin/awk -v filename="$NODE_PACKAGE" '$2 == filename { print $1; exit }' "$manifest_path")"
  [[ "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "Node.js 官方校验清单中缺少 ${NODE_PACKAGE}。"

  /usr/bin/curl --fail --location --silent --show-error --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 1800 \
    "${NODE_DIST_URL}/${NODE_PACKAGE}" \
    --output "${package_path}.download"
  actual="$(/usr/bin/shasum -a 256 "${package_path}.download" | /usr/bin/awk '{print $1}')"
  if [[ "$(normalize_token "$actual")" != "$(normalize_token "$expected")" ]]; then
    /bin/rm -f "${package_path}.download"
    fail "Node.js 官方安装包校验失败。"
  fi
  /bin/mv -f "${package_path}.download" "$package_path"
  /usr/bin/sudo /usr/sbin/installer -pkg "$package_path" -target /
  export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
  command -v node >/dev/null 2>&1 || fail "Node.js 安装完成，但系统仍找不到 node。"
  command -v npm >/dev/null 2>&1 || fail "Node.js 安装完成，但系统仍找不到 npm。"
}

ensure_codex_cli() {
  if command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1; then
    log "已检测到 Codex CLI $(codex --version)。"
    return
  fi

  log "正在安装 Codex CLI。"
  export NPM_CONFIG_PREFIX="${HOME}/.local"
  /bin/mkdir -p "$NPM_CONFIG_PREFIX"
  npm config set registry "$NPM_REGISTRY"
  npm config set fetch-retries 5
  npm config set fetch-retry-mintimeout 20000
  npm config set fetch-retry-maxtimeout 120000
  npm install --global @openai/codex --registry="$NPM_REGISTRY"
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v codex >/dev/null 2>&1 || fail "Codex CLI 安装完成，但系统仍找不到 codex。"
}

normalize_gateway() {
  node - "$1" <<'NODE'
const value = process.argv[2];
const parsed = new URL(value);
if (parsed.protocol !== 'https:') throw new Error('gateway must use https');
if (parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error('gateway contains unsupported URL fields');
const pathname = parsed.pathname.replace(/\/+$/, '');
process.stdout.write(`${parsed.origin}${pathname}`);
NODE
}

read_configuration() {
  local requested_gateway="" requested_model=""
  GATEWAY="$DEFAULT_GATEWAY"
  MODEL="$DEFAULT_MODEL"

  if [[ -t 0 ]]; then
    read -r -p "网关地址 [${GATEWAY}]: " requested_gateway
    read -r -p "默认模型 [${MODEL}]: " requested_model
    [[ -n "$requested_gateway" ]] && GATEWAY="$requested_gateway"
    [[ -n "$requested_model" ]] && MODEL="$requested_model"
  fi

  GATEWAY="$(normalize_gateway "$GATEWAY")" || fail "网关必须是无账号、查询参数和片段的 HTTPS 地址。"
  [[ -n "$MODEL" && "$MODEL" != *$'\n'* && "$MODEL" != *$'\r'* ]] || fail "默认模型不能为空或包含换行。"

  if [[ -z "${ANYU_API_KEY:-}" ]]; then
    [[ -t 0 ]] || fail "非交互运行时需要预先设置 ANYU_API_KEY。"
    read -r -s -p "安域 API Key（输入不会显示）: " API_KEY
    printf '\n'
  else
    API_KEY="$ANYU_API_KEY"
  fi
  [[ -n "$API_KEY" && "$API_KEY" != *$'\n'* && "$API_KEY" != *$'\r'* ]] || fail "API Key 不能为空或包含换行。"
}

write_codex_config() {
  local config_path="${HOME}/.codex/config.toml"
  /bin/mkdir -p "$(/usr/bin/dirname "$config_path")"
  node - "$config_path" "$GATEWAY" "$MODEL" <<'NODE'
const fs = require('fs');
const path = require('path');
const [target, gateway, model] = process.argv.slice(2);
if (fs.existsSync(target)) {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '');
  fs.copyFileSync(target, `${target}.bak_${stamp}`);
}
const toml = `model_provider = "anyu"
model = ${JSON.stringify(model)}
disable_response_storage = true
model_reasoning_effort = "high"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers]

[model_providers.anyu]
name = "Anyu AI"
wire_api = "responses"
requires_openai_auth = true
base_url = ${JSON.stringify(gateway)}

[features]
fast_mode = true
enable_request_compression = true
`;
const temporary = path.join(path.dirname(target), `.${path.basename(target)}.${process.pid}.tmp`);
fs.writeFileSync(temporary, toml, { encoding: 'utf8', mode: 0o600 });
fs.renameSync(temporary, target);
NODE
  log "已写入 ${config_path}，并启用完整本机权限。"
}

find_installed_application() {
  local expected_token="$1"
  local root candidate name normalized lowercase_name
  for root in /Applications "${HOME}/Applications"; do
    [[ -d "$root" ]] || continue
    for candidate in "$root"/*.app; do
      [[ -d "$candidate" ]] || continue
      name="$(/usr/bin/basename "$candidate")"
      normalized="$(normalize_token "$name")"
      lowercase_name="$(printf '%s' "$name" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]')"
      if [[ "$normalized" == *"$expected_token"* ]] || \
        [[ "$expected_token" == "codexplusplus" && "$lowercase_name" == "codex++.app" ]]; then
        printf '%s' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

INSTALLED_APPLICATION=""

install_dmg_application() {
  local filename="$1"
  local expected_token="$2"
  local dmg_path mount_point app_path app_name app_token destination stage backup timestamp

  dmg_path="$(download_server_file "$filename")"
  mount_point="$(/usr/bin/mktemp -d "${CACHE_DIRECTORY}/mount.XXXXXX")"
  MOUNT_POINTS+=("$mount_point")
  /usr/bin/hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_point" -quiet

  app_path="$(/usr/bin/find "$mount_point" -type d -name '*.app' -print | /usr/bin/head -n 1)"
  [[ -n "$app_path" && -d "$app_path" ]] || fail "${filename} 中没有 macOS 应用。"
  app_name="$(/usr/bin/basename "$app_path")"
  app_token="$(normalize_token "$app_name")"
  if [[ "$app_token" != *"$expected_token"* ]] && \
    ! [[ "$expected_token" == "codexplusplus" && "$(printf '%s' "$app_name" | LC_ALL=C /usr/bin/tr '[:upper:]' '[:lower:]')" == "codex++.app" ]]; then
    fail "${filename} 中包含了不符合预期的应用：${app_name}。"
  fi

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" >/dev/null
  if ! /usr/sbin/spctl --assess --type open --verbose=2 "$app_path" >/dev/null 2>&1; then
    log "${app_name} 未通过 Gatekeeper 公证检查，但代码签名结构有效；继续本地安装。"
  fi

  destination="/Applications/${app_name}"
  stage="/Applications/.${app_name}.staged.$$"
  backup=""
  timestamp="$(/bin/date -u +%Y%m%d%H%M%S)"
  /usr/bin/sudo /usr/bin/test ! -e "$stage" || fail "存在未清理的暂存目录：${stage}。"
  /usr/bin/sudo /usr/bin/ditto "$app_path" "$stage"
  if /usr/bin/sudo /usr/bin/test -e "$destination"; then
    backup="/Applications/.${app_name}.backup.${timestamp}"
    /usr/bin/sudo /bin/mv "$destination" "$backup"
  fi
  if ! /usr/bin/sudo /bin/mv "$stage" "$destination"; then
    if [[ -n "$backup" ]] && /usr/bin/sudo /usr/bin/test -e "$backup"; then
      /usr/bin/sudo /bin/mv "$backup" "$destination" || true
    fi
    fail "无法安装 ${app_name}。"
  fi

  /usr/bin/hdiutil detach "$mount_point" -quiet
  /bin/rmdir "$mount_point" || true
  INSTALLED_APPLICATION="$destination"
}

configure_codex_plus() {
  /bin/mkdir -p "$(/usr/bin/dirname "$CODEX_PLUS_SETTINGS")"
  ANYU_API_KEY="$API_KEY" node - "$CODEX_PLUS_SETTINGS" "$GATEWAY" "$MODEL" <<'NODE'
const fs = require('fs');
const path = require('path');
const [target, gateway, model] = process.argv.slice(2);
const key = process.env.ANYU_API_KEY || '';
let settings = {};
if (fs.existsSync(target)) {
  const stamp = new Date().toISOString().replace(/[-:.TZ]/g, '');
  fs.copyFileSync(target, `${target}.bak_${stamp}`);
  try { settings = JSON.parse(fs.readFileSync(target, 'utf8').replace(/^\uFEFF/, '')); } catch (_) { settings = {}; }
}
const configContents = `model_provider = "anyu"
model = ${JSON.stringify(model)}
disable_response_storage = true
model_reasoning_effort = "high"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers]

[model_providers.anyu]
name = "Anyu AI"
wire_api = "responses"
requires_openai_auth = true
base_url = ${JSON.stringify(gateway)}

[features]
fast_mode = true
enable_request_compression = true
`;
const profile = {
  id: 'anyu-ai-codex', name: 'Anyu AI Gateway', upstreamBaseUrl: gateway,
  protocol: 'responses', relayMode: 'pureApi', officialMixApiKey: false,
  testModel: model, configContents,
  authContents: JSON.stringify({ OPENAI_API_KEY: key, auth_mode: 'apikey' }, null, 2) + '\n',
  useCommonConfig: true, contextSelection: { mcpServers: [], skills: [], plugins: [] },
  contextSelectionInitialized: false, contextWindow: '', autoCompactLimit: '',
  modelInsertMode: 'patch', modelList: model,
};
const profiles = Array.isArray(settings.relayProfiles) ? settings.relayProfiles : [];
const index = profiles.findIndex((entry) => entry && (entry.id === profile.id || String(entry.upstreamBaseUrl || '').replace(/\/$/, '') === gateway));
if (index >= 0) profiles[index] = { ...profiles[index], ...profile }; else profiles.push(profile);
settings.relayProfiles = profiles;
Object.assign(settings, {
  codexAppPath: settings.codexAppPath || '',
  codexExtraArgs: settings.codexExtraArgs || [],
  providerSyncEnabled: settings.providerSyncEnabled || false,
  providerSyncSavedProviders: settings.providerSyncSavedProviders || [],
  providerSyncManualProviders: settings.providerSyncManualProviders || [],
  providerSyncLastSelectedProvider: settings.providerSyncLastSelectedProvider || '',
  relayProfilesEnabled: true,
  enhancementsEnabled: settings.enhancementsEnabled !== false,
  launchMode: settings.launchMode || 'patch',
  relayCommonConfigContents: settings.relayCommonConfigContents || '',
  relayContextConfigContents: settings.relayContextConfigContents || '',
  aggregateRelayProfiles: settings.aggregateRelayProfiles || [],
  activeAggregateRelayId: settings.activeAggregateRelayId || '',
  relayTestModel: model,
  cliWrapperEnabled: settings.cliWrapperEnabled || false,
  cliWrapperBaseUrl: settings.cliWrapperBaseUrl || '',
  cliWrapperApiKey: settings.cliWrapperApiKey || '',
  cliWrapperApiKeyEnv: settings.cliWrapperApiKeyEnv || 'CUSTOM_OPENAI_API_KEY',
  activeRelayId: profile.id,
});
const temporary = path.join(path.dirname(target), `.${path.basename(target)}.${process.pid}.tmp`);
fs.writeFileSync(temporary, JSON.stringify(settings, null, 2) + '\n', { encoding: 'utf8', mode: 0o600 });
fs.renameSync(temporary, target);
NODE
  log "已写入 Codex++ 安域网关配置。"
}

import_cc_switch_provider() {
  local import_url
  import_url="$(ANYU_API_KEY="$API_KEY" node - "$GATEWAY" "$MODEL" <<'NODE'
const [gateway, model] = process.argv.slice(2);
const url = new URL('ccswitch://v1/import');
for (const [key, value] of Object.entries({
  resource: 'provider', app: 'codex', name: '安域 AI Codex', homepage: gateway,
  endpoint: gateway, apiKey: process.env.ANYU_API_KEY || '', model,
  notes: 'Anyu AI Gateway for Codex', enabled: 'true',
})) url.searchParams.set(key, value);
process.stdout.write(url.toString());
NODE
)"
  /usr/bin/open "$import_url" >/dev/null 2>&1 || log "CC Switch 已安装，但未自动打开提供商导入确认。"
}

main() {
  require_macos
  ensure_node
  ensure_codex_cli
  read_configuration

  log "正在通过 Codex 官方登录流程保存本机 API Key。"
  printf '%s\n' "$API_KEY" | codex login --with-api-key
  codex login status || true
  write_codex_config
  refresh_download_checksums

  local cc_switch_app codex_plus_app="" architecture
  cc_switch_app="$(find_installed_application "ccswitch" || true)"
  if [[ -z "$cc_switch_app" ]]; then
    install_dmg_application "CC-Switch-v3.18.0-macOS.dmg" "ccswitch"
    cc_switch_app="$INSTALLED_APPLICATION"
  else
    log "已检测到 CC Switch。"
  fi

  architecture="$(/usr/bin/uname -m)"
  if [[ "$architecture" == "arm64" || "$architecture" == "aarch64" ]]; then
    codex_plus_app="$(find_installed_application "codexplusplus" || true)"
    if [[ -z "$codex_plus_app" ]]; then
      install_dmg_application "CodexPlusPlus-1.2.43-macos-arm64.dmg" "codexplusplus"
      codex_plus_app="$INSTALLED_APPLICATION"
    else
      log "已检测到 Codex++。"
    fi
    configure_codex_plus
  else
    log "当前为 Intel Mac；Codex++ 公开包仅支持 Apple Silicon，已跳过，不影响 Codex 与 CC Switch。"
  fi

  import_cc_switch_provider

  if [[ -d /Applications/Codex.app || -d "${HOME}/Applications/Codex.app" ]]; then
    /usr/bin/open -a Codex >/dev/null 2>&1 || true
  else
    log "正在打开 Codex 官方桌面版安装入口。"
    codex app "${HOME}" >/dev/null 2>&1 || /usr/bin/open "https://chatgpt.com/codex" >/dev/null 2>&1 || true
  fi
  /usr/bin/open "$cc_switch_app" >/dev/null 2>&1 || true
  [[ -z "$codex_plus_app" ]] || /usr/bin/open "$codex_plus_app" >/dev/null 2>&1 || true

  log "全部完成。Codex CLI 与 CC Switch 已连接 ${GATEWAY}。"
}

main "$@"
