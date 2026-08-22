#!/usr/bin/env bash
# ==============================================================================
# sanity-check.sh
# Verifies the vm-stack environment:
# 1. Ensures ~/.config/vm-stack/ directory exists.
# 2. Ensures ~/.config/vm-stack/preferences.json exists conforming to schema.
# 3. Detects QEMU installation and target emulator binaries.
# 4. Verifies virtualization acceleration (KVM, HVF).
# 5. Provides an interactive multi-stage wizard for privileged operations.
# ==============================================================================

set -euo pipefail

# Default settings
MODE="auto"        # "auto", "install", "check", or "wizard"
FORMAT="text"      # "text" or "json"
TARGET_ARCH="auto"
QUIET=0
VERBOSE=0

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

# Print helpers for non-wizard logging
log_info() {
  if [[ "$QUIET" -eq 0 && "$FORMAT" = "text" ]]; then
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"
  fi
}

log_warn() {
  if [[ "$FORMAT" = "text" ]]; then
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2
  fi
}

log_error() {
  if [[ "$FORMAT" = "text" ]]; then
    printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2
  fi
}

log_debug() {
  if [[ "$VERBOSE" -eq 1 && "$FORMAT" = "text" ]]; then
    printf '%s[DEBUG]%s %s\n' "$DIM" "$RESET" "$1"
  fi
}

show_help() {
  cat << 'EOF'
Usage: sanity-check.sh [OPTIONS]

Sanity checks the vm-stack environment:
- Ensures ~/.config/vm-stack/ exists
- Ensures ~/.config/vm-stack/preferences.json exists (cache_os_images, defaults)
- Verifies and installs QEMU across macOS and Linux
- Verifies virtualization acceleration (KVM / HVF)
- Provides an interactive setup wizard for privileged operations

Options:
  -c, --check          Check status only without installing (Exit: 0=found, 2=missing)
  -i, --install        Check and install QEMU (non-interactive where possible)
  -w, --wizard         Launch interactive multi-stage setup wizard for privileged operations
  -t, --target <arch>  Target architecture binary to verify (e.g. x86_64, aarch64, arm, all) [default: host architecture]
  -j, --json           Output results in machine-readable JSON format
  -q, --quiet          Suppress non-essential output
  -v, --verbose        Enable detailed debug logging
  -h, --help           Show this help message

Exit codes:
  0 - Environment, preferences, and QEMU are ready
  1 - Installation failed or unsupported system
  2 - QEMU is missing (in --check mode)
  3 - Privilege escalation required (run with --wizard in an interactive terminal)
EOF
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--check)
      MODE="check"
      shift
      ;;
    -i|--install)
      MODE="install"
      shift
      ;;
    -w|--wizard)
      MODE="wizard"
      shift
      ;;
    -t|--target)
      if [[ -n "${2:-}" ]]; then
        TARGET_ARCH="$2"
        shift 2
      else
        log_error "Option --target requires an architecture argument."
        exit 1
      fi
      ;;
    -j|--json)
      FORMAT="json"
      shift
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
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

if [[ "$TARGET_ARCH" = "auto" ]]; then
  host_machine="$(uname -m 2>/dev/null || echo x86_64)"
  case "$host_machine" in
    arm64|aarch64) TARGET_ARCH="aarch64" ;;
    amd64|x86_64) TARGET_ARCH="x86_64" ;;
    *)            TARGET_ARCH="$host_machine" ;;
  esac
fi

# Expand PATH to include standard binary directories
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ──────────────────────────────────────────────────────────────────────────
# Configuration & Preferences Initialization (~/.config/vm-stack/)
# ──────────────────────────────────────────────────────────────────────────

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
PREFERENCES_FILE="$CONFIG_DIR/preferences.json"
CONFIG_DIR_READY=0
CONFIG_DIR_CREATED=0
PREFERENCES_READY=0
PREFERENCES_CREATED=0
CACHE_OS_IMAGES="true"

