#!/usr/bin/env bash
# ==============================================================================
# fetch-media.sh
# Downloads and manages installation media (ISOs, cloud images, drivers)
# in ~/.config/vm-stack/media/.
# ==============================================================================

set -euo pipefail

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
MEDIA_DIR="$CONFIG_DIR/media"
PREFERENCES_FILE="$CONFIG_DIR/preferences.json"

log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

ensure_media_dir() {
  mkdir -p "$MEDIA_DIR" 2>/dev/null || true
}

get_host_arch() {
  local m
  m="$(uname -m 2>/dev/null || echo "arm64")"
  case "$m" in
    arm64|aarch64) echo "aarch64" ;;
    x86_64|amd64)  echo "x86_64" ;;
    *)             echo "$m" ;;
  esac
}

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} fetch-media.sh <command> [options]

Manages VM installation media in ${DIM}$MEDIA_DIR/${RESET}

${BOLD}Commands:${RESET}
  ${BLUE}virtio-win${RESET}               Download latest stable Red Hat VirtIO Windows drivers ISO
  ${BLUE}ubuntu${RESET} [arch]            Download latest Ubuntu Server cloud image (.img)
  ${BLUE}debian${RESET} [arch]            Download latest Debian genericcloud image (.qcow2)
  ${BLUE}alpine${RESET} [arch]            Download latest Alpine Linux virtual image (.qcow2)
  ${BLUE}find-windows${RESET} [arch]      Find or check for local Windows ISO in media directory
  ${BLUE}list${RESET}                     List all media files currently in ~/.config/vm-stack/media/
  ${BLUE}path${RESET}                     Print media directory path

${BOLD}Options:${RESET}
  --url <url>              Custom download URL
  --force                  Re-download even if file already exists in cache
  -h, --help               Show this help message
EOF
}

download_file() {
  local url="$1"
  local dest="$2"
  local force="${3:-0}"

  if [[ -f "$dest" && "$force" -eq 0 ]]; then
    log_info "Media already cached: $(basename "$dest")"
    return 0
  fi

  log_info "Downloading: $url -> $dest"
  local tmp_dest="${dest}.tmp.$$"

  if command -v curl >/dev/null 2>&1; then
    curl -fL -C - --progress-bar -o "$tmp_dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --progress=bar:force -O "$tmp_dest" "$url"
  else
    log_error "Neither curl nor wget is available."
    return 1
  fi

  mv "$tmp_dest" "$dest"
  log_info "Download complete: $dest"
}

fetch_virtio_win() {
  local force=0
  [[ "${1:-}" = "--force" ]] && force=1

  ensure_media_dir
  local url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  local dest="$MEDIA_DIR/virtio-win.iso"
  download_file "$url" "$dest" "$force"
}

fetch_ubuntu() {
  local arch="${1:-$(get_host_arch)}"
  local force=0
  [[ "${2:-}" = "--force" ]] && force=1

  ensure_media_dir
  local ubuntu_arch="arm64"
  [[ "$arch" = "x86_64" ]] && ubuntu_arch="amd64"

  local url="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ubuntu_arch}.img"
  local dest="$MEDIA_DIR/ubuntu-24.04-server-cloudimg-${arch}.img"
  download_file "$url" "$dest" "$force"
}

fetch_debian() {
  local arch="${1:-$(get_host_arch)}"
  local force=0
  [[ "${2:-}" = "--force" ]] && force=1

  ensure_media_dir
  local debian_arch="arm64"
  [[ "$arch" = "x86_64" ]] && debian_arch="amd64"

  local url="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-${debian_arch}.qcow2"
  local dest="$MEDIA_DIR/debian-12-genericcloud-${arch}.qcow2"
  download_file "$url" "$dest" "$force"
}

find_windows_iso() {
  local arch="${1:-$(get_host_arch)}"
  ensure_media_dir

  local found=""
  local candidates
  if [[ "$arch" = "aarch64" ]]; then
    candidates=$(find "$MEDIA_DIR" -maxdepth 2 -type f \( -iname "*win*11*arm*.iso" -o -iname "*win*arm64*.iso" -o -iname "*24H2*arm*.iso" -o -iname "*windows*.iso" \) 2>/dev/null || true)
  else
    candidates=$(find "$MEDIA_DIR" -maxdepth 2 -type f \( -iname "*win*11*x64*.iso" -o -iname "*win*10*x64*.iso" -o -iname "*windows*64*.iso" -o -iname "*windows*.iso" \) 2>/dev/null || true)
  fi

  if [[ -n "$candidates" ]]; then
    found="$(echo "$candidates" | head -n 1)"
    echo "$found"
    return 0
  else
    return 1
  fi
}

list_media() {
  ensure_media_dir
  printf '\n%sMedia Storage:%s %s\n\n' "$BOLD" "$RESET" "$MEDIA_DIR"
  if ! ls -lh "$MEDIA_DIR" 2>/dev/null | grep -v '^total'; then
    printf '  %s(No media files cached in %s)%s\n\n' "$DIM" "$MEDIA_DIR" "$RESET"
  fi
}

# Command dispatch
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

CMD="$1"
shift

case "$CMD" in
  virtio-win|virtio)
    fetch_virtio_win "$@"
    ;;
  ubuntu)
    fetch_ubuntu "$@"
    ;;
  debian)
    fetch_debian "$@"
    ;;
  find-windows|check-windows)
    if iso_path="$(find_windows_iso "$@")"; then
      log_info "Found Windows ISO: $iso_path"
      echo "$iso_path"
      exit 0
    else
      log_warn "No Windows ISO matching architecture found in $MEDIA_DIR."
      exit 1
    fi
    ;;
  list|ls)
    list_media
    ;;
  path)
    ensure_media_dir
    echo "$MEDIA_DIR"
    ;;
  -h|--help|help)
    show_help
    exit 0
    ;;
  *)
    log_error "Unknown command: $CMD"
    show_help
    exit 1
    ;;
esac
