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
# 6. QEMU execution with native NVMe storage and HVF acceleration or opt-in TCG emulation
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
  --arch <auto|aarch64|x86_64>
                             Guest architecture [default: auto (host architecture)]
  --accel <auto|hvf|tcg>     CPU execution backend [default: auto]
                             Cross-architecture guests require explicit --accel tcg
  --size <size>              Virtual disk size [default: 64G]
  --memory <size>            RAM allocation [default: 8G]
  --cpus <n>                 CPU core count [default: 4]
  --username <user>          Admin username in Windows [default: admin]
  --password <pass>          Admin password in Windows [default: admin]
  --ssh-port <port>          Host port forwarding for SSH [default: 2222]
  --rdp-port <port>          Host port forwarding for RDP [default: 3389]
  --display <mode>           Display mode (default, cocoa, vnc, none) [default: default]
  --ready-timeout <seconds>  Wait this long for completed SSH provisioning [default: 1800]
  --no-wait                  Return after starting installation instead of verifying provisioning
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
READY_TIMEOUT=1800
WAIT_FOR_READY=1
TARGET_ARCH="auto"
ACCEL="auto"
READY_TIMEOUT_SET=0

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
    --arch)
      TARGET_ARCH="$2"
      shift 2
      ;;
    --accel)
      ACCEL="$2"
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
    --ready-timeout)
      READY_TIMEOUT="$2"
      READY_TIMEOUT_SET=1
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_READY=0
      shift
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
case "$HOST_ARCH" in
  arm64|aarch64) HOST_QEMU_ARCH="aarch64" ;;
  x86_64|amd64) HOST_QEMU_ARCH="x86_64" ;;
  *) log_error "Unsupported host architecture: $HOST_ARCH"; exit 1 ;;
esac

case "$TARGET_ARCH" in
  auto) QEMU_ARCH="$HOST_QEMU_ARCH" ;;
  arm64|aarch64) QEMU_ARCH="aarch64" ;;
  amd64|x86_64) QEMU_ARCH="x86_64" ;;
  *) log_error "--arch must be auto, aarch64, or x86_64"; exit 1 ;;
esac

case "$ACCEL" in
  auto)
    if [[ "$QEMU_ARCH" != "$HOST_QEMU_ARCH" ]]; then
      log_error "Cross-architecture Windows requires explicit --accel tcg."
      exit 1
    fi
    ACCEL="hvf"
    ;;
  hvf)
    if [[ "$QEMU_ARCH" != "$HOST_QEMU_ARCH" ]]; then
      log_error "HVF cannot execute a $QEMU_ARCH guest on a $HOST_QEMU_ARCH host; use --accel tcg."
      exit 1
    fi
    ;;
  tcg) ;;
  *) log_error "--accel must be auto, hvf, or tcg"; exit 1 ;;
esac

if [[ "$ACCEL" = "tcg" && "$QEMU_ARCH" != "$HOST_QEMU_ARCH" ]]; then
  log_warn "Using full-system $QEMU_ARCH CPU emulation on $HOST_QEMU_ARCH. Installation may take several hours."
  if [[ "$READY_TIMEOUT_SET" -eq 0 ]]; then
    READY_TIMEOUT=14400
  fi
fi

QEMU_BIN="qemu-system-${QEMU_ARCH}"
command -v "$QEMU_BIN" >/dev/null 2>&1 || { log_error "Required emulator not found: $QEMU_BIN"; exit 1; }
log_info "Host: $HOST_ARCH; guest: $QEMU_ARCH; accelerator: $ACCEL"

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
if [[ ! -f "$VIRTIO_ISO" && "$DRY_RUN" -eq 0 ]]; then
  log_info "VirtIO drivers not found in cache. Attempting download..."
  "$FETCH_MEDIA_SCRIPT" virtio-win 2>/dev/null || log_warn "Could not download virtio-win.iso (offline or unreachable). Continuing without it."
fi