ensure_config_and_preferences() {
  if [[ -d "$CONFIG_DIR" ]]; then
    CONFIG_DIR_READY=1
  else
    if mkdir -p "$CONFIG_DIR" 2>/dev/null; then
      CONFIG_DIR_READY=1
      CONFIG_DIR_CREATED=1
      log_debug "Created configuration directory: $CONFIG_DIR"
    else
      CONFIG_DIR_READY=0
      log_debug "Could not create configuration directory: $CONFIG_DIR"
    fi
  fi

  if [[ -f "$PREFERENCES_FILE" ]]; then
    PREFERENCES_READY=1
    # Read cache_os_images value if available
    if command -v python3 >/dev/null 2>&1; then
      CACHE_OS_IMAGES="$(python3 -c 'import json, sys; d=json.load(open(sys.argv[1])); print("true" if d.get("cache_os_images", True) else "false")' "$PREFERENCES_FILE" 2>/dev/null || echo "true")"
    fi
  else
    if [[ "$CONFIG_DIR_READY" -eq 1 ]]; then
      local default_prefs
      default_prefs=$(cat << 'EOF'
{
  "version": 1,
  "cache_os_images": true,
  "default_arch": "auto",
  "default_memory": "4G",
  "default_cpus": 2,
  "default_accel": "auto",
  "images_dir": "",
  "cache_dir": ""
}
EOF
)
      if (printf '%s\n' "$default_prefs" > "$PREFERENCES_FILE") 2>/dev/null; then
        PREFERENCES_READY=1
        PREFERENCES_CREATED=1
        log_debug "Created default preferences file: $PREFERENCES_FILE"
      fi
    fi
  fi
}

ensure_config_and_preferences

# ──────────────────────────────────────────────────────────────────────────
# Detection Routines
# ──────────────────────────────────────────────────────────────────────────

OS_TYPE="unknown"
DISTRO="unknown"
DISTRO_VERSION=""
PKG_MGR="unknown"
PKG_MGR_REQUIRES_ROOT=1

detect_os() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo "Unknown")"
  case "$uname_s" in
    Darwin)
      OS_TYPE="macos"
      DISTRO="macos"
      DISTRO_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "")"
      if command -v brew >/dev/null 2>&1; then
        PKG_MGR="brew"
        PKG_MGR_REQUIRES_ROOT=0
      elif command -v port >/dev/null 2>&1; then
        PKG_MGR="port"
        PKG_MGR_REQUIRES_ROOT=1
      fi
      ;;
    Linux)
      OS_TYPE="linux"
      if [[ -f /etc/os-release || -f /usr/lib/os-release ]]; then
        local os_rel="/etc/os-release"
        [[ -f "$os_rel" ]] || os_rel="/usr/lib/os-release"

        local distro_id distro_like
        distro_id="$(grep '^ID=' "$os_rel" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")"
        distro_like="$(grep '^ID_LIKE=' "$os_rel" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")"
        DISTRO_VERSION="$(grep '^VERSION_ID=' "$os_rel" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")"

        case "$distro_id $distro_like" in
          *ubuntu*|*debian*|*pop*|*mint*|*kali*|*raspbian*)
            DISTRO="debian"
            PKG_MGR="apt"
            ;;
          *fedora*|*rhel*|*centos*|*rocky*|*alma*|*amzn*)
            DISTRO="fedora"
            if command -v dnf >/dev/null 2>&1; then
              PKG_MGR="dnf"
            else
              PKG_MGR="yum"
            fi
            ;;
          *arch*|*manjaro*|*endeavouros*|*artix*)
            DISTRO="arch"
            PKG_MGR="pacman"
            ;;
          *alpine*)
            DISTRO="alpine"
            PKG_MGR="apk"
            ;;
          *suse*|*opensuse*)
            DISTRO="opensuse"
            PKG_MGR="zypper"
            ;;
          *void*)
            DISTRO="void"
            PKG_MGR="xbps"
            ;;
          *gentoo*)
            DISTRO="gentoo"
            PKG_MGR="emerge"
            ;;
          *)
            DISTRO="$distro_id"
            ;;
        esac
      elif [[ -f /etc/redhat-release ]]; then
        DISTRO="fedora"
        PKG_MGR="dnf"
        command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
      elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        PKG_MGR="apt"
      elif [[ -f /etc/arch-release ]]; then
        DISTRO="arch"
        PKG_MGR="pacman"
      elif [[ -f /etc/alpine-release ]]; then
        DISTRO="alpine"
        PKG_MGR="apk"
      fi

      # Fallback package manager detection on Linux
      if [[ "$PKG_MGR" = "unknown" ]]; then
        if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt";
        elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
        elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
        elif command -v pacman >/dev/null 2>&1; then PKG_MGR="pacman";
        elif command -v apk >/dev/null 2>&1; then PKG_MGR="apk";
        elif command -v zypper >/dev/null 2>&1; then PKG_MGR="zypper";
        elif command -v nix-env >/dev/null 2>&1; then
          PKG_MGR="nix"
          PKG_MGR_REQUIRES_ROOT=0
        fi
      fi
      ;;
    *)
      OS_TYPE="unsupported"
      ;;
  esac
}

