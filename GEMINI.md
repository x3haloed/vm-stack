# GEMINI.md: Antigravity Project Instructions for vm-stack

Guidelines and operational patterns for Google Antigravity when working with `vm-stack`.

## Operational Invariants

1. **Deterministic Execution:**
   - Always route VM disk operations (create, resize, rename, clone, snapshot, delete) and process execution (start, stop, status, wait-ready, exec) through `./skills/manage-vms/scripts/manage-vms.sh`.
   - Never manipulate `.qcow2` files directly.

2. **Ephemeral Agent Testbeds:**
   - To test code inside a clean guest without mutating the base VM, start the VM with `--snapshot` or execute via `run-ephemeral`:
     ```bash
     ./skills/manage-vms/scripts/manage-vms.sh run-ephemeral <base-name> -- <command...>
     ```

3. **Desktop Wizards on User Desktop:**
   - If an interactive configuration or media download wizard is needed, spawn it via `launch-terminal.sh` so the user interacts in their native Terminal window while your tool execution completes cleanly.

4. **Programmatic State Probing:**
   - Always use `--json` flags on `./skills/manage-vms/scripts/manage-vms.sh status/list/inspect` and `./skills/sanity-check/scripts/sanity-check.sh --check` to obtain clean JSON structures.
