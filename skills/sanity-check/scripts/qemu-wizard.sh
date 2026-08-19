#!/usr/bin/env bash
# ==============================================================================
# qemu-wizard.sh (Interactive setup wizard for sanity-check)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/sanity-check.sh" --wizard "$@"