detect_os

# QEMU detection variables
QEMU_INSTALLED=0
FOUND_BINARIES=""
QEMU_VERSION=""
ACCEL_TYPE="tcg"
ACCEL_SUPPORTED=0
ACCEL_ACCESSIBLE=0
ACCEL_DETAILS=""
PRIVILEGE_REQUIRED=0

find_qemu_binaries() {
  local candidate_list="qemu-img qemu-system-x86_64 qemu-system-aarch64 qemu-system-arm qemu-system-i386 qemu-system-riscv64"
  FOUND_BINARIES=""
  for bin in $candidate_list; do
    if command -v "$bin" >/dev/null 2>&1; then
      local bin_path
      bin_path="$(command -v "$bin")"
      if [[ -z "$FOUND_BINARIES" ]]; then
        FOUND_BINARIES="$bin:$bin_path"
      else
        FOUND_BINARIES="$FOUND_BINARIES,$bin:$bin_path"
      fi
    fi
  done
}

check_qemu_installed() {
  find_qemu_binaries

  local req_bin="qemu-system-$TARGET_ARCH"
  if [[ "$TARGET_ARCH" = "all" || "$TARGET_ARCH" = "img" ]]; then
    req_bin="qemu-img"
  fi

  if command -v "$req_bin" >/dev/null 2>&1; then
    QEMU_INSTALLED=1
    QEMU_VERSION="$("$req_bin" --version 2>/dev/null | head -n 1 | sed 's/QEMU emulator version //; s/Copyright.*//' | tr -d '\n' || echo "unknown")"
  elif [[ "$TARGET_ARCH" = "all" && -n "$FOUND_BINARIES" ]]; then
    QEMU_INSTALLED=1
    local first_bin
    first_bin="$(echo "$FOUND_BINARIES" | cut -d, -f1 | cut -d: -f2)"
    QEMU_VERSION="$("$first_bin" --version 2>/dev/null | head -n 1 | sed 's/QEMU emulator version //; s/Copyright.*//' | tr -d '\n' || echo "unknown")"
  elif command -v qemu-img >/dev/null 2>&1 && [[ -n "$FOUND_BINARIES" ]]; then
    QEMU_VERSION="$(qemu-img --version 2>/dev/null | head -n 1 | sed 's/qemu-img version //; s/Copyright.*//' | tr -d '\n' || echo "unknown")"
    if [[ "$TARGET_ARCH" = "x86_64" ]] && command -v qemu-system-x86_64 >/dev/null 2>&1; then
      QEMU_INSTALLED=1
    elif [[ "$TARGET_ARCH" = "aarch64" ]] && command -v qemu-system-aarch64 >/dev/null 2>&1; then
      QEMU_INSTALLED=1
    fi
  else
    QEMU_INSTALLED=0
  fi
}

