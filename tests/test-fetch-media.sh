#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FETCH_MEDIA="$REPO_ROOT/skills/create-vm/scripts/fetch-media.sh"
TEST_DIR="$(mktemp -d -t vm-stack-media-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

export XDG_CONFIG_HOME="$TEST_DIR/config"
MEDIA_DIR="$XDG_CONFIG_HOME/vm-stack/media"
mkdir -p "$MEDIA_DIR"
touch "$MEDIA_DIR/win11-x64-tcg_unattend.iso" "$MEDIA_DIR/virtio-win.iso"

if "$FETCH_MEDIA" find-windows x86_64 >"$TEST_DIR/stdout" 2>"$TEST_DIR/stderr"; then
  echo "generated support ISOs must not be discovered as Windows installation media" >&2
  exit 1
fi
[[ ! -s "$TEST_DIR/stdout" ]]

WINDOWS_SOURCE="$TEST_DIR/Win11_25H2_English_x64.iso"
WINDOWS_ISO="$MEDIA_DIR/Win11_25H2_English_x64.iso"
touch "$WINDOWS_SOURCE"
ln -s "$WINDOWS_SOURCE" "$WINDOWS_ISO"
DISCOVERED="$($FETCH_MEDIA find-windows x86_64 2>"$TEST_DIR/stderr")"
[[ "$DISCOVERED" = "$WINDOWS_ISO" ]]
grep -q "Found Windows ISO: $WINDOWS_ISO" "$TEST_DIR/stderr"

echo "Windows media discovery checks passed."
