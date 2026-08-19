#!/usr/bin/env bash
# ==============================================================================
# create-windows-vm.sh
# Automated Windows 11/10 VM creation and unattended provisioning in vm-stack.
#
# Handles:
# 1. Host architecture detection (Apple Silicon aarch64 vs Intel x86_64)
# 2. ISO and VirtIO media validation (~/.config/vm-stack/media/)
# 3. Authoritative VM allocation via manage-vms.sh
# 4. UEFI firmware & per-VM NVRAM variable setup
# 5. autounattend.xml ISO generation (TPM/SecureBoot bypass, local admin user, SSH)
# 6. QEMU execution with native NVMe storage and HVF acceleration
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MANAGE_VMS_SCRIPT="$REPO_DIR/skills/manage-vms/scripts/manage-vms.sh"
FETCH_MEDIA_SCRIPT="$SCRIPT_DIR/fetch-media.sh"
GEN_UNATTEND_SCRIPT="$SCRIPT_DIR/generate-unattend.sh"

# Expand PATH
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
MEDIA_DIR="$CONFIG_DIR/media"
IMAGES_DIR="$CONFIG_DIR/images"
RUN_DIR="$CONFIG_DIR/run"

log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} create-windows-vm.sh <name> [options]

Provisions an automated Windows VM on macOS.

${BOLD}Options:${RESET}
  --iso <path>               Path to Windows ISO (if omitted, searches ~/.config/vm-stack/media/)
  --size <size>              Virtual disk size [default: 64G]
  --memory <size>            RAM allocation [default: 8G]
  --cpus <n>                 CPU core count [default: 4]
  --username <user>          Admin username in Windows [default: admin]
  --password <pass>          Admin password in Windows [default: admin]
  --ssh-port <port>          Host port forwarding for SSH [default: 2222]
  --rdp-port <port>          Host port forwarding for RDP [default: 3389]
  --display <mode>           Display mode (default, cocoa, vnc, none) [default: default]
  --dry-run                  Print generated QEMU command without executing
  -h, --help                 Show this help message
EOF
}

# Parameter Defaults
VM_NAME=""
ISO_PATH=""
DISK_SIZE="64G"
MEMORY="8G"
CPUS="4"
USERNAME="admin"
PASSWORD="admin"
SSH_PORT="2222"
RDP_PORT="3389"
DISPLAY_MODE="default"
DRY_RUN=0

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

VM_NAME="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)
      ISO_PATH="$2"
      shift 2
      ;;
    --size)
      DISK_SIZE="$2"
      shift 2
      ;;
    --memory)
      MEMORY="$2"
      shift 2
      ;;
    --cpus)
      CPUS="$2"
      shift 2
      ;;
    --username)
      USERNAME="$2"
      shift 2
      ;;
    --password)
      PASSWORD="$2"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="$2"
      shift 2
      ;;
    --rdp-port)
      RDP_PORT="$2"
      shift 2
      ;;
    --display)
      DISPLAY_MODE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

# Architecture detection
HOST_ARCH="$(uname -m 2>/dev/null || echo "arm64")"
QEMU_ARCH="aarch64"
QEMU_BIN="qemu-system-aarch64"

if [[ "$HOST_ARCH" = "x86_64" || "$HOST_ARCH" = "amd64" ]]; then
  QEMU_ARCH="x86_64"
  QEMU_BIN="qemu-system-x86_64"
fi

log_info "Targeting host architecture: $HOST_ARCH ($QEMU_ARCH)"

# Locate firmware files
EDK2_CODE=""
EDK2_VARS_TEMPLATE=""

if [[ "$QEMU_ARCH" = "aarch64" ]]; then
  for p in /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu; do
    if [[ -f "$p/edk2-aarch64-code.fd" && -f "$p/edk2-arm-vars.fd" ]]; then
      EDK2_CODE="$p/edk2-aarch64-code.fd"
      EDK2_VARS_TEMPLATE="$p/edk2-arm-vars.fd"
      break
    fi
  done
else
  for p in /opt/homebrew/share/qemu /usr/local/share/qemu /usr/share/qemu; do
    if [[ -f "$p/edk2-x86_64-code.fd" && -f "$p/edk2-i386-vars.fd" ]]; then
      EDK2_CODE="$p/edk2-x86_64-code.fd"
      EDK2_VARS_TEMPLATE="$p/edk2-i386-vars.fd"
      break
    fi
  done
fi

if [[ -z "$EDK2_CODE" ]]; then
  log_error "UEFI firmware (EDK2) not found in QEMU share directories."
  log_info "Please ensure QEMU is installed via Homebrew: brew install qemu"
  exit 1
fi

# Locate Windows ISO
if [[ -z "$ISO_PATH" ]]; then
  if ! ISO_PATH="$("$FETCH_MEDIA_SCRIPT" find-windows "$QEMU_ARCH" 2>/dev/null)"; then
    log_error "No Windows ISO found in $MEDIA_DIR."
    log_info "Please place a Windows ISO in $MEDIA_DIR/ or pass --iso <path>."
    log_info "To open the interactive media setup wizard, run: ./skills/create-vm/scripts/create-vm-wizard.sh"
    exit 1
  fi
fi

if [[ ! -f "$ISO_PATH" ]]; then
  log_error "Specified ISO file does not exist: $ISO_PATH"
  exit 1
fi

ISO_PATH="$(cd "$(dirname "$ISO_PATH")" && pwd)/$(basename "$ISO_PATH")"
log_info "Using Windows Installation ISO: $ISO_PATH"

