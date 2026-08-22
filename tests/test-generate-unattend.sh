#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="$REPO_ROOT/skills/create-vm/scripts/generate-unattend.sh"
TEST_DIR="$(mktemp -d -t vm-stack-unattend-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

VALID_XML="$TEST_DIR/valid.xml"
"$GENERATOR" --arch amd64 --hostname WIN11-X64-TCG --xml-only "$VALID_XML" >/dev/null
grep -q '<ComputerName>WIN11-X64-TCG</ComputerName>' "$VALID_XML"

if "$GENERATOR" --hostname WIN-win11-x64-tcg --xml-only "$TEST_DIR/invalid.xml" >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo "expected an overlong Windows hostname to be rejected" >&2
  exit 1
fi
grep -q 'Use 2-15 letters' "$TEST_DIR/stderr"

echo "Windows unattended hostname checks passed."
