---
name: ensure-qemu
description: Use when verifying, detecting, or installing QEMU (including qemu-img, qemu-system-x86_64, qemu-system-aarch64) or checking virtualization acceleration (KVM, HVF, WHPX) across macOS, Linux distributions, and Windows.
---

# Ensure QEMU

Detects whether QEMU and its virtualization utilities are installed on the local host, verifies hardware acceleration capabilities (KVM, HVF, WHPX), and provides automated verification and an interactive multi-stage setup wizard for operations requiring elevated privileges.

---

## Agent Operational Workflow

When preparing an environment for VM workloads, follow this deterministic decision flow:

```
                      +──────────────────────────+
                      |   Run Detection Check    |
                      | ensure-qemu.sh --check   |
                      +─────────────┬────────────+
                                    │
                         Is QEMU installed and
                         acceleration ready?
                                    │
                     ┌──────────────┴──────────────┐
                     ▼                             ▼
                  [ YES ]                       [ NO ]
                     │                             │
             Proceed with VM task        Does installation or
                                         config need root/sudo?
                                                   │
                                     ┌─────────────┴─────────────┐
                                     ▼                           ▼
                                  [ NO ]                      [ YES ]
                                     │                           │
                            Run Non-Privileged           Pop Open Interactive
                            Install (e.g. brew)          Setup Wizard for User
                                     │                   ensure-qemu.sh --wizard
                                     │                           │
                                     └─────────────┬─────────────┘
                                                   │
                                     Verify with Smoke Test
                                     ensure-qemu.sh --check
```

### 1. Step 1: Discover Environment & Status (Non-Interactive)
Run the check script with `--json` (or `--check`) to inspect host capabilities without making changes:

```bash
# macOS / Linux
./scripts/ensure-qemu.sh --check --json

# Windows (PowerShell)
.\scripts\ensure-qemu.ps1 -Check -Json
```

Inspect the returned JSON object:
- `installed`: `true` / `false`
- `privilege_required`: `true` / `false`
- `acceleration.accessible`: `true` / `false`
- `wizard_command`: Command to invoke the interactive wizard if setup or elevation is required.

### 2. Step 2: Auto-Install When Non-Privileged
If QEMU is missing and the local package manager runs in user space without requiring root privileges (e.g., macOS Homebrew, Linux Nix, Windows Scoop), run the automated installation directly:

```bash
# macOS (Homebrew)
brew install qemu

# Linux (Nix)
nix-env -iA nixpkgs.qemu

# Windows (Scoop)
scoop install qemu
```

### 3. Step 3: Launch Interactive Wizard When Privileged Escalation is Required
If package installation requires `sudo` / root (Debian/Ubuntu `apt`, Fedora `dnf`, Arch `pacman`, Alpine `apk`, openSUSE `zypper`, macOS MacPorts) or if hardware acceleration requires group configuration (`usermod -aG kvm $USER`) or Windows WHPX feature enablement:

> [!IMPORTANT]
> **Never prompt the user with ad-hoc raw terminal commands** like `please run sudo apt install ...`. 
> Instead, pop open the interactive setup wizard so the user is guided through structured, clear stages with confirmation gates and automatic smoke testing.

Launch the wizard in the user's terminal:

```bash
# macOS / Linux
./scripts/ensure-qemu.sh --wizard
# or shortcut:
./scripts/qemu-wizard.sh

# Windows (PowerShell)
.\scripts\ensure-qemu.ps1 -Wizard
# or shortcut:
.\scripts\qemu-wizard.ps1
```

#### Wizard Journey & Stages:
1. **Stage 1: Package Installation**: Identifies the host distribution, displays the exact package command, requests confirmation, and executes elevated installation with real-time feedback.
2. **Stage 2: Hardware Acceleration Configuration**:
   - On Linux: Checks `/dev/kvm` presence, loads kernel modules (`kvm`, `kvm_intel`, `kvm_amd`), and configures `kvm` user group membership.
   - On Windows: Checks and enables Windows Hypervisor Platform (`HypervisorPlatform`).
