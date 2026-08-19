---
name: manage-vms
description: Use when creating, importing, renaming, resizing, cloning, inspecting, listing, or deleting local virtual machines and disk images in vm-stack on macOS.
---

# Manage VMs

Authoritative QEMU and filesystem gateway for local virtual machine lifecycle management in `vm-stack` on macOS.

All VM definitions and metadata are stored in `~/.config/vm-stack/vms.json` and default disk images in `~/.config/vm-stack/images/`.

Bundled script: [scripts/manage-vms.sh](file:///Users/chad/Repos/vm-stack/skills/manage-vms/scripts/manage-vms.sh)

---

## Core Operational Rule for Agents

> [!IMPORTANT]
> **Always route VM disk creations, deletions, renames, resizing, and cloning through `manage-vms.sh`.**
> Never run raw `qemu-img create`, `qemu-img resize`, `rm`, or `mv` directly on VM disk files without routing through `manage-vms.sh`.
> 
> `manage-vms.sh` executes the underlying QEMU and filesystem operations while ensuring that `~/.config/vm-stack/vms.json` remains the accurate, authoritative source of truth.

---

## Command Reference & Architecture

```
                          ┌─────────────────────────────┐
                          │   Agent / User Command      │
                          │   manage-vms.sh <action>    │
                          └──────────────┬──────────────┘
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                               ▼
   ┌───────────────────────────┐                   ┌───────────────────────────┐
   │  Execute Real Operation   │                   │ Update Authoritative State│
   │  - qemu-img create/resize │                   │ ~/.config/vm-stack/       │
   │  - filesystem mv / rm     │ ───[ Success ]──► │   vms.json                │
   │  - qemu-system execution  │                   │                           │
   └───────────────────────────┘                   └───────────────────────────┘
```

---

### 1. Create a VM & Disk (`create`)
Invokes `qemu-img create` to allocate the disk image and registers the VM in `vms.json` in one atomic operation:

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
  --description "Primary ARM64 development environment"
```

### 2. Import an Existing Disk Image (`import`)
Inspects an existing disk image via `qemu-img info` and registers it:

```bash
./skills/manage-vms/scripts/manage-vms.sh import debian-cloud \
  --disk /Users/chad/Downloads/debian-12-nocloud.qcow2 \
  --os debian \
  --memory 4G
```

### 3. Rename a VM & Disk Image (`rename`)
Renames the VM entry in `vms.json` and automatically moves/renames the disk image file on the filesystem:

```bash
# Renames registry entry and moves images/dev-ubuntu.qcow2 -> images/staging-ubuntu.qcow2
./skills/manage-vms/scripts/manage-vms.sh rename dev-ubuntu staging-ubuntu
```

### 4. Resize a VM Disk (`resize`)
Expands the VM disk via `qemu-img resize` and updates the virtual size in `vms.json`:

```bash
# Grow disk by 10 Gigabytes
./skills/manage-vms/scripts/manage-vms.sh resize staging-ubuntu +10G

# Set absolute size
./skills/manage-vms/scripts/manage-vms.sh resize staging-ubuntu 50G
```

### 5. Clone a VM (`clone`)
Creates a fast Copy-on-Write linked overlay (default) or a full standalone copy via `qemu-img convert`, registering the cloned VM:

```bash
# Fast linked overlay clone (shares base image, only writes deltas)
./skills/manage-vms/scripts/manage-vms.sh clone staging-ubuntu dev-worker-1

# Standalone full clone
./skills/manage-vms/scripts/manage-vms.sh clone staging-ubuntu dev-worker-standalone --full
```

### 6. Delete a VM & Clean Up Disk (`delete`)
Deletes the disk image file from the filesystem and removes the VM from `vms.json`:

```bash
# Deletes both disk file and registry entry
./skills/manage-vms/scripts/manage-vms.sh delete dev-worker-1

# Unregisters VM while preserving disk file
./skills/manage-vms/scripts/manage-vms.sh delete dev-worker-1 --keep-disk
```

### 7. Inspect VM & Live Disk State (`inspect`)
Combines registered configuration in `vms.json` with live `qemu-img info` metadata:

```bash
# Human-readable summary
./skills/manage-vms/scripts/manage-vms.sh inspect dev-ubuntu

# Machine-readable JSON
./skills/manage-vms/scripts/manage-vms.sh inspect dev-ubuntu --json
```

### 8. Audit & Reconcile Registry (`sync`)
Scans the filesystem against `vms.json`, detects missing disk files, refreshes virtual sizes, and optionally prunes orphaned records:

```bash
# Audit status
./skills/manage-vms/scripts/manage-vms.sh sync

# Audit and prune records with missing disks
./skills/manage-vms/scripts/manage-vms.sh sync --prune
```

### 9. Query & Update
```bash
# List all VMs
./skills/manage-vms/scripts/manage-vms.sh list
./skills/manage-vms/scripts/manage-vms.sh list --json
./skills/manage-vms/scripts/manage-vms.sh list --quiet

# Get single VM record
./skills/manage-vms/scripts/manage-vms.sh get dev-ubuntu --json

# Update resources or metadata
./skills/manage-vms/scripts/manage-vms.sh update dev-ubuntu --memory 16G --cpus 8

# Test existence (exit 0=yes, 1=no)
./skills/manage-vms/scripts/manage-vms.sh exists dev-ubuntu
```

---

## State Schema (`~/.config/vm-stack/vms.json`)

```json
{
  "version": 1,
  "updated_at": "2026-08-19T17:47:00Z",
  "vms": {
    "dev-ubuntu": {
      "name": "dev-ubuntu",
      "arch": "aarch64",
      "os": "ubuntu",
      "disk": "/Users/chad/.config/vm-stack/images/dev-ubuntu.qcow2",
      "format": "qcow2",
      "virtual_size": "40.0G",
      "backing_file": null,
      "memory": "8G",
      "cpus": 4,
      "accel": "hvf",
      "description": "Primary ARM64 development environment",
      "status": "stopped",
      "extra_args": "",
      "created_at": "2026-08-19T17:40:00Z",
      "updated_at": "2026-08-19T17:47:00Z"
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
