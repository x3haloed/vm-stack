#!/usr/bin/env bash
# Quick entrypoint for the vm-stack sanity check & setup wizard.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -t 0 || ! -t 1 ]]; then
  exec "$SCRIPT_DIR/launch-terminal.sh" "$SCRIPT_DIR/sanity-check.sh" --wizard "$@"
else
  exec "$SCRIPT_DIR/sanity-check.sh" --wizard "$@"
fi
