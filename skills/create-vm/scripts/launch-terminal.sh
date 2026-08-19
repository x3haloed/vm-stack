#!/usr/bin/env bash
# ==============================================================================
# launch-terminal.sh
# Opens a command or setup wizard in a new visible GUI terminal window
# directly on the user's desktop (Terminal.app / iTerm2 on macOS, GUI terminal on Linux).
#
# Ensures the user can interact directly with the wizard rather than
# having the agent block on background subshell input.
# ==============================================================================

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: launch-terminal.sh <script_or_command> [args...]"
  exit 1
fi

TARGET_CMD="$*"
if [[ -f "$1" ]]; then
  FIRST_ABS="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  shift
  TARGET_CMD="$FIRST_ABS $*"
fi

UNAME_S="$(uname -s 2>/dev/null || echo "Darwin")"

if [[ "$UNAME_S" = "Darwin" ]]; then
  # Format command for macOS AppleScript execution
  ESCAPED_CMD=$(printf '%s' "cd \"$PWD\" && $TARGET_CMD; echo; read -n 1 -s -r -p 'Press any key to close this terminal...'" | sed 's/\\/\\\\/g; s/"/\\"/g')

  if pgrep -x "iTerm2" >/dev/null 2>&1; then
    osascript << EOF >/dev/null 2>&1 || osascript -e "tell application \"Terminal\" to do script \"$ESCAPED_CMD\"" -e "tell application \"Terminal\" to activate"
tell application "iTerm2"
  create window with default profile command "bash -c \"$ESCAPED_CMD\""
  activate
end tell
EOF
  else
    osascript -e "tell application \"Terminal\" to do script \"$ESCAPED_CMD\"" \
              -e "tell application \"Terminal\" to activate" >/dev/null 2>&1
  fi
  printf '[INFO] Launched wizard in a new desktop Terminal window for the user.\n'
elif [[ "$UNAME_S" = "Linux" ]]; then
  if command -v x-terminal-emulator >/dev/null 2>&1; then
    x-terminal-emulator -e bash -c "cd \"$PWD\" && $TARGET_CMD; echo; read -n 1 -s -r -p 'Press any key to close...'" &
  elif command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal -- bash -c "cd \"$PWD\" && $TARGET_CMD; echo; read -n 1 -s -r -p 'Press any key to close...'" &
  elif command -v konsole >/dev/null 2>&1; then
    konsole -e bash -c "cd \"$PWD\" && $TARGET_CMD; echo; read -n 1 -s -r -p 'Press any key to close...'" &
  elif command -v xterm >/dev/null 2>&1; then
    xterm -e bash -c "cd \"$PWD\" && $TARGET_CMD; echo; read -n 1 -s -r -p 'Press any key to close...'" &
  fi
  printf '[INFO] Launched wizard in a new desktop terminal window for the user.\n'
fi
