#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER="$SCRIPT_DIR/../../manage-vms/scripts/manage-vms.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: seal-windows-base.sh <vm-name> <base-name> [--user <user>] [--password <pass>] [--allow-expiring-base]" >&2
  exit 2
fi

VM_NAME="$1"
BASE_NAME="$2"
shift 2
USERNAME="admin"
PASSWORD="admin"
ALLOW_EXPIRING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USERNAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --allow-expiring-base) ALLOW_EXPIRING=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

WORK_DIR="$(mktemp -d -t vm_stack_seal_XXXXXX)"
REMOTE_SCRIPT='C:/ProgramData/vm-stack/prepare-windows-base.ps1'
REMOTE_LICENSE='C:/ProgramData/vm-stack/base-license.json'
LOCAL_LICENSE="$WORK_DIR/base-license.json"
INSPECT_TIMEOUT=600
GENERALIZE_TIMEOUT=600
# Cross-architecture Windows Sysprep can spend hours generalizing under TCG.
# This is a maximum wait only; native guests still proceed as soon as QEMU exits.
SHUTDOWN_TIMEOUT=14400

"$MANAGER" copy-to "$VM_NAME" "$SCRIPT_DIR/prepare-windows-base.ps1" "$REMOTE_SCRIPT" --user "$USERNAME" --password "$PASSWORD"
"$MANAGER" exec "$VM_NAME" --user "$USERNAME" --password "$PASSWORD" --timeout "$INSPECT_TIMEOUT" -- \
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\vm-stack\prepare-windows-base.ps1 -Username '$USERNAME' -Password '$PASSWORD' -InspectOnly"
"$MANAGER" copy-from "$VM_NAME" "$REMOTE_LICENSE" "$LOCAL_LICENSE" --user "$USERNAME" --password "$PASSWORD"

if [[ "$ALLOW_EXPIRING" -eq 0 ]] && /usr/bin/python3 - "$LOCAL_LICENSE" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as handle:
    raise SystemExit(0 if json.load(handle).get("evaluation") else 1)
PY
then
  echo "[ERROR] Refusing to seal Evaluation media without --allow-expiring-base." >&2
  exit 1
fi

echo "[INFO] Generalizing '$VM_NAME'; the SSH session may close while Windows shuts down."
"$MANAGER" exec "$VM_NAME" --user "$USERNAME" --password "$PASSWORD" --timeout "$GENERALIZE_TIMEOUT" -- \
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\vm-stack\prepare-windows-base.ps1 -Username '$USERNAME' -Password '$PASSWORD'" || true

for _ in $(seq 1 $((SHUTDOWN_TIMEOUT / 2))); do
  if status_json="$("$MANAGER" status "$VM_NAME" --json)"; then
    if printf '%s\n' "$status_json" | /usr/bin/python3 -c 'import json,sys; raise SystemExit(0 if not json.load(sys.stdin)["runtime"]["is_running"] else 1)'; then
      args=("$VM_NAME" "$BASE_NAME" --license-json "$LOCAL_LICENSE")
      [[ "$ALLOW_EXPIRING" -eq 1 ]] && args+=(--allow-expiring-base)
      "$MANAGER" seal-base "${args[@]}"
      exit 0
    fi
  fi
  sleep 2
done

echo "[ERROR] Timed out after ${SHUTDOWN_TIMEOUT}s waiting for Sysprep to shut down '$VM_NAME'." >&2
exit 1
