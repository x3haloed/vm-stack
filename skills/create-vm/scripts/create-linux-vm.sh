#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER="$SCRIPT_DIR/../../manage-vms/scripts/manage-vms.sh"
FETCH_MEDIA="$SCRIPT_DIR/fetch-media.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
IMAGES_DIR="$CONFIG_DIR/images"

usage() {
  cat <<'EOF'
Usage: create-linux-vm.sh <name> --os <ubuntu|debian> --purpose <text> --release-when <condition> [options]

Options:
  --arch <aarch64|x86_64>  Guest architecture [default: host architecture]
  --size <size>            Virtual disk size [default: 20G]
  --memory <size>          RAM [default: 2G]
  --cpus <count>           vCPUs [default: 2]
  --ssh-port <port>        Host SSH port [default: 2222]
  --user <name>            Guest user [default: ubuntu or debian]
  --ssh-key <public-key>   Existing public key; otherwise a VM-scoped key is generated
  --package <name>         Cloud-init package to install (repeatable)
  --gui                    Install a minimal desktop environment
  --retained               Retain the VM after its purpose is complete
  --no-start               Create without booting or waiting for SSH
EOF
}

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo aarch64 ;;
    x86_64|amd64) echo x86_64 ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; return 1 ;;
  esac
}

NAME="${1:-}"
[[ -n "$NAME" && "$NAME" != -* ]] || { usage >&2; exit 1; }
[[ "$NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "VM name may contain only letters, numbers, dashes, and underscores" >&2; exit 1; }
shift
OS=""; ARCH="$(host_arch)"; SIZE=20G; MEMORY=2G; CPUS=2; SSH_PORT=2222
USER_NAME=""; PUBLIC_KEY=""; PURPOSE=""; RELEASE_WHEN=""; GUI=0; RETAINED=0; START=1
PACKAGES=(); PACKAGE_COUNT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --cpus) CPUS="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --ssh-key) PUBLIC_KEY="$2"; shift 2 ;;
    --purpose) PURPOSE="$2"; shift 2 ;;
    --release-when) RELEASE_WHEN="$2"; shift 2 ;;
    --package) PACKAGES+=("$2"); PACKAGE_COUNT=$((PACKAGE_COUNT + 1)); shift 2 ;;
    --gui) GUI=1; shift ;;
    --retained) RETAINED=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$OS" in
  ubuntu) USER_NAME="${USER_NAME:-ubuntu}"; MEDIA="$CONFIG_DIR/media/ubuntu-24.04-server-cloudimg-${ARCH}.img" ;;
  debian) USER_NAME="${USER_NAME:-debian}"; MEDIA="$CONFIG_DIR/media/debian-12-genericcloud-${ARCH}.qcow2" ;;
  *) echo "--os must be ubuntu or debian" >&2; exit 1 ;;
