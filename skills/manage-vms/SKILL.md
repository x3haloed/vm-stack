---
name: manage-vms
description: Use when creating, starting, stopping, checking live status, importing, renaming, resizing, cloning, snapshotting, inspecting, listing, executing commands in, transferring files to, or deleting local virtual machines in vm-stack.
---

# Manage VMs

Authoritative QEMU and filesystem gateway for local virtual machine lifecycle management, zero-touch ephemeral testbeds, and guest execution in `vm-stack` across macOS, Linux, and Windows.

- Authoritative specification: [schemas/vms.schema.json](../../schemas/vms.schema.json)
- Bundled CLI gateway: [scripts/manage-vms.sh](scripts/manage-vms.sh)

---

## Core Operational Rule for Agents

> [!IMPORTANT]
> **Always route VM disk operations (create, delete, rename, resize, clone, snapshot) and execution (start, stop, wait-ready, exec) through `manage-vms.sh`.**
> Never run raw `qemu-img` or `rm`/`mv` on VM disk files directly without routing through `manage-vms.sh`.
> 
> `manage-vms.sh` binds the physical QEMU disk and runtime process directly to the inventory in `~/.config/vm-stack/vms.json`, ensuring zero state drift.

### Managed guest authority

When the user asks `vm-stack` to create or manage a VM for a stated purpose, treat routine guest-local administration needed for that purpose as part of the requested work. This includes installing guest drivers or packages, enabling services, accepting guest-local elevation prompts, rebooting the guest, and changing disposable guest configuration. Do not repeatedly hand those operations back to the user merely because the same operation would be consequential on a user-owned host or workspace.

This authority is bounded by the registered guest and its declared purpose. It does not authorize host changes outside `vm-stack`, access to unrelated user data, publication, external account changes, or destructive replacement of a non-disposable guest. Higher-level harness confirmation requirements still apply when they cannot be delegated by repository guidance.

---

## Authority & Dynamic Probing Architecture

```
                          ┌─────────────────────────────┐
                          │   Agent / User Command      │
                          │   manage-vms.sh <action>    │
                          └──────────────┬──────────────┘
                                         │
        ┌────────────────────────────────┼────────────────────────────────┐
        ▼                                ▼                                ▼
  [ QEMU Execution ]           [ Authoritative Spec ]            [ Live Probing ]
  - Disk create / resize       - Stored in vms.json             - qemu-img info (disk)
  - Process start / stop       - cpus, memory, os, ports        - PID / TCP probe (liveness)
  - Snapshot lifecycle         - Bound atomically               - Real-time synthesis
```

---

## Command Reference

### 1. Create a VM & Disk (`create`)
```bash
./skills/manage-vms/scripts/manage-vms.sh create dev-ubuntu \
  --size 40G \
  --format qcow2 \
  --arch aarch64 \
  --memory 8G \
  --cpus 4 \
  --os ubuntu \
  --accel hvf \
  --ssh-port 2222 \
  --description "Primary ARM64 development environment"
```

### 2. Start a Virtual Machine (`start`)
```bash
# Start in background daemon mode
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --daemon

# Start in ephemeral snapshot mode (discards all disk writes upon shutdown)
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --daemon --snapshot

# Start with visible desktop Cocoa GUI window
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --display cocoa
```

### 3. Ephemeral Single-Command Execution (`run-ephemeral`)
Spins up a base VM with snapshot discard isolation, waits for SSH readiness, executes the command, and destroys the runtime state without touching the base image:
```bash
./skills/manage-vms/scripts/manage-vms.sh run-ephemeral dev-ubuntu -- uname -a
./skills/manage-vms/scripts/manage-vms.sh run-ephemeral win11-dev -- powershell -Command "Get-ComputerInfo"
```

### 4. Wait for Guest Readiness (`wait-ready`)
Polls until the guest's SSH service is responsive:
```bash
./skills/manage-vms/scripts/manage-vms.sh wait-ready dev-ubuntu --timeout 120
```

