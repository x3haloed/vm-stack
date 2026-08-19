#!/usr/bin/env bash
# ==============================================================================
# ensure-qemu.sh (alias/wrapper to sanity-check.sh)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/sanity-check.sh" "$@"
