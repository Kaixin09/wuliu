#!/bin/sh

if [ -z "${BASH_VERSION:-}" ]; then
  if [ ! -f /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] This installer only supports Alpine Linux' >&2
    exit 1
  fi
  if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' '[ERROR] Run this installer as root or with sudo' >&2
    exit 1
  fi
  apk add --no-cache bash ca-certificates curl >/dev/null || exit 1
  exec /bin/bash "$0" "$@"
fi

set -Eeuo pipefail

installRoot="/etc/ssx"
configFile="${installRoot}/config.yml"
credentialsFile="${installRoot}/credentials.env"
metaFile="${installRoot}/install-meta.json"
binaryPath="/usr/local/bin/ssx"
cliPath="/usr/local/bin/ssxctl"
servicePath="/etc/init.d/ssx"
releaseBase="https://github.com/cedar2025/xboard-node/releases"

action="install"
mode=""
panelUrl=""
token=""
nodeId=""
machineId=""
nodeType=""
kernelType="singbox"
releaseVersion="v1.13"
healthPort="65530"
goMemLimit="64MiB"
goGc="50"
purge=0
yes=0
arch=""
tmpDir=""

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

cleanup() {
  if [ -n "$tmpDir" ] && [ -d "$tmpDir" ]; then
    rm -rf "$tmpDir"
  fi
}
trap cleanup EXIT

showHelp() {
  cat <<'EOF'
ssx - Xboard Node Alpine installer

Usage:
  bash ssx.sh --mode machine --panel URL --token TOKEN --machine-id ID
  bash ssx.sh --mode node --panel URL --token TOKEN --node-id ID
  bash ssx.sh status
  bash ssx.sh upgrade
  bash ssx.sh uninstall [--purge] [--yes]

Options:
  --mode node|machine
  --panel, --panel-url, --api URL
  --token TOKEN
  --node-id ID
  --machine-id ID
  --node-type TYPE
  --kernel singbox|xray
  --version VERSION        Default and verified: v1.13
  --health-port PORT
  --gomemlimit VALUE       Default: 64MiB
  --gogc VALUE             Default: 50
  --purge
  --yes, -y
EOF
}

requireValue() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    error "$1 requires a value"
    exit 1
  fi
}

parseArgs() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install|upgrade|uninstall|status|help)
        action="$1"
        shift
        ;;
      --mode)
        requireValue "$1" "${2:-}"; mode="$2"; shift 2
        ;;
      --panel|--panel-url|--api|-a)
        requireValue "$1" "${2:-}"; panelUrl="$2"; shift 2
        ;;
      --token|-t)
        requireValue "$1" "${2:-}"; token="$2"; shift 2
        ;;
      --node-id|-n)
        requireValue "$1" "${2:-}"; nodeId="$2"; shift 2
        ;;
      --machine-id)
        requireValue "$1" "${2:-}"; machineId="$2"; shift 2
        ;;
      --node-type|-T)
        requireValue "$1" "${2:-}"; nodeType="$2"; shift 2
        ;;
      --kernel|-k)
        requireValue "$1" "${2:-}"; kernelType="$2"; shift 2
        ;;
      --version)
        requireValue "$1" "${2:-}"; releaseVersion="$2"; shift 2
        ;;
      --health-port)
        requireValue "$1" "${2:-}"; healthPort="$2"; shift 2
        ;;
      --gomemlimit)
        requireValue "$1" "${2:-}"; goMemLimit="$2"; shift 2
        ;;
      --gogc)
        requireValue "$1" "${2:-}"; goGc="$2"; shift 2
        ;;
      --purge)
        purge=1; shift
        ;;
      --yes|-y)
        yes=1; shift
        ;;
      --help|-h)
        action="help"; shift
        ;;
      *)
        error "Unknown argument: $1"
        showHelp
        exit 1
        ;;
    esac
  done

  if [ -z "$mode" ]; then
    if [ -n "$machineId" ]; then mode="machine"; else mode="node"; fi
  fi
}

checkEnvironment() {
  if [ "$(id -u)" -ne 0 ]; then
    error "Run this installer as root or with sudo"
    exit 1
  fi
  if [ ! -f /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
    error "This installer only supports Alpine Linux"
    exit 1
  fi
  if ! command -v rc-service >/dev/null 2>&1; then
    error "OpenRC is required"
    exit 1
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

installDependencies() {
  apk add --no-cache ca-certificates curl bash >/dev/null
  update-ca-certificates >/dev/null 2>&1 || true
}

checkResources() {
  local availableKb freeKb
  availableKb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
  freeKb=$(df -Pk / | awk 'NR == 2 {print $4}')
  if [ -n "$availableKb" ] && [ "$availableKb" -lt 65536 ]; then
    warn "Available memory is below 64 MiB; add swap before installation"
  fi
  if [ -n "$freeKb" ] && [ "$freeKb" -lt 204800 ]; then
    error "At least 200 MiB of free disk space is required"
    exit 1
  fi
}

validatePositiveInt() {
  case "$2" in
    ''|*[!0-9]*) error "$1 must be a positive integer"; exit 1 ;;
    0) error "$1 must be greater than zero"; exit 1 ;;
  esac
}

