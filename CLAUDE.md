# CLAUDE.md: Claude Code Workspace Guidelines for vm-stack

This repository provides skills and scripts for managing local QEMU virtual machines on macOS, Linux, and Windows.

## Operational Rules for Claude Code

1. **Routing:** Always route VM creation, deletion, resizing, starting, stopping, and query operations through `./skills/manage-vms/scripts/manage-vms.sh`.
2. **Ephemeral Testbeds:** Use `manage-vms.sh start <name> --snapshot` or `manage-vms.sh run-ephemeral <base> -- <command...>` for isolated testbeds. All writes are discarded on VM termination.
3. **Guest Command Execution:**
   - Wait for SSH readiness: `./skills/manage-vms/scripts/manage-vms.sh wait-ready <name>`
   - Run commands: `./skills/manage-vms/scripts/manage-vms.sh exec <name> -- <command...>`
   - Transfer files: `./skills/manage-vms/scripts/manage-vms.sh copy-to <name> <src> <dest>`
4. **Desktop Wizards:** Never run interactive wizards (`create-vm-wizard.sh` or `sanity-check.sh --wizard`) in tool subshells. Always launch them on the user's desktop with `./skills/create-vm/scripts/launch-terminal.sh <script>`.
5. **Output Format:** Prefer `--json` flags when querying machine state for programmatic parsing.
