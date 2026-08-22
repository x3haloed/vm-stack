#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATOR="$REPO_ROOT/skills/create-vm/scripts/create-windows-vm.sh"

grep -Fq "'cmd.exe /d /s /c type C:\ProgramData\vm-stack\provisioned'" "$CREATOR"
grep -Fq 'PROVISION_VERIFY_TIMEOUT=300' "$CREATOR"
grep -Fq -- '--password "$PASSWORD" --timeout 30 --' "$CREATOR"

if grep -Fq 'Get-Content -LiteralPath C:\ProgramData\vm-stack\provisioned' "$CREATOR"; then
  echo "readiness verification must not depend on the configured SSH default shell" >&2
  exit 1
fi

echo "Windows readiness verification checks passed."