validateInstall() {
  [ -n "$panelUrl" ] || { error "--panel is required"; exit 1; }
  [ -n "$token" ] || { error "--token is required"; exit 1; }
  case "$mode" in
    machine) validatePositiveInt "Machine ID" "$machineId" ;;
    node) validatePositiveInt "Node ID" "$nodeId" ;;
    *) error "--mode must be node or machine"; exit 1 ;;
  esac
  case "$kernelType" in
    singbox|xray) ;;
    *) error "--kernel must be singbox or xray"; exit 1 ;;
  esac
  case "$healthPort" in ''|*[!0-9]*) error "--health-port must be 0-65535"; exit 1 ;; esac
  if [ "$healthPort" -gt 65535 ]; then error "--health-port must be 0-65535"; exit 1; fi
}

getDownloadUrl() {
  local artifact="$1"
  if [ "$releaseVersion" = "latest" ]; then
    printf '%s/latest/download/%s' "$releaseBase" "$artifact"
  else
    printf '%s/download/%s/%s' "$releaseBase" "$releaseVersion" "$artifact"
  fi
}

getExpectedDigest() {
  case "$releaseVersion:$1:$arch" in
    v1.13:daemon:amd64) printf '%s' '55bf71fa9d9f2048d3255ae7c0af929a41897ca7743f6ead34132a6ca4c79043' ;;
    v1.13:daemon:arm64) printf '%s' '40835fd216cdeaa731f69cab3f0cb0b93b6e9a145a0489beddbc25b6473658d7' ;;
    v1.13:cli:amd64) printf '%s' '8ec7b9bbf0abb99a9c24b1b3ceef1ed5496f458e7dc22b09c33b098d5b2aad9e' ;;
    v1.13:cli:arm64) printf '%s' '0c9b67e767d7baa9d4dae53b8ace31b9eb3209a3f1e41e62dc1b0f410dc8ba18' ;;
    *) error "No trusted checksum for ${releaseVersion} ($1/${arch})"; exit 1 ;;
  esac
}

verifyDigest() {
  local file="$1" expected="$2" actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  if [ "$actual" != "$expected" ]; then
    error "Checksum verification failed for $(basename "$file")"
    exit 1
  fi
}

downloadBinaries() {
  local daemonUrl cliUrl daemonDigest cliDigest
  daemonUrl=$(getDownloadUrl "xboard-node-linux-${arch}")
  cliUrl=$(getDownloadUrl "xbctl-linux-${arch}")
  info "Downloading official Xboard Node release for ${arch}"
  curl -fL --retry 3 --connect-timeout 15 "$daemonUrl" -o "${tmpDir}/ssx"
  curl -fL --retry 3 --connect-timeout 15 "$cliUrl" -o "${tmpDir}/ssxctl"
  daemonDigest=$(getExpectedDigest daemon)
  cliDigest=$(getExpectedDigest cli)
  verifyDigest "${tmpDir}/ssx" "$daemonDigest"
  verifyDigest "${tmpDir}/ssxctl" "$cliDigest"
  chmod 755 "${tmpDir}/ssx" "${tmpDir}/ssxctl"
  "${tmpDir}/ssx" -v >/dev/null
  "${tmpDir}/ssxctl" version >/dev/null
}

renderConfig() {
  local args
  args=(
    config init
    --mode "$mode"
    --panel-url "$panelUrl"
    --kernel "$kernelType"
    --health-port "$healthPort"
    --token "$token"
    --version "$releaseVersion"
    --output "${tmpDir}/config.yml"
    --credentials-out "${tmpDir}/credentials.env"
    --meta "${tmpDir}/install-meta.json"
    --install-root "$installRoot"
    --gomemlimit "$goMemLimit"
    --gogc "$goGc"
  )

  [ ! -f "$configFile" ] || args+=(--config "$configFile")
  [ ! -f "$credentialsFile" ] || args+=(--credentials-in "$credentialsFile")

  if [ "$mode" = "machine" ]; then
    args+=(--machine-id "$machineId")
  else
    args+=(--node-id "$nodeId")
    [ -z "$nodeType" ] || args+=(--node-type "$nodeType")
  fi

  "${tmpDir}/ssxctl" "${args[@]}" >/dev/null
  chmod 600 "${tmpDir}/config.yml" "${tmpDir}/credentials.env"
}

