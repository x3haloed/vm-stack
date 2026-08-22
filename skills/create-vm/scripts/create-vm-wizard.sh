#!/usr/bin/env bash
# ==============================================================================
# create-vm-wizard.sh
# Interactive multi-stage setup wizard for provisioning virtual machines
# in vm-stack.
#
# Walks the user through:
# 1. Architecture & OS selection
# 2. Media acquisition (including browser-assisted ISO download & path capture)
# 3. Hardware sizing (vCPUs, RAM, Disk)
# 4. Automated unattended installation launch
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANAGE_VMS_SCRIPT="$REPO_DIR/skills/manage-vms/scripts/manage-vms.sh"
FETCH_MEDIA_SCRIPT="$SCRIPT_DIR/fetch-media.sh"
CREATE_WIN_SCRIPT="$SCRIPT_DIR/create-windows-vm.sh"
LAUNCH_TERMINAL_SCRIPT="$SCRIPT_DIR/launch-terminal.sh"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
MEDIA_DIR="$CONFIG_DIR/media"
IMAGES_DIR="$CONFIG_DIR/images"

# ──────────────────────────────────────────────────────────────────────────
# Check for Interactive Terminal vs Background Agent Subshell
# ──────────────────────────────────────────────────────────────────────────

# If invoked with --terminal OR executed non-interactively (e.g. from an agent task),
# pop open a visible terminal window on the user's desktop and exit gracefully.
if [[ "${1:-}" = "--terminal" ]] || [[ ! -t 0 || ! -t 1 ]]; then
  SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  # Filter out --terminal from args if present
  ARGS=()
  for arg in "$@"; do
    [[ "$arg" != "--terminal" ]] && ARGS+=("$arg")
  done
  exec "$LAUNCH_TERMINAL_SCRIPT" "$SCRIPT_PATH" ${ARGS[@]+"${ARGS[@]}"}
fi

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# ──────────────────────────────────────────────────────────────────────────
# Wizard Primitives
# ──────────────────────────────────────────────────────────────────────────

_STAGE_INDEX=0
TOTAL_STAGES=4
ACTIONS_PERFORMED=()
SKIPPED_ACTIONS=()

_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stages%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  This wizard guides you through acquiring OS media, allocating hardware\n' "$DIM"
  printf '  resources, and provisioning a local VM in vm-stack.%s\n\n' "$RESET"
  pause "Press Enter to start..."
}

stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()     { printf '  %s\n' "$1"; }
step()    { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note()    { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn()    { printf '  %s⚠ %s%s\n' "$YELLOW" "$RESET" "$1"; }
success() { printf '  %s✓ %s%s\n' "$GREEN" "$1" "$RESET"; }

pause() {
  printf '  %s%s%s ' "$DIM" "${1:-Press Enter to continue}" "$RESET"
  read -r _ || true
}

confirm() {
  local reply=""
  printf '  %s? %s [Y/n] %s' "$YELLOW" "$1" "$RESET"
  read -r reply || true
  [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

ask() {
  local var_name="$1"
  local prompt="$2"
  local default_val="${3:-}"
  local input=""

  if [[ -n "$default_val" ]]; then
    printf '  %s%s%s %s[%s]%s: ' "$BOLD" "$prompt" "$RESET" "$DIM" "$default_val" "$RESET"
  else
    printf '  %s%s%s: ' "$BOLD" "$prompt" "$RESET"
  fi

  read -r input || true
  [[ -z "$input" && -n "$default_val" ]] && input="$default_val"
  printf -v "$var_name" '%s' "$input"
}

open_url() {
  local url="$1"
  step "Opening browser: $url"
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 || warn "Could not open browser. Please visit: $url"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || warn "Could not open browser. Please visit: $url"
  else
    warn "Please visit in your browser: $url"
  fi
}

finish() {
  _clear
  printf '\n%s%s  ✓ VM Provisioning Wizard Complete%s\n\n' "$BOLD" "$GREEN" "$RESET"
  if [[ -n "${ACTIONS_PERFORMED[*]-}" ]]; then
    note "Summary of actions:"
    for act in "${ACTIONS_PERFORMED[@]}"; do
      printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$act"
    done
    printf '\n'
  fi

  printf '  %sVM Name:%s      %s\n' "$BOLD" "$RESET" "$VM_NAME"
  printf '  %sOS Type:%s      %s\n' "$BOLD" "$RESET" "$OS_CHOICE"
  printf '  %sArch:%s         %s\n' "$BOLD" "$RESET" "$TARGET_ARCH"
  printf '  %sAllocations:%s  %s vCPUs, %s RAM, %s Disk\n' "$BOLD" "$RESET" "$VM_CPUS" "$VM_RAM" "$VM_SIZE"
  printf '  %sDisk Path:%s    %s\n\n' "$BOLD" "$RESET" "$IMAGES_DIR/${VM_NAME}.qcow2"

  if [[ "$OS_CHOICE" = "windows" ]]; then
    note "Connection Ports:"
    printf '  %s• SSH:%s localhost:2222 (user: %s, pass: %s)\n' "$BLUE" "$RESET" "$ADMIN_USER" "$ADMIN_PASS"
    printf '  %s• RDP:%s localhost:3389\n\n' "$BLUE" "$RESET"
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Wizard Stages
# ──────────────────────────────────────────────────────────────────────────

HOST_ARCH="$(uname -m 2>/dev/null || echo "arm64")"
TARGET_ARCH="aarch64"
[[ "$HOST_ARCH" = "x86_64" || "$HOST_ARCH" = "amd64" ]] && TARGET_ARCH="x86_64"

OS_CHOICE="windows"
VM_NAME="win11-dev"
VM_RAM="8G"
VM_CPUS="4"
VM_SIZE="64G"
ADMIN_USER="admin"
ADMIN_PASS="admin"
MEDIA_ISO=""
WINDOWS_ACCEL="hvf"

banner "vm-stack VM Creation Wizard"

# Stage 1: Select OS & Architecture
stage "Select OS & Architecture"
say "Host architecture detected: $HOST_ARCH ($TARGET_ARCH)"
say "Select target operating system:"
if [[ "$HOST_ARCH" = "arm64" || "$HOST_ARCH" = "aarch64" ]]; then
  printf '\n    1) Windows 11 ARM64 — HVF virtualization (fast)\n'
  printf '    2) Windows 11 x86-64 — TCG emulation (slow compatibility mode)\n'
  printf '    3) Ubuntu 24.04 Server (aarch64)\n'
  printf '    4) Debian 12 (aarch64)\n'
  printf '    5) Custom ISO / Disk Image\n\n'
  ask OS_SELECTION "Enter selection (1-5)" "1"
  case "$OS_SELECTION" in
    1) OS_CHOICE="windows"; TARGET_ARCH="aarch64"; WINDOWS_ACCEL="hvf"; VM_NAME="win11-dev" ;;
    2) OS_CHOICE="windows"; TARGET_ARCH="x86_64"; WINDOWS_ACCEL="tcg"; VM_NAME="win11-x64-tcg";
       warn "x86-64 TCG installation may take several hours." ;;
    3) OS_CHOICE="ubuntu"; VM_NAME="ubuntu-24-dev"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="20G" ;;
    4) OS_CHOICE="debian"; VM_NAME="debian-12-dev"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="20G" ;;
    *) OS_CHOICE="custom"; VM_NAME="custom-vm"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="30G" ;;
  esac
else
  printf '\n    1) Windows 11 (x86_64)\n'
  printf '    2) Ubuntu 24.04 Server (x86_64)\n'
  printf '    3) Debian 12 (x86_64)\n'
  printf '    4) Custom ISO / Disk Image\n\n'
  ask OS_SELECTION "Enter selection (1-4)" "1"
  case "$OS_SELECTION" in
    1) OS_CHOICE="windows"; VM_NAME="win11-dev" ;;
    2) OS_CHOICE="ubuntu"; VM_NAME="ubuntu-24-dev"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="20G" ;;
    3) OS_CHOICE="debian"; VM_NAME="debian-12-dev"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="20G" ;;
    *) OS_CHOICE="custom"; VM_NAME="custom-vm"; VM_RAM="4G"; VM_CPUS="2"; VM_SIZE="30G" ;;
  esac
fi

success "Selected: $OS_CHOICE ($TARGET_ARCH)"
ACTIONS_PERFORMED+=("Selected OS: $OS_CHOICE ($TARGET_ARCH)")

# Stage 2: Media Acquisition
stage "Acquire Installation Media"

if [[ "$OS_CHOICE" = "windows" ]]; then
  say "Checking local media cache (~/.config/vm-stack/media/)..."
  if MEDIA_ISO="$("$FETCH_MEDIA_SCRIPT" find-windows "$TARGET_ARCH" 2>/dev/null)"; then
    success "Found cached Windows ISO: $MEDIA_ISO"
  else
    warn "No Windows ISO found in $MEDIA_DIR."
    say "To install Windows 11 for a $TARGET_ARCH guest:"
    step "Download the official Windows 11 ($TARGET_ARCH) ISO from Microsoft."
    printf '\n'
    open_url "https://www.microsoft.com/en-us/software-download/windows11"
    printf '\n'
    note "On the Microsoft page, select the Windows 11 ISO for $TARGET_ARCH and download it."
    DEFAULT_WINDOWS_ISO="$HOME/Downloads/Win11_Arm64.iso"
    [[ "$TARGET_ARCH" = "x86_64" ]] && DEFAULT_WINDOWS_ISO="$HOME/Downloads/Win11_x64.iso"
    ask MEDIA_ISO "Enter the path to your downloaded Windows ISO" "$DEFAULT_WINDOWS_ISO"
    while [[ ! -f "$MEDIA_ISO" ]]; do
      warn "File does not exist: $MEDIA_ISO"
      ask MEDIA_ISO "Please enter a valid path to the Windows ISO"
    done
    success "Validated Windows ISO path: $MEDIA_ISO"
  fi

  # VirtIO drivers
  if [[ ! -f "$MEDIA_DIR/virtio-win.iso" ]]; then
    step "Downloading latest Red Hat VirtIO Windows drivers..."
    "$FETCH_MEDIA_SCRIPT" virtio-win
    success "Downloaded VirtIO drivers: $MEDIA_DIR/virtio-win.iso"
  fi
  ACTIONS_PERFORMED+=("Acquired Windows media: $(basename "$MEDIA_ISO")")

