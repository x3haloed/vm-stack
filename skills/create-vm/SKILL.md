---
name: create-vm
description: Use when creating, provisioning, downloading installation media for, or starting new Windows, Linux, or custom virtual machines in vm-stack on macOS.
---

# Create VM

Authoritative procedural guide and tooling for creating, provisioning, and automating local virtual machines in `vm-stack` on macOS.

Covers automated media acquisition, unattended installation (`autounattend.xml` / `cloud-init`), UEFI NVRAM firmware handling, TPM/SecureBoot bypasses, and interactive wizard fallbacks when human intervention is needed.

---

## Agent Decision Workflow

When a user asks to create or start a VM (e.g. *"I want you to start a Windows VM to test this"* or *"Provision an Ubuntu ARM64 VM"*), follow this deterministic workflow:

```
                      +──────────────────────────+
                      | User Request             |
                      | "Start a Windows VM..."  |
                      +─────────────┬────────────+
                                    │
                                    ▼
                      +──────────────────────────+
                      | 1. Query Host Arch       |
                      |    uname -m              |
                      |    arm64  -> aarch64     |
                      |    x86_64 -> x86_64      |
                      +─────────────┬────────────+
                                    │
                                    ▼
                      +──────────────────────────+
                      | 2. Check / Fetch Media   |
                      |    ~/.config/vm-stack/   |
                      |      media/              |
                      +─────────────┬────────────+
                                    │
                         Is OS Media available?
                                    │
                     ┌──────────────┴──────────────┐
                     ▼                             ▼
                  [ YES ]                       [ NO ]
                     │                             │
                     │                     Pop Open Media Wizard
                     │                     create-vm-wizard.sh
                     │                             │
                     └──────────────┬──────────────┘
                                    │
                                    ▼
                      +──────────────────────────+
                      | 3. Authoritative VM Disk |
                      |    manage-vms.sh create  |
                      |    --size 64G ...        |
                      +─────────────┬────────────+
                                    │
                                    ▼
                      +──────────────────────────+
                      | 4. Generate Unattend ISO |
                      |    generate-unattend.sh  |
                      |    (TPM/RAM bypass, SSH) |
                      +─────────────┬────────────+
                                    │
                                    ▼
                      +──────────────────────────+
                      | 5. Launch Installation   |
                      |    create-windows-vm.sh  |
                      |    (QEMU with HVF, NVMe) |
                      +──────────────────────────+
```

---

## Step-by-Step Guidance by OS Type

### A. Windows 11 / Windows 10 Provisioning

#### 1. Architecture Matching
- **Apple Silicon (`arm64`)**: Must install **Windows 11 on ARM (ARM64)** with `-accel hvf` and `qemu-system-aarch64`. *(Emulating x86_64 Windows on Apple Silicon via TCG is slow and unsupported for interactive workloads).*
- **Intel Mac (`x86_64`)**: Install **Windows 10/11 x86_64** with `-accel hvf` and `qemu-system-x86_64`.

#### 2. Media Acquisition (`~/.config/vm-stack/media/`)
Check if the Windows ISO is already cached:
```bash
./skills/create-vm/scripts/fetch-media.sh find-windows
```
- If missing:
  - If a direct download URL or path was supplied, save/symlink it to `~/.config/vm-stack/media/`.
  - Otherwise, launch the interactive setup wizard so the human can download the official ISO from Microsoft and provide the path:
    ```bash
    ./skills/create-vm/scripts/create-vm-wizard.sh
    ```
- Automatically ensure Red Hat VirtIO drivers are present:
  ```bash
  ./skills/create-vm/scripts/fetch-media.sh virtio-win
  ```

#### 3. Automated Unattended Provisioning (`create-windows-vm.sh`)
Run the automated Windows creator script:
```bash
./skills/create-vm/scripts/create-windows-vm.sh <vm-name> \
  --size 64G \
  --memory 8G \
  --cpus 4 \
  --username admin \
  --password admin \
  --ssh-port 2222 \
  --rdp-port 3389
```

This single command executes the complete unattended pipeline:
1. Allocates and registers the VM in `~/.config/vm-stack/vms.json` via `manage-vms.sh`.
2. Initializes the per-VM UEFI NVRAM variable store (`~/.config/vm-stack/images/<name>_vars.fd`).
3. Generates `autounattend.xml` with `LabConfig` bypasses (`BypassTPMCheck=1`, `BypassSecureBootCheck=1`, `BypassRAMCheck=1`, `BypassCPUCheck=1`, `BypassStorageCheck=1`), automatic partition formatting, default local admin account (`admin`/`admin`), OOBE bypass, and OpenSSH server enablement.
4. Launches QEMU with:
   - `-accel hvf`
   - `-device nvme,drive=hd0` (enables inbox Windows NVMe storage driver without manual driver injection)
   - `-drive file=virtio-win.iso` (provides VirtIO network and balloon drivers)
   - `-drive file=unattend.iso`
   - Port forwarding: Host `2222` -> Guest `22` (SSH), Host `3389` -> Guest `3389` (RDP).

---

### B. Linux VM Provisioning (Ubuntu / Debian / Cloud-Init)

For Linux virtual machines, pre-baked cloud images with `cloud-init` provide near-instant 10-second provisioning without running an installer:

#### 1. Download Base Cloud Image
```bash
# Ubuntu 24.04 Server Cloud Image
./skills/create-vm/scripts/fetch-media.sh ubuntu

# Debian 12 Generic Cloud Image
./skills/create-vm/scripts/fetch-media.sh debian
```

#### 2. Create VM via `manage-vms.sh`
```bash
./skills/manage-vms/scripts/manage-vms.sh create my-ubuntu \
  --size 20G \
  --memory 4G \
  --cpus 2 \
  --os ubuntu \
  --backing-file ~/.config/vm-stack/media/ubuntu-24.04-server-cloudimg-aarch64.img
```

---

## When to Launch the Setup Wizard

When any of the following conditions occur, **do not prompt the user with raw terminal commands**. Instead, launch the interactive setup wizard:

```bash
./skills/create-vm/scripts/create-vm-wizard.sh
```

### Wizard Triggers:
1. **Missing Windows Installation ISO**: The wizard opens Microsoft's official download portal in the user's browser, explains which edition to select, and prompts for the downloaded ISO file path.
2. **Ambiguous Hardware Requirements**: The wizard guides the user through selecting RAM, vCPU cores, and disk sizing.
3. **Interactive Graphical Installation**: The wizard launches the VM display and monitors setup through to desktop readiness.

---

## Script Reference Matrix

| Script | Purpose |
| :--- | :--- |
| **[scripts/fetch-media.sh](file:///Users/chad/Repos/vm-stack/skills/create-vm/scripts/fetch-media.sh)** | Downloads and manages ISOs, VirtIO drivers, and cloud images in `~/.config/vm-stack/media/`. |
| **[scripts/generate-unattend.sh](file:///Users/chad/Repos/vm-stack/skills/create-vm/scripts/generate-unattend.sh)** | Generates Windows `autounattend.xml` with TPM/SecureBoot bypasses, user credentials, and builds `unattend.iso`. |
| **[scripts/create-windows-vm.sh](file:///Users/chad/Repos/vm-stack/skills/create-vm/scripts/create-windows-vm.sh)** | End-to-end automated runner for Windows 11/10 unattended QEMU provisioning. |
| **[scripts/create-vm-wizard.sh](file:///Users/chad/Repos/vm-stack/skills/create-vm/scripts/create-vm-wizard.sh)** | Interactive multi-stage terminal setup wizard for human-guided media and VM creation. |