check_acceleration() {
  if [[ "$OS_TYPE" = "linux" ]]; then
    ACCEL_TYPE="kvm"
    if [[ -e /dev/kvm ]]; then
      ACCEL_SUPPORTED=1
      if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        ACCEL_ACCESSIBLE=1
        ACCEL_DETAILS="/dev/kvm is available and read/write accessible"
      else
        ACCEL_ACCESSIBLE=0
        local current_user
        current_user="$(id -un 2>/dev/null || whoami)"
        ACCEL_DETAILS="/dev/kvm exists but user '$current_user' lacks read/write permissions."
        PRIVILEGE_REQUIRED=1
      fi
    else
      ACCEL_SUPPORTED=0
      ACCEL_ACCESSIBLE=0
      ACCEL_DETAILS="/dev/kvm not found (hardware virtualization disabled in BIOS/UEFI or nested virt disabled)"
    fi
  elif [[ "$OS_TYPE" = "macos" ]]; then
    ACCEL_TYPE="hvf"
    local hv_support
    hv_support="$(sysctl -n kern.hv_support 2>/dev/null || echo "0")"
    if [[ "$hv_support" = "1" ]]; then
      ACCEL_SUPPORTED=1
      ACCEL_ACCESSIBLE=1
      ACCEL_DETAILS="macOS Hypervisor framework (HVF) supported and enabled (-accel hvf)"
    else
      ACCEL_SUPPORTED=0
      ACCEL_ACCESSIBLE=0
      ACCEL_DETAILS="Hypervisor framework not supported by this CPU or OS"
    fi
  fi

  # If QEMU is missing and package manager needs root, flag privilege required
  if [[ "$QEMU_INSTALLED" -eq 0 && "$PKG_MGR_REQUIRES_ROOT" -eq 1 ]]; then
    local current_uid
    current_uid="$(id -u 2>/dev/null || echo 1)"
    if [[ "$current_uid" -ne 0 ]]; then
      PRIVILEGE_REQUIRED=1
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Interactive Wizard Engine
# ──────────────────────────────────────────────────────────────────────────

_STAGE_INDEX=0
TOTAL_STAGES=0
ACTIONS_PERFORMED=()
SKIPPED_ACTIONS=()

_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then tput clear; else printf '\033[2J\033[3J\033[H'; fi
}

banner() {
  _clear
  printf '\n%s%s  %s%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
  printf '%s  %s stage(s)%s\n\n' "$DIM" "$TOTAL_STAGES" "$RESET"
  printf '%s  This setup wizard walks you through verifying the vm-stack environment,\n' "$DIM"
  printf '  configuration preferences, QEMU installation, and virtualization acceleration.\n'
  printf '  Privileged steps will prompt for confirmation before execution.%s\n\n' "$RESET"
  pause "Press Enter to start..."
}

stage() {
  _clear
  _STAGE_INDEX=$((_STAGE_INDEX + 1))
  printf '\n%s%s▸ Stage %s/%s · %s%s\n\n' \
    "$BOLD" "$BLUE" "$_STAGE_INDEX" "$TOTAL_STAGES" "$1" "$RESET"
}

say()  { printf '  %s\n' "$1"; }
step() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$1"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s⚠ %s%s\n' "$YELLOW" "$RESET" "$1"; }
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

