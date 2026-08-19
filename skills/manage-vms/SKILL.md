---
name: manage-vms
description: Use when creating, starting, stopping, checking live status, importing, renaming, resizing, cloning, snapshotting, inspecting, listing, or deleting local virtual machines in vm-stack.
---

# Manage VMs

Authoritative QEMU and filesystem gateway for local virtual machine lifecycle management in `vm-stack` across macOS, Linux, and Windows.

All authoritative VM specifications are stored in `~/.config/vm-stack/vms.json`, default disk images in `~/.config/vm-stack/images/`, and runtime state in `~/.config/vm-stack/run/`.

Bundled script: [scripts/manage-vms.sh](file:///Users/chad/Repos/vm-stack/skills/manage-vms/scripts/manage-vms.sh)

---

## Core Operational Rule for Agents

> [!IMPORTANT]
> **Always route VM disk operations (create, delete, rename, resize, clone, snapshot) and execution (start, stop) through `manage-vms.sh`.**
> Never run raw `qemu-img` or `rm`/`mv` on VM disk files directly without routing through `manage-vms.sh`.
> 
> `manage-vms.sh` binds the physical QEMU disk and runtime process directly to the inventory in `~/.config/vm-stack/vms.json`, ensuring zero state drift.

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

### What `vms.json` Authoritatively Owns:
1. **VM Identity:** Name & description
2. **Disk Path:** Primary disk location
3. **Hardware Allocation:** vCPUs, RAM, architecture, OS profile, acceleration type
4. **Port Configuration:** Forwarded host ports for SSH and RDP
5. **Custom Flags:** `extra_args`

### What is Dynamically Probed On-the-Fly:
* **Disk properties:** Actual size on disk, virtual size, format, backing file, internal snapshots (probed via `qemu-img info`).
* **Runtime liveness:** True running status, PID, uptime, and whether the SSH port is actively listening (probed via OS process check and TCP connection probe).

---

## Command Reference

### 1. Create a VM & Disk (`create`)
Allocates the QEMU disk image and registers the authoritative VM specification in `vms.json` in one atomic operation:

```bash
# Basic creation (default: ~/.config/vm-stack/images/<name>.qcow2)
./skills/manage-vms/scripts/manage-vms.sh create dev-ubuntu --size 20G

# Full specification
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
Launches QEMU with registered hardware specifications, acceleration, and port forwardings:

```bash
# Start in background daemon mode (tracks PID in ~/.config/vm-stack/run/<name>.pid)
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --daemon

# Start in foreground with visible Cocoa GUI
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --display cocoa

# Dry-run to inspect assembled QEMU command
./skills/manage-vms/scripts/manage-vms.sh start dev-ubuntu --dry-run
```

### 3. Check Live Status (`status`)
Probes the live system (process table, listening ports, disk header) and returns real-time status:

```bash
# Human-readable summary
./skills/manage-vms/scripts/manage-vms.sh status dev-ubuntu

# Machine-readable JSON
./skills/manage-vms/scripts/manage-vms.sh status dev-ubuntu --json
```

### 4. Stop a Virtual Machine (`stop`)
Gracefully shuts down the VM process via `SIGTERM`, falling back to `SIGKILL` if unresponsive:

```bash
# Graceful shutdown
./skills/manage-vms/scripts/manage-vms.sh stop dev-ubuntu

# Immediate force kill
./skills/manage-vms/scripts/manage-vms.sh stop dev-ubuntu --force
```

### 5. Snapshot Management (`snapshot`)
Creates, lists, rolls back, or deletes internal Copy-on-Write disk snapshots via `qemu-img`:

```bash
# Create a snapshot checkpoint
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu create clean-install

# List snapshots
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu list
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu list --json

# Roll back VM disk to snapshot (VM must be stopped)
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu rollback clean-install

# Delete snapshot
./skills/manage-vms/scripts/manage-vms.sh snapshot dev-ubuntu delete clean-install
```

### 6. List All Registered VMs (`list`)
Synthesizes the authoritative inventory with live disk and process probes for every VM:

```bash
# Live status table
./skills/manage-vms/scripts/manage-vms.sh list

# Machine-readable JSON array
./skills/manage-vms/scripts/manage-vms.sh list --json

# Quiet mode (names only)
./skills/manage-vms/scripts/manage-vms.sh list --quiet
```

### 7. Inspect VM Details (`inspect`)
Combines authoritative configuration with complete `qemu-img info` and live process metrics:

```bash
./skills/manage-vms/scripts/manage-vms.sh inspect dev-ubuntu
./skills/manage-vms/scripts/manage-vms.sh inspect dev-ubuntu --json
```

### 8. Clone a VM (`clone`)
Creates a fast Copy-on-Write linked overlay (default) or a full standalone copy, assigning a non-conflicting SSH port:

```bash
# Fast linked overlay clone (shares base disk, only writes deltas)
./skills/manage-vms/scripts/manage-vms.sh clone dev-ubuntu dev-worker-1

# Standalone full clone
./skills/manage-vms/scripts/manage-vms.sh clone dev-ubuntu dev-worker-standalone --full
```

### 9. Resize a VM Disk (`resize`)
Expands the VM disk via `qemu-img resize`:

```bash
# Grow disk by 10 Gigabytes
./skills/manage-vms/scripts/manage-vms.sh resize dev-ubuntu +10G
```

### 10. Rename a VM (`rename`)
Atomically renames the VM entry in `vms.json` and moves the disk and NVRAM files on the filesystem:

```bash
./skills/manage-vms/scripts/manage-vms.sh rename dev-ubuntu staging-ubuntu
```

### 11. Delete a VM (`delete`)
Stops any running instance, deletes the disk file and NVRAM variables, and removes the registry entry:

```bash
./skills/manage-vms/scripts/manage-vms.sh delete dev-worker-1
```

### 12. Audit & Reconcile (`sync`)
Scans the filesystem against `vms.json`, cleans up dead PID files, reports missing disks, and optionally prunes orphaned records:

```bash
./skills/manage-vms/scripts/manage-vms.sh sync
./skills/manage-vms/scripts/manage-vms.sh sync --prune
```

---

## Authoritative Specification Schema (`~/.config/vm-stack/vms.json`)

```json
{
  "version": 1,
  "updated_at": "2026-08-19T21:45:00Z",
  "vms": {
    "dev-ubuntu": {
      "name": "dev-ubuntu",
      "disk": "/Users/chad/.config/vm-stack/images/dev-ubuntu.qcow2",
      "os": "ubuntu",
      "arch": "aarch64",
      "cpus": 4,
      "memory": "8G",
      "accel": "hvf",
      "ssh_port": 2222,
      "rdp_port": 3389,
      "extra_args": "",
      "description": "Primary ARM64 development environment",
      "created_at": "2026-08-19T17:40:00Z",
      "updated_at": "2026-08-19T21:45:00Z"
    }
  }
}
```

---

## Exit Codes

| Code | Meaning |
| :--- | :--- |
| **0** | Success |
| **1** | Command syntax or QEMU/FS execution error |
| **2** | VM not found |
| **3** | VM already exists |
