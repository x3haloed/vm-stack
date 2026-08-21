# AGENTS.md: Universal AI Agent Guidelines for vm-stack

`vm-stack` is a multi-platform skill stack that enables AI coding assistants and humans to provision, manage, and execute commands inside local virtual machines (Windows, Linux, Custom OS) with zero state drift and zero-touch automation.

---

## 1. Architecture & Single Source of Truth

- **Authoritative Registry (`~/.config/vm-stack/vms.json`):**
  Defines registered virtual machines, their target architecture, allocated CPUs, memory, disk location, acceleration framework, and port forwardings.
- **Dynamic Probing:**
  Actual disk size, format, snapshots, process liveness (PID), and SSH listening status are dynamically probed on the fly by `manage-vms.sh`.
- **Golden Rule:**
  **Always route VM operations through `./skills/manage-vms/scripts/manage-vms.sh`.**
  Never manipulate raw `.qcow2` disk files or QEMU processes directly.

---

## 2. Zero-Touch Ephemeral Testbeds

For running tests, builds, or executing untrusted code in an isolated guest environment:

1. **Single-Command Ephemeral Execution:**
   ```bash
   ./skills/manage-vms/scripts/manage-vms.sh run-ephemeral <base-vm> -- <command...>
   ```
   - Automatically boots the base VM with QEMU `-snapshot` (all writes to disk are held in RAM/temporary files and discarded upon exit).
   - Waits for guest SSH readiness.
   - Executes the command and returns its exit code and stdout/stderr.
   - Gracefully stops the VM and discards all writes. The base VM is untouched.

2. **Step-by-Step Ephemeral Execution:**
   ```bash
   # Start base VM with snapshot discard flag
   ./skills/manage-vms/scripts/manage-vms.sh start <base-vm> --daemon --snapshot

   # Wait for guest SSH port
   ./skills/manage-vms/scripts/manage-vms.sh wait-ready <base-vm>

   # Transfer files
   ./skills/manage-vms/scripts/manage-vms.sh copy-to <base-vm> ./my-script.sh /tmp/my-script.sh

   # Execute commands
   ./skills/manage-vms/scripts/manage-vms.sh exec <base-vm> -- bash /tmp/my-script.sh

   # Stop and discard all changes
   ./skills/manage-vms/scripts/manage-vms.sh stop <base-vm> --force
   ```

---

## 3. Desktop Wizard Rule (Never Hang Subshells)

> [!IMPORTANT]
> **Interactive wizards (e.g. `create-vm-wizard.sh`, `sanity-check.sh --wizard`) must NEVER be executed directly within an agent tool call (`run_command`).**
> Subshells have no interactive TTY or stdin access, which causes tools to hang indefinitely.
>
> When human intervention is required (e.g. downloading official Windows ISO from Microsoft with a browser session):
> ```bash
> ./skills/create-vm/scripts/launch-terminal.sh ./skills/create-vm/scripts/create-vm-wizard.sh
> ```
> This immediately opens a visible terminal window on the user's macOS/Linux desktop and allows the tool call to complete cleanly.

---

## 4. Skill Catalog Reference

| Skill | Purpose | Key Commands |
| :--- | :--- | :--- |
| **`sanity-check`** | Verify QEMU, hypervisor acceleration (`hvf`/`kvm`), and preferences. | `./skills/sanity-check/scripts/sanity-check.sh --check --json` |
| **`create-vm`** | Download media, generate unattended answer files, and provision VMs. | `./skills/create-vm/scripts/create-windows-vm.sh <name>` |
| **`use-linux-vm`** | Infer and run purpose-bound Linux test/build guests, including implicit Linux requests. | `./skills/create-vm/scripts/create-linux-vm.sh <name> ...` |
| **`manage-vms`** | Complete lifecycle, exec, file transfer, and snapshot management. | `./skills/manage-vms/scripts/manage-vms.sh list --json` |