finish() {
  _clear
  printf '\n%s%s  ✓ Sanity Check & Setup Complete%s\n\n' "$BOLD" "$GREEN" "$RESET"
  if [[ -n "${ACTIONS_PERFORMED[*]-}" ]]; then
    note "Actions completed:"
    for act in "${ACTIONS_PERFORMED[@]}"; do
      printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$act"
    done
    printf '\n'
  fi

  if [[ -n "${SKIPPED_ACTIONS[*]-}" ]]; then
    warn "Actions skipped or requiring manual follow-up:"
    for sk in "${SKIPPED_ACTIONS[@]}"; do
      printf '  %s-%s %s\n' "$YELLOW" "$RESET" "$sk"
    done
    printf '\n'
  fi

  # Final status summary
  printf '  %sConfig Directory:%s  %s (%s)\n' "$BOLD" "$RESET" "$CONFIG_DIR" "$([[ "$CONFIG_DIR_READY" -eq 1 ]] && echo "Ready" || echo "Not created")"
  printf '  %sPreferences File:%s  %s (%s)\n' "$BOLD" "$RESET" "$PREFERENCES_FILE" "$([[ "$PREFERENCES_READY" -eq 1 ]] && echo "Ready" || echo "Not created")"
  printf '  %sHost OS:%s           %s (%s)\n' "$BOLD" "$RESET" "$OS_TYPE" "$DISTRO"
  printf '  %sQEMU Installed:%s    %s\n' "$BOLD" "$RESET" "$([[ "$QEMU_INSTALLED" -eq 1 ]] && echo "Yes (v$QEMU_VERSION)" || echo "No")"
  printf '  %sTarget Emulator:%s   %s\n' "$BOLD" "$RESET" "$(command -v "qemu-system-$TARGET_ARCH" 2>/dev/null || echo "Not found")"
  printf '  %sAcceleration:%s      %s\n\n' "$BOLD" "$RESET" "$ACCEL_DETAILS"
}

get_install_command() {
  case "$PKG_MGR" in
    brew)   echo "brew install qemu" ;;
    port)   echo "sudo port selfupdate && sudo port install qemu" ;;
    apt)    echo "sudo apt-get update && sudo apt-get install -y qemu-system qemu-utils" ;;
    dnf)    echo "sudo dnf install -y qemu-system-x86 qemu-system-aarch64 qemu-img" ;;
    yum)    echo "sudo yum install -y qemu-kvm qemu-img" ;;
    pacman) echo "sudo pacman -Sy --noconfirm qemu-full" ;;
    apk)    echo "sudo apk add --no-cache qemu-system-x86_64 qemu-system-aarch64 qemu-img" ;;
    zypper) echo "sudo zypper --non-interactive in qemu-x86 qemu-arm qemu-tools" ;;
    xbps)   echo "sudo xbps-install -Sy qemu" ;;
    emerge) echo "sudo emerge --ask=n app-emulation/qemu" ;;
    nix)    echo "nix-env -iA nixpkgs.qemu" ;;
    *)      echo "" ;;
  esac
}