OPENSSH_MSI="$MEDIA_DIR/openssh-${QEMU_ARCH}.msi"
if [[ "$DRY_RUN" -eq 0 ]]; then
  log_info "Ensuring checksum-verified Microsoft OpenSSH media is cached..."
  "$FETCH_MEDIA_SCRIPT" openssh-win "$QEMU_ARCH" >/dev/null
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
      --accel "$ACCEL" \
      --ssh-port "$SSH_PORT" \
      --rdp-port "$RDP_PORT" \
      --description "Automated Windows 11 ($QEMU_ARCH, $ACCEL) VM"
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
  # Windows unattended setup rejects ComputerName values longer than 15
  # characters. Keep short VM names readable and give truncated names a stable
  # checksum suffix so similarly prefixed VMs do not collide on the network.
  WINDOWS_HOSTNAME="$(printf '%s' "$VM_NAME" | tr '[:lower:]_' '[:upper:]-' | sed -E 's/[^A-Z0-9-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "$WINDOWS_HOSTNAME" ]]; then
    WINDOWS_HOSTNAME="WINDOWS-VM"
  elif [[ ! "$WINDOWS_HOSTNAME" =~ [A-Z] ]]; then
    WINDOWS_HOSTNAME="W-$WINDOWS_HOSTNAME"
  fi
  if [[ ${#WINDOWS_HOSTNAME} -gt 15 ]]; then
    HOSTNAME_CHECKSUM="$(printf '%s' "$VM_NAME" | cksum | awk '{printf "%04x", $1 % 65536}')"
    WINDOWS_HOSTNAME="${WINDOWS_HOSTNAME:0:10}-${HOSTNAME_CHECKSUM}"
  fi

  log_info "Generating unattended answer file ISO: $UNATTEND_ISO"
  "$GEN_UNATTEND_SCRIPT" \
    --output "$UNATTEND_ISO" \
    --arch "$([[ "$QEMU_ARCH" = "aarch64" ]] && echo "arm64" || echo "amd64")" \
    --username "$USERNAME" \
    --password "$PASSWORD" \
    --hostname "$WINDOWS_HOSTNAME" \
    --openssh-msi "$OPENSSH_MSI"
fi

# 4. Assemble QEMU Command
QEMU_CMD=(
  "$QEMU_BIN"
  -accel "$ACCEL"
  -cpu "$([[ "$ACCEL" = "hvf" ]] && echo host || echo max)"
  -smp "$CPUS"
  -m "$MEMORY"
  -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE"
  -drive if=pflash,format=raw,file="$VARS_FILE"
  -device qemu-xhci,id=xhci
  -device usb-kbd
  -device usb-tablet
  -drive file="$DISK_PATH",if=none,id=hd0,format=qcow2
  -device nvme,drive=hd0,serial=nvme0,bootindex=0
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${RDP_PORT}-:3389
)

if [[ "$QEMU_ARCH" = "aarch64" ]]; then
  QEMU_CMD+=(
    -device usb-storage,drive=unattend_iso
    -drive file="$UNATTEND_ISO",if=none,id=unattend_iso,format=raw,media=cdrom,readonly=on
    -device usb-storage,drive=win_iso,bootindex=1
    -drive file="$ISO_PATH",if=none,id=win_iso,format=raw,media=cdrom,readonly=on
  )
  QEMU_CMD+=(-device virtio-net-pci,netdev=net0)
else
  QEMU_CMD+=(
    -device usb-storage,drive=win_iso,bootindex=1
    -drive file="$ISO_PATH",if=none,id=win_iso,format=raw,media=cdrom,readonly=on
    -device usb-storage,drive=unattend_iso
    -drive file="$UNATTEND_ISO",if=none,id=unattend_iso,format=raw,media=cdrom,readonly=on
  )
  QEMU_CMD+=(-device virtio-net-pci,netdev=net0)
fi

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

if [[ "$QEMU_ARCH" = "aarch64" ]]; then
  INSTALL_MEDIA_ARGS=(
    -device usb-storage,drive=unattend_iso
    -drive "file=$UNATTEND_ISO,if=none,id=unattend_iso,format=raw,media=cdrom,readonly=on"
    -device usb-storage,drive=win_iso,bootindex=1
    -drive "file=$ISO_PATH,if=none,id=win_iso,format=raw,media=cdrom,readonly=on"
  )
else
  INSTALL_MEDIA_ARGS=(
    -device usb-storage,drive=win_iso,bootindex=1
    -drive "file=$ISO_PATH,if=none,id=win_iso,format=raw,media=cdrom,readonly=on"
    -device usb-storage,drive=unattend_iso
    -drive "file=$UNATTEND_ISO,if=none,id=unattend_iso,format=raw,media=cdrom,readonly=on"
  )
fi
if [[ -f "$VIRTIO_ISO" ]]; then
  INSTALL_MEDIA_ARGS+=(
    -device usb-storage,drive=virtio_iso
    -drive "file=$VIRTIO_ISO,if=none,id=virtio_iso,format=raw,media=cdrom,readonly=on"
  )
fi

printf -v INSTALL_EXTRA_ARGS '%q ' "${INSTALL_MEDIA_ARGS[@]}"
"$MANAGE_VMS_SCRIPT" start "$VM_NAME" \
  --daemon \
  --display "$DISPLAY_MODE" \
  --extra-args="$INSTALL_EXTRA_ARGS"

if [[ "$QEMU_ARCH" = "aarch64" ]]; then
  log_info "Watching for the Windows ARM optical-boot prompt through the VM monitor..."
  INITIAL_DISK_BYTES="$(wc -c < "$DISK_PATH" | tr -d ' ')"
  for _ in {1..120}; do
    "$MANAGE_VMS_SCRIPT" send-key "$VM_NAME" spc >/dev/null 2>&1 || true
    sleep 0.5
    CURRENT_DISK_BYTES="$(wc -c < "$DISK_PATH" | tr -d ' ')"
    if [[ "$CURRENT_DISK_BYTES" -gt "$INITIAL_DISK_BYTES" ]]; then
      log_info "Windows setup has started writing to the VM disk."
      break
    fi
  done

  CURRENT_DISK_BYTES="$(wc -c < "$DISK_PATH" | tr -d ' ')"
  if [[ "$CURRENT_DISK_BYTES" -le "$INITIAL_DISK_BYTES" ]]; then
    log_warn "Optical boot prompt was missed; invoking the ARM EFI loader from the UEFI shell."
    "$MANAGE_VMS_SCRIPT" type-text "$VM_NAME" 'FS0:\EFI\BOOT\BOOTAA64.EFI' --enter
    for _ in {1..20}; do
      "$MANAGE_VMS_SCRIPT" send-key "$VM_NAME" spc >/dev/null 2>&1 || true
      sleep 0.1
    done
  fi
fi

if [[ "$WAIT_FOR_READY" -eq 1 ]]; then
  log_info "Waiting for Windows provisioning to expose SSH (timeout: ${READY_TIMEOUT}s)..."
  if ! "$MANAGE_VMS_SCRIPT" wait-ready "$VM_NAME" --timeout "$READY_TIMEOUT"; then
    DIAGNOSTIC_FRAME="$RUN_DIR/${VM_NAME}-provisioning-timeout.ppm"
    "$MANAGE_VMS_SCRIPT" screenshot "$VM_NAME" --output "$DIAGNOSTIC_FRAME" >/dev/null 2>&1 || true
    log_error "Windows provisioning did not become ready. Guest framebuffer: $DIAGNOSTIC_FRAME"
    exit 1
  fi

  # Do not assume the OpenSSH DefaultShell registry change has taken effect for
  # the first connection. Execute a cmd-native read explicitly and retry: the
  # SSH service can briefly restart or become banner-unresponsive while Windows
  # finishes its first-login work, especially under TCG emulation.
  PROVISION_VERIFY_TIMEOUT=300
  PROVISION_VERIFY_STARTED="$(date +%s)"
  PROVISION_STATUS=""
  while (( $(date +%s) - PROVISION_VERIFY_STARTED < PROVISION_VERIFY_TIMEOUT )); do
    if PROVISION_STATUS="$("$MANAGE_VMS_SCRIPT" exec "$VM_NAME" \
      --user "$USERNAME" --password "$PASSWORD" --timeout 30 -- \
      'cmd.exe /d /s /c type C:\ProgramData\vm-stack\provisioned' 2>/dev/null)"; then
      PROVISION_STATUS="$(printf '%s' "$PROVISION_STATUS" | tr -d '\r\n ')"
      [[ "$PROVISION_STATUS" = "ok" ]] && break
    fi
    sleep 5
  done
  if [[ "$PROVISION_STATUS" != "ok" ]]; then
    log_error "Windows SSH became reachable, but the provisioning marker was not verified within $PROVISION_VERIFY_TIMEOUT seconds."
    exit 1
  fi
  log_info "Windows VM '$VM_NAME' is provisioned and ready for managed execution."
else
  log_info "Windows installation session started for '$VM_NAME'."
fi