renderService() {
  cat >"${tmpDir}/ssx.openrc" <<EOF
#!/sbin/openrc-run

name="ssx"
description="Xboard Node Backend for Alpine"
command="${binaryPath}"
command_args="-c ${configFile}"
command_background="yes"
pidfile="/run/ssx.pid"
output_log="/var/log/ssx.log"
error_log="/var/log/ssx.log"
directory="${installRoot}"

start_pre() {
  if [ -f "${credentialsFile}" ]; then
    if grep -Ev '^[A-Za-z_][A-Za-z0-9_]*=' "${credentialsFile}" | grep -q .; then
      eerror "Invalid credentials file format"
      return 1
    fi
    set -a
    . "${credentialsFile}"
    set +a
  fi
}

depend() {
  need net
  after firewall
}
EOF
  chmod 755 "${tmpDir}/ssx.openrc"
}

installFiles() {
  rc-service ssx stop >/dev/null 2>&1 || true
  mkdir -p "$installRoot"
  chmod 700 "$installRoot"
  install -m 755 "${tmpDir}/ssx" "$binaryPath"
  install -m 755 "${tmpDir}/ssxctl" "$cliPath"
  install -m 600 "${tmpDir}/config.yml" "$configFile"
  install -m 600 "${tmpDir}/credentials.env" "$credentialsFile"
  install -m 644 "${tmpDir}/install-meta.json" "$metaFile"
  install -m 755 "${tmpDir}/ssx.openrc" "$servicePath"
  rc-update add ssx default >/dev/null 2>&1
  rc-service ssx restart
}

waitForService() {
  local attempt=0
  while [ "$attempt" -lt 20 ]; do
    if rc-service ssx status >/dev/null 2>&1; then
      if [ "$healthPort" = "0" ] || curl -fsS "http://127.0.0.1:${healthPort}/healthz" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  error "ssx failed to become healthy"
  [ ! -f /var/log/ssx.log ] || tail -n 30 /var/log/ssx.log >&2
  return 1
}

performInstall() {
  validateInstall
  tmpDir=$(mktemp -d)
  downloadBinaries
  renderConfig
  renderService
  installFiles
  waitForService
  info "ssx installed successfully"
  info "Service: rc-service ssx status"
  info "Config: ${configFile}"
  info "Logs: /var/log/ssx.log"
}

performUpgrade() {
  [ -f "$configFile" ] || { error "ssx is not installed"; exit 1; }
  tmpDir=$(mktemp -d)
  downloadBinaries
  cp "$binaryPath" "${tmpDir}/ssx.previous"
  cp "$cliPath" "${tmpDir}/ssxctl.previous"
  rc-service ssx stop >/dev/null 2>&1 || true
  install -m 755 "${tmpDir}/ssx" "$binaryPath"
  install -m 755 "${tmpDir}/ssxctl" "$cliPath"
  rc-service ssx start
  if ! waitForService; then
    warn "Upgrade failed; restoring the previous version"
    rc-service ssx stop >/dev/null 2>&1 || true
    install -m 755 "${tmpDir}/ssx.previous" "$binaryPath"
    install -m 755 "${tmpDir}/ssxctl.previous" "$cliPath"
    rc-service ssx start || true
    exit 1
  fi
  info "ssx upgraded successfully"
}

performStatus() {
  if [ ! -x "$binaryPath" ]; then
    warn "ssx is not installed"
    exit 1
  fi
  "$binaryPath" -v || true
  rc-service ssx status
}

performUninstall() {
  if [ "$yes" -ne 1 ]; then
    printf 'Uninstall ssx? [y/N] '
    read -r answer
    case "$answer" in y|Y) ;; *) exit 0 ;; esac
  fi
  rc-service ssx stop >/dev/null 2>&1 || true
  rc-update del ssx default >/dev/null 2>&1 || true
  rm -f "$servicePath" "$binaryPath" "$cliPath"
  rm -f /run/ssx.pid
  if [ "$purge" -eq 1 ]; then
    rm -rf "$installRoot"
    rm -f /var/log/ssx.log
  fi
  info "ssx uninstalled"
}

main() {
  parseArgs "$@"
  if [ "$action" = "help" ]; then showHelp; exit 0; fi
  checkEnvironment
  case "$action" in
    install) installDependencies; checkResources; performInstall ;;
    upgrade) installDependencies; checkResources; performUpgrade ;;
    status) performStatus ;;
    uninstall) performUninstall ;;
    *) error "Unknown action: $action"; exit 1 ;;
  esac
}

main "$@"