run_wizard() {
  ensure_config_and_preferences
  if [[ "$CONFIG_DIR_READY" -eq 1 ]]; then
    ACTIONS_PERFORMED+=("Initialized configuration directory ($CONFIG_DIR)")
  fi
  if [[ "$PREFERENCES_READY" -eq 1 ]]; then
    ACTIONS_PERFORMED+=("Initialized preferences ($PREFERENCES_FILE)")
  fi

  # Recalculate states
  check_qemu_installed
  check_acceleration

  # Determine stages to run
  local need_install=0
  local need_kvm_perm=0
  local need_kvm_module=0

  [[ "$QEMU_INSTALLED" -eq 0 ]] && need_install=1

  if [[ "$OS_TYPE" = "linux" ]]; then
    if [[ ! -e /dev/kvm ]]; then
      need_kvm_module=1
    elif [[ "$ACCEL_ACCESSIBLE" -eq 0 ]]; then
      need_kvm_perm=1
    fi
  fi

  TOTAL_STAGES=1 # Smoke test is always included
  [[ "$need_install" -eq 1 ]] && TOTAL_STAGES=$((TOTAL_STAGES + 1))
  [[ "$need_kvm_perm" -eq 1 || "$need_kvm_module" -eq 1 ]] && TOTAL_STAGES=$((TOTAL_STAGES + 1))

  banner "vm-stack Sanity Check & Setup Wizard"

  # Stage: Package Installation
  if [[ "$need_install" -eq 1 ]]; then
    stage "Install QEMU Packages"
    say "QEMU binaries were not detected on this system ($OS_TYPE / $DISTRO)."
    local cmd
    cmd="$(get_install_command)"

    if [[ -z "$cmd" ]]; then
      warn "No automated package manager detected. Please install QEMU manually."
      SKIPPED_ACTIONS+=("Install QEMU packages manually via package manager")
      pause
    else
      say "Recommended installation command:"
      printf '\n    %s%s%s\n\n' "$BOLD" "$cmd" "$RESET"

      if [[ "$PKG_MGR_REQUIRES_ROOT" -eq 1 ]]; then
        note "This step requires elevated privileges (sudo/root)."
      fi

      if confirm "Proceed with package installation?"; then
        step "Executing installation..."
        if eval "$cmd"; then
          success "QEMU packages installed successfully."
          ACTIONS_PERFORMED+=("Installed QEMU packages ($PKG_MGR)")
        else
          warn "Package installation encountered an error."
          SKIPPED_ACTIONS+=("Package installation failed: $cmd")
        fi
      else
        warn "Package installation skipped by user."
        SKIPPED_ACTIONS+=("Package installation skipped by user")
      fi
    fi
    # Re-evaluate
    check_qemu_installed
  fi

  # Stage: KVM Acceleration Configuration
  if [[ "$need_kvm_module" -eq 1 || "$need_kvm_perm" -eq 1 ]]; then
    stage "Configure Hardware Acceleration (KVM)"
    if [[ "$need_kvm_module" -eq 1 ]]; then
      say "The '/dev/kvm' device node was not found."
      say "Attempting to load the KVM kernel module can enable hardware virtualization."
      printf '\n    %ssudo modprobe kvm%s\n\n' "$BOLD" "$RESET"

      if confirm "Attempt to load the KVM kernel module?"; then
        if sudo modprobe kvm 2>/dev/null; then
          success "Loaded 'kvm' module."
          ACTIONS_PERFORMED+=("Loaded KVM kernel module")
          # Try CPU specific modules
          sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
        else
          warn "Could not load KVM module. Hardware virtualization might be disabled in BIOS."
          SKIPPED_ACTIONS+=("KVM module loading failed or unsupported by CPU")
        fi
      else
        SKIPPED_ACTIONS+=("Skipped KVM module loading")
      fi
    fi

    # Recheck /dev/kvm
    if [[ -e /dev/kvm && ! -w /dev/kvm ]]; then
      local user_name
      user_name="$(id -un 2>/dev/null || whoami)"
      say "User '$user_name' does not have write access to /dev/kvm."
      say "Adding '$user_name' to the 'kvm' group will grant necessary permissions."
      printf '\n    %ssudo usermod -aG kvm %s%s\n\n' "$BOLD" "$user_name" "$RESET"

      if confirm "Add '$user_name' to the 'kvm' group?"; then
        if sudo usermod -aG kvm "$user_name"; then
          success "Added user '$user_name' to group 'kvm'."
          ACTIONS_PERFORMED+=("Added user '$user_name' to 'kvm' group (requires session reload)")
          note "Tip: Run 'newgrp kvm' or log out/in to apply group membership to existing shells."
        else
          warn "Failed to add user to 'kvm' group."
          SKIPPED_ACTIONS+=("Failed to add user to kvm group")
        fi
      else
        SKIPPED_ACTIONS+=("Skipped adding user to kvm group")
      fi
    fi
    check_acceleration
  fi

  # Stage: Verification & Smoke Test
  stage "Verify QEMU Installation & Smoke Test"
  say "Verifying binary accessibility and disk image creation..."

  check_qemu_installed
  check_acceleration

  local smoke_passed=1
  if command -v qemu-img >/dev/null 2>&1; then
    step "Testing 'qemu-img' disk creation..."
    local test_img
    test_img="$(mktemp -u --tmpdir qemu_test_XXXXXX.qcow2 2>/dev/null || echo "/tmp/qemu_test_$$.qcow2")"
    if qemu-img create -f qcow2 "$test_img" 10M >/dev/null 2>&1; then
      if qemu-img info "$test_img" >/dev/null 2>&1; then
        success "qemu-img verification passed."
      else
        warn "qemu-img created image but failed to read metadata."
        smoke_passed=0
      fi
      rm -f "$test_img" 2>/dev/null || true
    else
      warn "qemu-img failed to create a test disk image."
      smoke_passed=0
    fi
  else
    warn "'qemu-img' utility is not in PATH."
    smoke_passed=0
  fi

  if command -v "qemu-system-$TARGET_ARCH" >/dev/null 2>&1; then
    local emulator_bin="qemu-system-$TARGET_ARCH"
    step "Testing '$emulator_bin --version'..."
    local ver_str
    ver_str="$("$emulator_bin" --version 2>/dev/null | head -n 1 || echo "")"
    if [[ -n "$ver_str" ]]; then
      success "$emulator_bin is operational ($ver_str)."
    else
      warn "Failed to execute $emulator_bin."
      smoke_passed=0
    fi
  else
    warn "Target emulator 'qemu-system-$TARGET_ARCH' not found in PATH."
    smoke_passed=0
  fi

  if [[ "$smoke_passed" -eq 1 ]]; then
    ACTIONS_PERFORMED+=("Verification smoke test passed")
  fi

  pause "Press Enter to view final summary..."
  finish
}