elif [[ "$OS_CHOICE" = "ubuntu" ]]; then
  step "Checking/downloading Ubuntu 24.04 cloud image..."
  "$FETCH_MEDIA_SCRIPT" ubuntu "$TARGET_ARCH"
  MEDIA_ISO="$MEDIA_DIR/ubuntu-24.04-server-cloudimg-${TARGET_ARCH}.img"
  success "Cached Ubuntu cloud image: $MEDIA_ISO"
  ACTIONS_PERFORMED+=("Acquired Ubuntu 24.04 cloud image")

elif [[ "$OS_CHOICE" = "debian" ]]; then
  step "Checking/downloading Debian 12 cloud image..."
  "$FETCH_MEDIA_SCRIPT" debian "$TARGET_ARCH"
  MEDIA_ISO="$MEDIA_DIR/debian-12-genericcloud-${TARGET_ARCH}.qcow2"
  success "Cached Debian 12 cloud image: $MEDIA_ISO"
  ACTIONS_PERFORMED+=("Acquired Debian 12 cloud image")

else
  ask MEDIA_ISO "Enter path to your custom ISO or disk image"
  while [[ ! -f "$MEDIA_ISO" ]]; do
    warn "File does not exist: $MEDIA_ISO"
    ask MEDIA_ISO "Enter valid path to image"
  done
  ACTIONS_PERFORMED+=("Acquired custom media: $MEDIA_ISO")
fi

pause "Press Enter to configure hardware sizing..."

# Stage 3: Hardware Sizing
stage "Configure Hardware Sizing"
say "Configure virtual machine resources:"

ask VM_NAME "VM Name (alphanumeric, dashes)" "$VM_NAME"
ask VM_CPUS "vCPU Core Count" "$VM_CPUS"
ask VM_RAM "RAM Allocation (e.g. 4G, 8G)" "$VM_RAM"
ask VM_SIZE "Virtual Disk Size (e.g. 30G, 64G)" "$VM_SIZE"

if [[ "$OS_CHOICE" = "windows" ]]; then
  ask ADMIN_USER "Default Administrator Username" "$ADMIN_USER"
  ask ADMIN_PASS "Default Administrator Password" "$ADMIN_PASS"
fi

ACTIONS_PERFORMED+=("Allocated resources: $VM_CPUS cores, $VM_RAM RAM, $VM_SIZE disk")

# Stage 4: Installation Execution
stage "Automated Installation"
say "Everything is ready to provision '$VM_NAME'."
printf '\n    %sVM Name:%s     %s\n' "$BOLD" "$RESET" "$VM_NAME"
printf '    %sOS Media:%s    %s\n' "$BOLD" "$RESET" "$(basename "$MEDIA_ISO")"
printf '    %sAllocations:%s %s vCPUs, %s RAM, %s Disk\n\n' "$BOLD" "$RESET" "$VM_CPUS" "$VM_RAM" "$VM_SIZE"

if confirm "Start VM provisioning and automated installation now?"; then
  step "Launching installer session..."
  if [[ "$OS_CHOICE" = "windows" ]]; then
    ACTIONS_PERFORMED+=("Launched automated Windows installation")
    finish
    exec "$CREATE_WIN_SCRIPT" "$VM_NAME" \
      --iso "$MEDIA_ISO" \
      --arch "$TARGET_ARCH" \
      --accel "$WINDOWS_ACCEL" \
      --size "$VM_SIZE" \
      --memory "$VM_RAM" \
      --cpus "$VM_CPUS" \
      --username "$ADMIN_USER" \
      --password "$ADMIN_PASS"
  else
    # Linux / Custom disk clone
    "$MANAGE_VMS_SCRIPT" create "$VM_NAME" \
      --size "$VM_SIZE" \
      --arch "$TARGET_ARCH" \
      --memory "$VM_RAM" \
      --cpus "$VM_CPUS" \
      --os "$OS_CHOICE" \
      --description "Local $OS_CHOICE VM"
    ACTIONS_PERFORMED+=("Created VM '$VM_NAME' via manage-vms.sh")
    finish
  fi
else
  warn "Installation launch skipped by user."
  SKIPPED_ACTIONS+=("Installation launch postponed")
  finish
fi

exit 0