esac
[[ -n "$PURPOSE" && -n "$RELEASE_WHEN" ]] || { echo "--purpose and --release-when are required" >&2; exit 1; }
[[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Invalid Linux username: $USER_NAME" >&2; exit 1; }
if [[ "$PACKAGE_COUNT" -gt 0 ]]; then
  for package in "${PACKAGES[@]}"; do
    [[ "$package" =~ ^[a-zA-Z0-9.+:-]+$ ]] || { echo "Invalid package name: $package" >&2; exit 1; }
  done
fi

mkdir -p "$IMAGES_DIR"
KEY_PATH="$IMAGES_DIR/${NAME}_id_ed25519"
SEED_DIR="$(mktemp -d)"
SEED_ISO="$IMAGES_DIR/${NAME}-cloud-init.iso"
GENERATED_KEY=0
REGISTERED=0
cleanup() {
  rm -rf "$SEED_DIR"
  if [[ "$REGISTERED" -eq 0 ]]; then
    rm -f "$SEED_ISO"
    [[ "$GENERATED_KEY" -eq 0 ]] || rm -f "$KEY_PATH" "$KEY_PATH.pub"
  fi
}
trap cleanup EXIT

if [[ -n "$PUBLIC_KEY" ]]; then
  [[ -f "$PUBLIC_KEY" ]] || { echo "Public key not found: $PUBLIC_KEY" >&2; exit 1; }
  AUTHORIZED_KEY="$(cat "$PUBLIC_KEY")"
  KEY_ARGS=()
else
  command -v ssh-keygen >/dev/null || { echo "ssh-keygen is required" >&2; exit 1; }
  [[ ! -e "$KEY_PATH" && ! -e "$KEY_PATH.pub" ]] || { echo "VM key already exists: $KEY_PATH" >&2; exit 1; }
  ssh-keygen -q -t ed25519 -N '' -C "vm-stack:${NAME}" -f "$KEY_PATH"
  GENERATED_KEY=1
  AUTHORIZED_KEY="$(cat "$KEY_PATH.pub")"
  KEY_ARGS=(--auxiliary-file "$KEY_PATH" --auxiliary-file "$KEY_PATH.pub")
fi

cat >"$SEED_DIR/meta-data" <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF
{
  printf '#cloud-config\nusers:\n  - name: %s\n    groups: [sudo]\n    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - %s\n' "$USER_NAME" "$AUTHORIZED_KEY"
  printf 'ssh_pwauth: false\ndisable_root: true\npackage_update: true\n'
  if [[ "$PACKAGE_COUNT" -gt 0 || "$GUI" -eq 1 ]]; then
    printf 'packages:\n'
    if [[ "$PACKAGE_COUNT" -gt 0 ]]; then
      for package in "${PACKAGES[@]}"; do printf '  - %s\n' "$package"; done
    fi
    if [[ "$GUI" -eq 1 ]]; then
      [[ "$OS" = ubuntu ]] && printf '  - ubuntu-desktop-minimal\n' || printf '  - task-gnome-desktop\n'
    fi
  fi
  printf 'runcmd:\n  - [systemctl, enable, --now, ssh]\n'
} >"$SEED_DIR/user-data"

if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "$SEED_ISO" "$SEED_DIR/user-data" "$SEED_DIR/meta-data"
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null 2>&1
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR/user-data" "$SEED_DIR/meta-data" >/dev/null
elif command -v hdiutil >/dev/null 2>&1; then
  hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED_ISO" "$SEED_DIR" >/dev/null
else
  echo "Creating cloud-init media requires cloud-localds, xorriso, genisoimage, or hdiutil." >&2
  exit 1
fi

"$FETCH_MEDIA" "$OS" "$ARCH"
RETAIN_ARGS=(); [[ "$RETAINED" -eq 1 ]] && RETAIN_ARGS=(--retained)
EXTRA_ARGS="-drive file=${SEED_ISO},format=raw,if=virtio,readonly=on"

if ! "$MANAGER" create "$NAME" --size "$SIZE" --backing-file "$MEDIA" --arch "$ARCH" \
  --memory "$MEMORY" --cpus "$CPUS" --os "$OS" --ssh-port "$SSH_PORT" \
  --description "$PURPOSE" --purpose "$PURPOSE" --release-when "$RELEASE_WHEN" \
  --extra-args "$EXTRA_ARGS" --auxiliary-file "$SEED_ISO" \
  ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} ${RETAIN_ARGS[@]+"${RETAIN_ARGS[@]}"}; then
  rm -f "$SEED_ISO"
  [[ -z "$PUBLIC_KEY" ]] && rm -f "$KEY_PATH" "$KEY_PATH.pub"
  exit 1
fi
REGISTERED=1

if [[ "$START" -eq 1 ]]; then
  "$MANAGER" start "$NAME" --daemon --display none
  "$MANAGER" wait-ready "$NAME"
  if [[ -z "$PUBLIC_KEY" ]]; then
    "$MANAGER" exec "$NAME" --user "$USER_NAME" --key "$KEY_PATH" --timeout 600 -- "cloud-init status --wait"
  else
    printf '[WARN] SSH is reachable, but full cloud-init completion was not checked because only a public key was supplied.\n' >&2
  fi
  printf '[INFO] Linux VM ready. Use: %q exec %q --user %q' "$MANAGER" "$NAME" "$USER_NAME"
  [[ -z "$PUBLIC_KEY" ]] && printf ' --key %q' "$KEY_PATH"
  printf ' -- <command>\n'
fi
