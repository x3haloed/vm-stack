---
name: manage-vms
description: Use when registering, creating, listing, inspecting, querying, updating, or deleting local virtual machines in the vm-stack registry on macOS.
---

# Manage VMs

Maintains a local registry of known virtual machines for `vm-stack` on macOS. VM definitions and metadata are stored in `~/.config/vm-stack/vms.json`.

Bundled script: [scripts/manage-vms.sh](file:///Users/chad/Repos/vm-stack/skills/manage-vms/scripts/manage-vms.sh)

---

## State Storage & Schema

The registry is stored at `${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack/vms.json`:

```json
{
  "version": 1,
  "updated_at": "2026-08-19T17:40:00Z",
  "vms": {
    "ubuntu-arm64": {
      "name": "ubuntu-arm64",
      "arch": "aarch64",
      "os": "ubuntu",
      "disk": "/Users/chad/vms/ubuntu.qcow2",
      "memory": "4G",
      "cpus": 4,
      "accel": "hvf",
      "description": "Ubuntu 24.04 ARM64 Development VM",
      "status": "stopped",
      "extra_args": "",
      "created_at": "2026-08-19T17:40:00Z",
      "updated_at": "2026-08-19T17:40:00Z"
    }
  }
}
```

### VM Record Attributes:
- **`name`** *(string, required)*: Unique identifier for the VM (alphanumeric, dashes, underscores).
- **`arch`** *(string)*: CPU architecture (e.g. `aarch64`, `x86_64`). Defaults to host architecture.
- **`os`** *(string)*: OS distribution label (e.g. `ubuntu`, `debian`, `alpine`, `macos`, `generic`).
- **`disk`** *(string)*: Absolute path to the VM disk image (`.qcow2`, `.img`, `.raw`).
- **`memory`** *(string)*: RAM allocation (e.g. `4G`, `8G`, `2048M`). Default: `4G`.
- **`cpus`** *(int)*: Number of virtual CPU cores. Default: `2`.
- **`accel`** *(string)*: Hypervisor acceleration mode (`hvf`, `tcg`). Default: `hvf` on macOS.
- **`description`** *(string)*: Human-readable description of VM workload or purpose.
- **`status`** *(string)*: Current lifecycle state (`stopped`, `running`, `paused`). Default: `stopped`.
- **`extra_args`** *(string)*: Custom QEMU flags or device specifications.
- **`created_at`** / **`updated_at`** *(string)*: ISO-8601 UTC timestamps.

---

## Command-Line Interface (CRUD)

### 1. Register a VM (`add`)
Registers a new virtual machine definition in the registry:

```bash
# Basic registration
./skills/manage-vms/scripts/manage-vms.sh add my-vm --disk /path/to/disk.qcow2

# Full specification
./skills/manage-vms/scripts/manage-vms.sh add dev-ubuntu \
  --disk /Users/chad/vms/ubuntu-24.04.qcow2 \
  --arch aarch64 \
  --memory 8G \
  --cpus 4 \
  --os ubuntu \
  --accel hvf \
  --description "Primary ARM64 development VM"
```

### 2. List VMs (`list`)
Lists all registered virtual machines:

```bash
# Formatted table view
./skills/manage-vms/scripts/manage-vms.sh list

# JSON array output (for agent parsing)
./skills/manage-vms/scripts/manage-vms.sh list --json

# Names only (useful for shell loops)
./skills/manage-vms/scripts/manage-vms.sh list --quiet
```

### 3. Inspect a VM (`get`)
Retrieves details for a specific VM:

```bash
# Formatted key-value text
./skills/manage-vms/scripts/manage-vms.sh get dev-ubuntu

# JSON object output
./skills/manage-vms/scripts/manage-vms.sh get dev-ubuntu --json
```

### 4. Update a VM (`update`)
Updates one or more attributes of an existing VM:

```bash
# Update memory and CPU allocations
./skills/manage-vms/scripts/manage-vms.sh update dev-ubuntu --memory 16G --cpus 8

# Update status
./skills/manage-vms/scripts/manage-vms.sh update dev-ubuntu --status running

# Update disk location
./skills/manage-vms/scripts/manage-vms.sh update dev-ubuntu --disk /new/path/to/disk.qcow2
```

### 5. Check VM Existence (`exists`)
Tests whether a VM exists in the registry (returns exit code `0` if present, `1` if missing):

```bash
if ./skills/manage-vms/scripts/manage-vms.sh exists dev-ubuntu; then
  echo "VM exists"
fi
```

### 6. Delete a VM (`delete`)
Removes a virtual machine from the registry:

```bash
# Unregister VM (leaves disk image intact)
./skills/manage-vms/scripts/manage-vms.sh delete dev-ubuntu

# Unregister VM and delete disk image file
./skills/manage-vms/scripts/manage-vms.sh delete dev-ubuntu --delete-disk
```

### 7. Print Registry Path (`path`)
Outputs the absolute path to the active `vms.json` file:

```bash
./skills/manage-vms/scripts/manage-vms.sh path
```

---

## Agent Usage Recipes

### Checking if a VM Exists Before Launching
```bash
if ! ./skills/manage-vms/scripts/manage-vms.sh exists "$VM_NAME"; then
  ./skills/manage-vms/scripts/manage-vms.sh add "$VM_NAME" \
    --disk "$DISK_PATH" \
    --memory 4G \
    --cpus 2 \
    --os ubuntu
fi
```

### Inspecting VM Parameters Programmatically
```bash
VM_JSON=$(./skills/manage-vms/scripts/manage-vms.sh get "$VM_NAME" --json)
DISK_PATH=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['disk'])" "$VM_JSON")
MEMORY=$(python3 -c "import sys, json; print(json.loads(sys.argv[1])['memory'])" "$VM_JSON")
```

---

## Exit Codes

| Code | Meaning |
| :--- | :--- |
| **0** | Success |
| **1** | Command syntax or general execution error |
| **2** | VM not found |
| **3** | VM already exists |