# Ensure VirtIO drivers ISO is present
VIRTIO_ISO="$MEDIA_DIR/virtio-win.iso"
if [[ ! -f "$VIRTIO_ISO" ]]; then
  log_info "VirtIO drivers not found in cache. Attempting download..."
  "$FETCH_MEDIA_SCRIPT" virtio-win 2>/dev/null || log_warn "Could not download virtio-win.iso (offline or unreachable). Continuing without it."
fi

# 1. Authoritatively create the VM via manage-vms.sh
log_info "Creating and registering VM '$VM_NAME' in vm-stack registry..."
mkdir -p "$IMAGES_DIR" "$MEDIA_DIR"
DISK_PATH="$IMAGES_DIR/${VM_NAME}.qcow2"

if [[ "$DRY_RUN" -eq 0 ]]; then
  if "$MANAGE_VMS_SCRIPT" exists "$VM_NAME"; then
    log_warn "VM '$VM_NAME' already exists in registry. Reusing existing entry."
  else
    "$MANAGE_VMS_SCRIPT" create "$VM_NAME" \
      --size "$DISK_SIZE" \
      --format qcow2 \
      --disk "$DISK_PATH" \
      --arch "$QEMU_ARCH" \
      --memory "$MEMORY" \
      --cpus "$CPUS" \
      --os windows \
      --accel hvf \
      --ssh-port "$SSH_PORT" \
      --rdp-port "$RDP_PORT" \
      --description "Automated Windows 11 ($QEMU_ARCH) VM"
  fi
fi

# 2. Setup Per-VM NVRAM Variables
VARS_FILE="$IMAGES_DIR/${VM_NAME}_vars.fd"
if [[ ! -f "$VARS_FILE" && "$DRY_RUN" -eq 0 ]]; then
  log_info "Initializing UEFI NVRAM vars: $VARS_FILE"
  cp "$EDK2_VARS_TEMPLATE" "$VARS_FILE"
fi

# 3. Generate Unattended Setup ISO
UNATTEND_ISO="$MEDIA_DIR/${VM_NAME}_unattend.iso"
if [[ "$DRY_RUN" -eq 0 ]]; then
  log_info "Generating unattended answer file ISO: $UNATTEND_ISO"
  "$GEN_UNATTEND_SCRIPT" \
    --output "$UNATTEND_ISO" \
    --arch "$([[ "$QEMU_ARCH" = "aarch64" ]] && echo "arm64" || echo "amd64")" \
    --username "$USERNAME" \
    --password "$PASSWORD" \
    --hostname "WIN-${VM_NAME}"
fi

# 4. Assemble QEMU Command
QEMU_CMD=(
  "$QEMU_BIN"
  -accel hvf
  -cpu host
  -smp "$CPUS"
  -m "$MEMORY"
  -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE"
  -drive if=pflash,format=raw,file="$VARS_FILE"
  -device qemu-xhci,id=xhci
  -device usb-kbd
  -device usb-tablet
  -drive file="$DISK_PATH",if=none,id=hd0,format=qcow2
  -device nvme,drive=hd0,serial=nvme0,bootindex=0
  -device usb-storage,drive=win_iso,bootindex=1
  -drive file="$ISO_PATH",if=none,id=win_iso,format=raw,media=cdrom,readonly=on
  -device usb-storage,drive=unattend_iso
  -drive file="$UNATTEND_ISO",if=none,id=unattend_iso,format=raw,media=cdrom,readonly=on
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${RDP_PORT}-:3389
  -device virtio-net-pci,netdev=net0
)

if [[ -f "$VIRTIO_ISO" ]]; then
  QEMU_CMD+=(
    -device usb-storage,drive=virtio_iso
    -drive file="$VIRTIO_ISO",if=none,id=virtio_iso,format=raw,media=cdrom,readonly=on
  )
fi

if [[ "$QEMU_ARCH" = "aarch64" ]]; then
  QEMU_CMD+=(-M virt,highmem=on -device ramfb)
else
  QEMU_CMD+=(-M q35,smm=on -device virtio-vga)
fi

if [[ "$DISPLAY_MODE" = "none" ]]; then
  QEMU_CMD+=(-display none)
elif [[ "$DISPLAY_MODE" = "vnc" ]]; then
  QEMU_CMD+=(-display none -vnc :0)
else
  QEMU_CMD+=(-display default,show-cursor=on)
fi

log_info "Generated QEMU launch command:"
printf '\n    %s%s%s\n\n' "$BOLD" "${QEMU_CMD[*]}" "$RESET"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_info "Dry-run complete."
  exit 0
fi

log_info "Starting QEMU Windows installation..."
log_info "Port Forwarding: Host :$SSH_PORT -> Guest :22 (SSH), Host :$RDP_PORT -> Guest :3389 (RDP)"
log_info "Default Credentials: Username='$USERNAME', Password='$PASSWORD'"

mkdir -p "$RUN_DIR"
PID_FILE="$RUN_DIR/${VM_NAME}.pid"

# Execute QEMU with PID tracking
"${QEMU_CMD[@]}" &
QEMU_PID=$!
echo "$QEMU_PID" > "$PID_FILE"

cleanup_pid() {
  rm -f "$PID_FILE" 2>/dev/null || true
}
trap cleanup_pid EXIT INT TERM

wait "$QEMU_PID" || true
cleanup_pid
log_info "Windows installation session finished for '$VM_NAME'."