# ──────────────────────────────────────────────────────────────────────────
# Standard Execution Modes (Check / Non-interactive Install / JSON)
# ──────────────────────────────────────────────────────────────────────────

output_json() {
  local bin_json="{"
  if [[ -n "$FOUND_BINARIES" ]]; then
    local old_ifs="$IFS"
    IFS=','
    local first_item=1
    for pair in $FOUND_BINARIES; do
      local bname bpath
      bname="$(echo "$pair" | cut -d: -f1)"
      bpath="$(echo "$pair" | cut -d: -f2)"
      if [[ "$first_item" -eq 1 ]]; then
        bin_json="$bin_json\"$bname\":\"$bpath\""
        first_item=0
      else
        bin_json="$bin_json,\"$bname\":\"$bpath\""
      fi
    done
    IFS="$old_ifs"
  fi
  bin_json="$bin_json}"

  local inst_bool="false"
  [[ "$QEMU_INSTALLED" -eq 1 ]] && inst_bool="true"
  local acc_sup_bool="false"
  [[ "$ACCEL_SUPPORTED" -eq 1 ]] && acc_sup_bool="true"
  local acc_acc_bool="false"
  [[ "$ACCEL_ACCESSIBLE" -eq 1 ]] && acc_acc_bool="true"
  local priv_req_bool="false"
  [[ "$PRIVILEGE_REQUIRED" -eq 1 ]] && priv_req_bool="true"
  local cfg_ready_bool="false"
  [[ "$CONFIG_DIR_READY" -eq 1 ]] && cfg_ready_bool="true"
  local pref_ready_bool="false"
  [[ "$PREFERENCES_READY" -eq 1 ]] && pref_ready_bool="true"

  cat << EOF
{
  "config_dir": "$CONFIG_DIR",
  "config_dir_ready": $cfg_ready_bool,
  "preferences_file": "$PREFERENCES_FILE",
  "preferences_ready": $pref_ready_bool,
  "preferences": {
    "cache_os_images": $CACHE_OS_IMAGES
  },
  "installed": $inst_bool,
  "target_arch": "$TARGET_ARCH",
  "version": "$QEMU_VERSION",
  "os": "$OS_TYPE",
  "distro": "$DISTRO",
  "distro_version": "$DISTRO_VERSION",
  "package_manager": "$PKG_MGR",
  "privilege_required": $priv_req_bool,
  "wizard_recommended": $priv_req_bool,
  "wizard_command": "./scripts/sanity-check.sh --wizard",
  "binaries": $bin_json,
  "acceleration": {
    "type": "$ACCEL_TYPE",
    "supported": $acc_sup_bool,
    "accessible": $acc_acc_bool,
    "details": "$ACCEL_DETAILS"
  }
}
EOF
}

