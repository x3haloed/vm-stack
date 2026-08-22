#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGER="$SCRIPT_DIR/../../manage-vms/scripts/manage-vms.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: create-windows-from-base.sh <base-name> <vm-name> --purpose <text> --release-when <condition> [--retained] [--user <user>] [--password <pass>]" >&2
  exit 2
fi

BASE_NAME="$1"
VM_NAME="$2"
shift 2
USERNAME="admin"
PASSWORD="admin"
CREATE_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USERNAME="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    *) CREATE_ARGS+=("$1"); shift ;;
  esac
done

"$MANAGER" create-from-base "$BASE_NAME" "$VM_NAME" ${CREATE_ARGS[@]+"${CREATE_ARGS[@]}"}
"$MANAGER" start "$VM_NAME" --daemon --display none
"$MANAGER" wait-ready "$VM_NAME" --timeout 600
"$MANAGER" exec "$VM_NAME" --user "$USERNAME" --password "$PASSWORD" -- \
  "if ((Get-Content -LiteralPath 'C:\ProgramData\vm-stack\provisioned' -ErrorAction SilentlyContinue) -ne 'ok') { exit 1 }"

for attempt in 1 2 3; do
  if "$MANAGER" exec "$VM_NAME" --user "$USERNAME" --password "$PASSWORD" -- \
    "cscript.exe //Nologo 'C:\Windows\System32\slmgr.vbs' /ato 2>&1 | Tee-Object -FilePath 'C:\ProgramData\vm-stack\activation.log' -Append; \$license = Get-CimInstance SoftwareLicensingProduct | Where-Object { \$_.Name -like 'Windows*' -and \$_.PartialProductKey } | Select-Object -First 1; if (\$license.LicenseStatus -eq 1) { exit 0 }; exit 1"; then
    break
  fi
  [[ "$attempt" -lt 3 ]] && sleep 10
done
"$MANAGER" exec "$VM_NAME" --user "$USERNAME" --password "$PASSWORD" -- \
  "cscript.exe //Nologo 'C:\Windows\System32\slmgr.vbs' /xpr 2>&1 | Tee-Object -FilePath 'C:\ProgramData\vm-stack\activation.log' -Append"
echo "[INFO] Windows VM '$VM_NAME' is specialized and ready from sealed base '$BASE_NAME'."
