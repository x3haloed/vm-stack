#!/usr/bin/env bash
# ==============================================================================
# qemu-wizard.sh
# Interactive setup wizard for QEMU and virtualization configuration.
# Walks through package installation (including elevated/sudo commands),
# hardware acceleration permissions, and verification smoke testing.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ensure-qemu.sh" --wizard "$@"
