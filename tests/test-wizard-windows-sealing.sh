#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIZARD="$REPO_ROOT/skills/create-vm/scripts/create-vm-wizard.sh"
SEALER="$REPO_ROOT/skills/create-vm/scripts/seal-windows-base.sh"

bash -n "$WIZARD" "$SEALER"

if grep -Fq 'exec "$CREATE_WIN_SCRIPT"' "$WIZARD"; then
  echo "the wizard must regain control after Windows provisioning" >&2
  exit 1
fi

create_line="$(grep -nF '"$CREATE_WIN_SCRIPT" "$VM_NAME"' "$WIZARD" | tail -n 1 | cut -d: -f1)"
offer_line="$(grep -nF 'confirm_optional "Seal this fresh VM as a reusable thin-clone base?"' "$WIZARD" | cut -d: -f1)"
seal_line="$(grep -nF '"$SEAL_WIN_SCRIPT" "$VM_NAME" "$SEALED_BASE_NAME"' "$WIZARD" | cut -d: -f1)"
finish_line="$(awk -v start="$seal_line" 'NR > start && /    finish/ { print NR; exit }' "$WIZARD")"

[[ "$create_line" -lt "$offer_line" ]]
[[ "$offer_line" -lt "$seal_line" ]]
[[ "$seal_line" -lt "$finish_line" ]]

grep -Fq 'INSPECT_TIMEOUT=600' "$SEALER"
grep -Fq 'GENERALIZE_TIMEOUT=600' "$SEALER"
grep -Fq 'SHUTDOWN_TIMEOUT=14400' "$SEALER"
grep -Fq 'status_json="$("$MANAGER" status "$VM_NAME" --json)"' "$SEALER"
grep -Fq '0 if not json.load(sys.stdin)["runtime"]["is_running"] else 1' "$SEALER"

echo "Wizard post-provision sealing flow checks passed."
