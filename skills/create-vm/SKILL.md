---
name: create-vm
description: Use when creating, provisioning, downloading installation media for, or starting new Windows, Linux, or custom virtual machines in vm-stack across macOS, Linux, or Windows.
---

# Create VM

Authoritative procedural guide and tooling for creating, provisioning, and automating local virtual machines in `vm-stack` across macOS, Linux, and Windows.

- Windows Unattended Guide: [references/windows-provisioning.md](references/windows-provisioning.md)
- Linux Cloud-Init Guide: [references/cloud-init-linux.md](references/cloud-init-linux.md)
- Implicit Linux test workflow: [../use-linux-vm/SKILL.md](../use-linux-vm/SKILL.md)
- Desktop Wizard Helper: [scripts/launch-terminal.sh](scripts/launch-terminal.sh)

Covers automated media acquisition, unattended installation (`autounattend.xml` / `cloud-init`), UEFI NVRAM firmware handling, TPM/SecureBoot bypasses, deterministic offline guest provisioning, and interactive desktop wizard fallbacks when media acquisition genuinely needs human intervention.

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
                     │                     Pop Open Desktop Wizard
                     │                     launch-terminal.sh
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
                      |    (answer file + offline|
                      |     guest provisioner)  |
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

## Critical Execution Rule: Launching Wizards on Desktop

> [!IMPORTANT]
> **Never run an interactive wizard inside your own background agent subshell / tool call (e.g. `run_command`).**
> Agent tool subshells have no interactive TTY or keyboard access to the user's desktop, so running an interactive wizard inside `run_command` causes the task to hang waiting on stdin.
>
> **Always launch the wizard in a visible terminal window on the user's desktop** using the bundled `launch-terminal.sh` helper:
> ```bash
> ./skills/create-vm/scripts/launch-terminal.sh ./skills/create-vm/scripts/create-vm-wizard.sh
> ```
> This immediately opens a visible macOS Terminal window on the user's desktop so the user can directly interact with the wizard, while your agent tool call finishes cleanly.

---

## Step-by-Step Guidance by OS Type

### A. Windows 11 / Windows 10 Provisioning

#### 1. Architecture Matching
- **Apple Silicon (`arm64`)**, ordinary path: install **Windows 11 on ARM
  (ARM64)** with `-accel hvf` and `qemu-system-aarch64`.
- **Apple Silicon (`arm64`)**, explicit compatibility path: x86-64 Windows may
  be installed with `--arch x86_64 --accel tcg`. This is full-system CPU
  emulation, not HVF virtualization. It is intentionally opt-in, warns that
  installation may take several hours, and defaults readiness waiting to four
  hours. Use it when native x86-64 execution semantics matter more than speed.
- **Intel Mac (`x86_64`)**: Install **Windows 10/11 x86_64** with `-accel hvf` and `qemu-system-x86_64`.

#### 2. Media Acquisition (`~/.config/vm-stack/media/`)
Check if the Windows ISO is already cached:
```bash
./skills/create-vm/scripts/fetch-media.sh find-windows
```
- If missing:
  - If a direct download URL or path was supplied, save/symlink it to `~/.config/vm-stack/media/`.
  - Otherwise, launch the interactive setup wizard on the user's desktop so the human can download the official ISO from Microsoft and provide the path:
    ```bash
    ./skills/create-vm/scripts/launch-terminal.sh ./skills/create-vm/scripts/create-vm-wizard.sh
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

On Apple Silicon, explicitly request x86-64 TCG emulation with matching x64
installation media:

```bash
./skills/create-vm/scripts/create-windows-vm.sh windows-x64-tcg \
  --arch x86_64 --accel tcg --iso /path/to/Win11_x64.iso \
  --size 64G --memory 8G --cpus 4
```

This single command executes the complete unattended pipeline:
1. Allocates and registers the VM in `~/.config/vm-stack/vms.json` via `manage-vms.sh`.
2. Initializes the per-VM UEFI NVRAM variable store (`~/.config/vm-stack/images/<name>_vars.fd`).
3. Fetches a pinned, checksum-verified Win32-OpenSSH MSI and generates an unattended ISO containing `autounattend.xml`, the MSI, and `provision-windows.ps1`. The answer file supplies `LabConfig` bypasses, automatic partitioning, the requested local administrator, locale settings, and supported OOBE automation.
4. Launches QEMU with:
   - `-accel hvf` for same-architecture virtualization, or explicit
     `-accel tcg` for cross-architecture emulation
   - `-device nvme,drive=hd0` (enables inbox Windows NVMe storage driver)
   - `-device usb-storage,drive=win_iso` (attaches Windows ISO as native USB media so WinPE never throws missing CD/DVD driver errors)
   - `-device usb-storage,drive=virtio_iso` (provides VirtIO network and balloon drivers with automated search paths)
   - `-device usb-storage,drive=unattend_iso` (provides the answer file, offline OpenSSH package, and the single guest provisioner)
   - Port forwarding: Host `2222` -> Guest `22` (SSH), Host `3389` -> Guest `3389` (RDP).
5. Recovers a missed optical-boot prompt through the managed QMP console when needed, waits for a real SSH banner, and verifies `C:\ProgramData\vm-stack\provisioned` before reporting success. Use `--no-wait` only when the caller explicitly wants asynchronous creation.
6. When run through the desktop wizard, offers an explicit post-provision choice to generalize the fresh VM with Sysprep and capture it as an immutable reusable base. The wizard warns that this removes machine-specific identity and shuts down the source VM; declining leaves the provisioned VM running normally.

#### 4. Reusing a Sealed Windows Base

After one fully provisioned Windows VM has passed acceptance, generalize and capture it once:

```bash
./skills/create-vm/scripts/seal-windows-base.sh <source-vm> windows11-arm64-base \
  --user admin --password admin