output_text() {
  log_info "Config directory: $CONFIG_DIR ($([[ "$CONFIG_DIR_READY" -eq 1 ]] && echo "ready" || echo "uninitialized"))"
  log_info "Preferences: $PREFERENCES_FILE (cache_os_images: $CACHE_OS_IMAGES)"
  if [[ "$QEMU_INSTALLED" -eq 1 ]]; then
    log_info "QEMU is installed (Version: ${QEMU_VERSION:-detected})."
    log_info "Target binary: $(command -v "qemu-system-$TARGET_ARCH" 2>/dev/null || command -v qemu-img 2>/dev/null || echo "Available")"
    if [[ "$ACCEL_SUPPORTED" -eq 1 ]]; then
      if [[ "$ACCEL_ACCESSIBLE" -eq 1 ]]; then
        log_info "Acceleration ($ACCEL_TYPE): Available and ready."
      else
        log_warn "Acceleration ($ACCEL_TYPE): Supported by CPU, but permissions or group membership needed."
        log_warn "$ACCEL_DETAILS"
        log_info "To configure interactively, run: ./scripts/sanity-check.sh --wizard"
      fi
    else
      log_warn "Acceleration ($ACCEL_TYPE): Not available ($ACCEL_DETAILS)."
    fi
  else
    log_warn "QEMU (target: $TARGET_ARCH) is not installed on this system ($OS_TYPE / $DISTRO)."
    if [[ "$PRIVILEGE_REQUIRED" -eq 1 ]]; then
      log_warn "Installation requires elevated privileges (sudo/root)."
      log_info "Run the interactive setup wizard: ./scripts/sanity-check.sh --wizard"
    fi
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run detection
check_qemu_installed
check_acceleration

# Route by MODE
if [[ "$MODE" = "wizard" ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    exec "$SCRIPT_DIR/launch-terminal.sh" "$SCRIPT_PATH" --wizard
  fi
  run_wizard
  exit 0
fi

if [[ "$MODE" = "check" ]]; then
  if [[ "$FORMAT" = "json" ]]; then
    output_json
  else
    output_text
  fi
  if [[ "$QEMU_INSTALLED" -eq 1 ]]; then
    exit 0
  else
    exit 2
  fi
fi

# Auto / Install Mode
if [[ "$QEMU_INSTALLED" -eq 0 ]]; then
  # If running in an interactive terminal and privilege escalation is required, launch wizard
  if [[ -t 0 && -t 1 && "$PRIVILEGE_REQUIRED" -eq 1 ]]; then
    run_wizard
    exit 0
  fi

  # Non-privileged installation (Homebrew / Nix)
  if [[ "$PKG_MGR_REQUIRES_ROOT" -eq 0 ]]; then
    log_info "Installing QEMU via $PKG_MGR..."
    if [[ "$PKG_MGR" = "brew" ]]; then
      brew install qemu
    elif [[ "$PKG_MGR" = "nix" ]]; then
      nix-env -iA nixpkgs.qemu
    fi
    check_qemu_installed
    check_acceleration
    if [[ "$QEMU_INSTALLED" -eq 1 ]]; then
      log_info "Successfully installed QEMU."
    else
      log_error "Installation completed but QEMU was not found in PATH."
      exit 1
    fi
  else
    # Root required
    local cur_uid
    cur_uid="$(id -u 2>/dev/null || echo 1)"
    if [[ "$cur_uid" -eq 0 ]]; then
      log_info "Running installation as root via $PKG_MGR..."
      cmd="$(get_install_command | sed 's/sudo //g')"
      eval "$cmd"
      check_qemu_installed
      check_acceleration
    else
      if [[ "$FORMAT" = "json" ]]; then
        output_json
      else
        log_error "Root privileges are required to install packages on $DISTRO via $PKG_MGR."
        log_info "Please launch the interactive setup wizard in a terminal:"
        printf '\n    %s./scripts/sanity-check.sh --wizard%s\n\n' "$BOLD" "$RESET"
      fi
      exit 3
    fi
  fi
fi

if [[ "$FORMAT" = "json" ]]; then
  output_json
else
  output_text
fi

exit 0
