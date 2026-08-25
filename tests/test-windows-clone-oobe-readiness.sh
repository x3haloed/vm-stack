#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREPARER="$REPO_ROOT/skills/create-vm/scripts/prepare-windows-base.ps1"

grep -Fq '<AutoLogon>' "$PREPARER"
grep -Fq '<LogonCount>1</LogonCount>' "$PREPARER"
grep -Fq '<FirstLogonCommands>' "$PREPARER"
grep -Fq 'Complete vm-stack clone provisioning' "$PREPARER"

if grep -Fq '<LocalAccounts>' "$PREPARER"; then
  echo 'clone unattend must not recreate the preserved local administrator' >&2
  exit 1
fi

specialize_block="$(sed -n '/<settings pass="specialize">/,/<\/settings>/p' "$PREPARER")"
if grep -Fq 'first-boot.ps1' <<<"$specialize_block"; then
  echo 'clone readiness must not be published during specialize, before interactive OOBE completes' >&2
  exit 1
fi

echo 'Windows clone readiness follows the first interactive logon without recreating the account.'
