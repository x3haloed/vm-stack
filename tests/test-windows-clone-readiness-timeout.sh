#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLONER="$REPO_ROOT/skills/create-vm/scripts/create-windows-from-base.sh"

bash -n "$CLONER"
grep -Fq 'READY_TIMEOUT=600' "$CLONER"
grep -Fq 'json.load(sys.stdin)["accel"]' "$CLONER"
grep -Fq 'READY_TIMEOUT=14400' "$CLONER"
grep -Fq 'wait-ready "$VM_NAME" --timeout "$READY_TIMEOUT"' "$CLONER"

echo "Windows clone readiness timeout checks passed."