### 5. Execute Commands in Guest (`exec`)
Runs arbitrary commands inside the running guest via SSH, returning the exact stdout, stderr, and exit code:
```bash
./skills/manage-vms/scripts/manage-vms.sh exec dev-ubuntu -- "ls -la /tmp"
./skills/manage-vms/scripts/manage-vms.sh exec win11-dev --user admin --password admin -- "cmd /c dir"
```

### 6. Transfer Files (`copy-to` / `copy-from`)
Copies files between host and guest via SCP:
```bash
# Host to Guest
./skills/manage-vms/scripts/manage-vms.sh copy-to dev-ubuntu ./test.sh /tmp/test.sh

# Guest to Host
./skills/manage-vms/scripts/manage-vms.sh copy-from dev-ubuntu /tmp/output.log ./output.log
```

### 7. Check Live Status (`status`)
```bash
./skills/manage-vms/scripts/manage-vms.sh status dev-ubuntu
./skills/manage-vms/scripts/manage-vms.sh status dev-ubuntu --json
```

### 8. Operate a Pre-SSH Console (`send-key` / `type-text` / `screenshot`)

Use the manager-owned QEMU monitor when a guest is still in firmware, installation, OOBE, or recovery and SSH is unavailable:

```bash
./skills/manage-vms/scripts/manage-vms.sh screenshot win11-dev --output /tmp/win11.ppm
./skills/manage-vms/scripts/manage-vms.sh send-key win11-dev ctrl shift ret
./skills/manage-vms/scripts/manage-vms.sh type-text win11-dev 'FS0:\EFI\BOOT\BOOTAA64.EFI' --enter
```

`type-text` validates the complete string before sending any keys. Prefer `exec` once the guest SSH service is ready.

### 9. Stop a Virtual Machine (`stop`)
```bash
# Graceful ACPI shutdown
./skills/manage-vms/scripts/manage-vms.sh stop dev-ubuntu

# Immediate force kill
./skills/manage-vms/scripts/manage-vms.sh stop dev-ubuntu --force
```

### 10. Snapshot Management (`snapshot`)
```bash
# Create checkpoint
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu create clean-install

# List snapshots
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu list --json

# Roll back VM disk (VM must be stopped)
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu rollback clean-install

# Delete snapshot
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu delete clean-install
```

### 10. List All Registered VMs (`list`)
```bash
./skills/manage-vms/scripts/manage-vms.sh list
./skills/manage-vms/scripts/manage-vms.sh list --json
```

### 11. Inspect VM Details (`inspect`)
```bash
./skills/manage-vms/scripts/manage-vms.sh inspect dev-ubuntu --json
```

### 12. Clone a VM (`clone`)
```bash
# Fast linked overlay clone (shares base disk)
./skills/manage-vms/scripts/manage-vms.sh clone dev-ubuntu dev-worker-1

# Standalone full clone
./skills/manage-vms/scripts/manage-vms.sh clone dev-ubuntu dev-worker-standalone --full
```

### 13. Resize a VM Disk (`resize`)
```bash
./skills/manage-vms/scripts/manage-vms.sh resize dev-ubuntu +10G
```

### 14. Rename a VM (`rename`)
```bash
./skills/manage-vms/scripts/manage-vms.sh rename dev-ubuntu staging-ubuntu
```

### 15. Delete a VM (`delete`)
```bash
./skills/manage-vms/scripts/manage-vms.sh delete dev-worker-1
```

### 16. Audit & Reconcile (`sync`)
```bash
./skills/manage-vms/scripts/manage-vms.sh sync --prune
```

---

## Exit Codes

| Code | Meaning |
| :--- | :--- |
| **0** | Success |
| **1** | Command syntax or QEMU/FS execution error |
| **2** | VM not found |
| **3** | VM already exists |
