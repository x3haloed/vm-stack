#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$REPO_ROOT/skills/manage-vms/scripts/manage-vms.sh"

bash -n "$MANAGER"

timeout_calls="$(grep -Fc 'subprocess.run(full, timeout=timeout_sec)' "$MANAGER")"
timeout_handlers="$(grep -Fc 'except subprocess.TimeoutExpired:' "$MANAGER")"

[[ "$timeout_calls" -eq 2 ]]
[[ "$timeout_handlers" -ge 2 ]]

echo "Manager sshpass timeout checks passed."