3. **Stage 3: Smoke Test & PATH Verification**: Creates a temporary test disk with `qemu-img`, verifies target emulator execution (`qemu-system-<arch>`), and displays a closing summary frame.

### 4. Step 4: Final Verification
Re-run the status check to ensure everything is operational:

```bash
./scripts/ensure-qemu.sh --check
```

---

## Command-Line Reference

### macOS & Linux (`ensure-qemu.sh` / `qemu-wizard.sh`)
```bash
# Status check (Exit 0=ready, 2=missing)
./scripts/ensure-qemu.sh --check

# Machine-readable JSON output
./scripts/ensure-qemu.sh --check --json

# Target a specific architecture (e.g. aarch64, arm, x86_64)
./scripts/ensure-qemu.sh --check --target aarch64

# Launch interactive multi-stage wizard
./scripts/ensure-qemu.sh --wizard
./scripts/qemu-wizard.sh
```

### Windows (`ensure-qemu.ps1` / `qemu-wizard.ps1`)
```powershell
# Status check
.\scripts\ensure-qemu.ps1 -Check

# JSON output
.\scripts\ensure-qemu.ps1 -Check -Json

# Target a specific architecture
.\scripts\ensure-qemu.ps1 -Check -Target aarch64

# Launch interactive wizard
.\scripts\ensure-qemu.ps1 -Wizard
.\scripts\qemu-wizard.ps1
```

---

## Installation Reference Matrix

| Platform / Distro | Package Manager | Privileges Required | Key Packages |
| :--- | :--- | :--- | :--- |
| **macOS** | Homebrew | User | `qemu` |
| **macOS** | MacPorts | Root (`sudo`) | `qemu` |
| **Debian / Ubuntu / Mint** | APT | Root (`sudo`) | `qemu-system`, `qemu-utils` |
| **Fedora / RHEL / Rocky** | DNF / YUM | Root (`sudo`) | `qemu-system-x86`, `qemu-system-aarch64`, `qemu-img` |
| **Arch Linux / Manjaro** | Pacman | Root (`sudo`) | `qemu-full` (or `qemu-desktop`) |
| **Alpine Linux** | APK | Root (`sudo`) | `qemu-system-x86_64`, `qemu-system-aarch64`, `qemu-img` |
| **openSUSE** | Zypper | Root (`sudo`) | `qemu-x86`, `qemu-arm`, `qemu-tools` |
| **Gentoo** | Portage | Root (`sudo`) | `app-emulation/qemu` |
| **Void Linux** | XBPS | Root (`sudo`) | `qemu` |
| **Nix** | Nixpkgs | User | `nixpkgs.qemu` |
| **Windows** | Scoop | User | `qemu` |
| **Windows** | WinGet / Choco / Direct | Administrator | QEMU for Windows |

---

## Hardware Acceleration Reference

| Host OS | Acceleration Type | QEMU Flags | Verification Check | Configuration / Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Linux** | KVM | `-accel kvm` or `-enable-kvm` | `test -r /dev/kvm && test -w /dev/kvm` | Add user to group: `sudo usermod -aG kvm $USER`<br>Module: `sudo modprobe kvm` |
| **macOS** | HVF | `-accel hvf` | `sysctl -n kern.hv_support` (returns `1`) | Native Apple Silicon / Intel Hypervisor framework |
| **Windows** | WHPX | `-accel whpx` | `Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform` | Enable feature: `Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform` |

---

## Verification & Smoke Test

To verify disk creation and emulator execution manually:

```bash
# Verify system emulator
qemu-system-x86_64 --version

# Verify disk management utility
qemu-img --version

# Test disk image lifecycle
qemu-img create -f qcow2 test_disk.qcow2 10M
qemu-img info test_disk.qcow2
rm test_disk.qcow2
```