```

The seal workflow records the edition, licensing channel/status, grace time, and expiration. Evaluation media is rejected unless `--allow-expiring-base` is explicit. It removes machine-specific SSH keys and readiness state, runs Sysprep, waits for Windows to shut down, and delegates immutable image capture to `manage-vms.sh seal-base`. A clone reuses the preserved local administrator, performs one automatic logon, and publishes readiness only from its first-logon provisioner after the interactive desktop path has completed; it does not recreate the existing account during OOBE.

The desktop creation wizard offers this workflow immediately after successful Windows readiness verification. Direct callers continue to invoke `seal-windows-base.sh` explicitly so creating a normal long-lived VM never generalizes it implicitly.

Create subsequent VMs as thin overlays:

```bash
./skills/create-vm/scripts/create-windows-from-base.sh windows11-arm64-base <new-vm> \
  --purpose "Validate the Windows shim" \
  --release-when "Validation evidence has been captured" \
  --user admin --password admin
```

Purpose and release condition are required. Clones are disposable unless `--retained` is explicit. When the release condition becomes true, preserve the needed transcript, hashes, screenshots, or other evidence outside the guest and immediately run `manage-vms.sh release <vm>`.

The clone receives private writable disk and firmware state. Windows specializes a fresh machine identity, generates new SSH host keys, writes the readiness marker, and exposes SSH. The host then retries activation after networking is usable, persists the output in `C:\ProgramData\vm-stack\activation.log`, and reports the resulting state. Activation failure does not make an otherwise functional test VM unready, but it must remain visible to the caller. An inherited activation state is neither guaranteed to activate another virtual device nor authorization to run more Windows instances; licensing remains the operator's responsibility.

Clone readiness waits up to ten minutes under hardware acceleration and four
hours under TCG. The longer TCG bound covers the same full-system emulation cost
as installation and sealing; an active specialization screen is not treated as
a failed clone merely because it crosses the accelerated-path timeout.

---

### B. Linux VM Provisioning (Ubuntu / Debian / Cloud-Init)

For Linux virtual machines, use `create-linux-vm.sh`. It creates a cloud-init identity and SSH key, a thin overlay over cached upstream media, and a purpose-bound registry entry. Read `use-linux-vm` first when Linux is implied by a test/build request because it owns flavor, GUI, sizing, and retention judgment.

```bash
./skills/create-vm/scripts/create-linux-vm.sh my-ubuntu \
  --os ubuntu --size 20G --memory 2G --cpus 2 \
  --purpose "Run Linux compatibility tests" \
  --release-when "Results and environment metadata are copied out"
```

---

## When to Launch the Desktop Wizard

When human assistance is needed (such as downloading a Windows ISO from Microsoft, custom hardware selection, or visual console monitoring), launch the wizard on the user's desktop:

```bash
./skills/create-vm/scripts/launch-terminal.sh ./skills/create-vm/scripts/create-vm-wizard.sh
```

---

## Script Reference Matrix

| Script | Purpose |
| :--- | :--- |
| **[scripts/launch-terminal.sh](scripts/launch-terminal.sh)** | Spawns any wizard or command in a visible desktop GUI terminal (Terminal.app / iTerm2) for the human user. |
| **[scripts/fetch-media.sh](scripts/fetch-media.sh)** | Downloads and manages ISOs, VirtIO drivers, pinned Win32-OpenSSH installers, and cloud images in `~/.config/vm-stack/media/`. |
| **[scripts/generate-unattend.sh](scripts/generate-unattend.sh)** | Generates the Windows answer file and packages it with the offline guest provisioner and OpenSSH MSI. |
| **[scripts/provision-windows.ps1](scripts/provision-windows.ps1)** | Sole guest-provisioning authority for VirtIO networking, OpenSSH, firewall/default shell configuration, and the readiness marker. |
| **[scripts/prepare-windows-base.ps1](scripts/prepare-windows-base.ps1)** | Records licensing state, removes clone-unsafe identity, defines SYSTEM specialization, and invokes Sysprep. |
| **[scripts/seal-windows-base.sh](scripts/seal-windows-base.sh)** | Orchestrates validation, generalization, shutdown, and immutable base capture through the manager. |
| **[scripts/create-windows-from-base.sh](scripts/create-windows-from-base.sh)** | Creates, boots, verifies, and activation-checks a thin Windows clone. |
| **[scripts/create-windows-vm.sh](scripts/create-windows-vm.sh)** | End-to-end automated runner for Windows 11/10 unattended QEMU provisioning. |
| **[scripts/create-linux-vm.sh](scripts/create-linux-vm.sh)** | Noninteractive Ubuntu/Debian cloud-image provisioning with cloud-init, SSH, and purpose-bound cleanup. |
| **[scripts/create-vm-wizard.sh](scripts/create-vm-wizard.sh)** | Interactive multi-stage terminal setup wizard for human-guided media and VM creation. |
