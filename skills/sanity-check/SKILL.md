---
name: sanity-check
description: Use when verifying the local vm-stack environment, ensuring ~/.config/vm-stack/ and preferences.json exist, detecting or installing QEMU (including qemu-img, qemu-system-x86_64, qemu-system-aarch64), and checking virtualization acceleration (KVM, HVF, WHPX) across macOS, Linux distributions, and Windows.
---

# Sanity Check

Verifies the host environment for `vm-stack`, ensures the configuration directory `~/.config/vm-stack/` and preferences file `~/.config/vm-stack/preferences.json` exist, detects QEMU and its virtualization utilities, checks hardware acceleration capabilities (KVM, HVF, WHPX), and provides automated verification alongside an interactive multi-stage setup wizard for operations requiring elevated privileges.

- Schema definition: [schemas/preferences.schema.json](file:///Users/chad/Repos/vm-stack/schemas/preferences.schema.json)

---

## Preferences Configuration (`~/.config/vm-stack/preferences.json`)

The sanity-check routine automatically initializes `~/.config/vm-stack/preferences.json` (or platform equivalent) conforming to the bundled schema:

```json
{
  "version": 1,
  "cache_os_images": true,
  "default_arch": "auto",
  "default_memory": "4G",
  "default_cpus": 2,
  "default_accel": "auto",
  "images_dir": "",
  "cache_dir": ""
}
```

### Key Preference Fields:
- **`cache_os_images`** *(boolean, default: `true`)*: Whether to cache downloaded base cloud/OS images locally in `~/.config/vm-stack/cache/` for fast VM provisioning.
- **`default_arch`** *(string, default: `"auto"`)*: Preferred target architecture (`aarch64`, `x86_64`, or `auto`).
- **`default_memory`** *(string, default: `"4G"`)*: Default RAM allocation for newly provisioned VMs.
- **`default_cpus`** *(integer, default: `2`)*: Default virtual CPU core count.
- **`default_accel`** *(string, default: `"auto"`)*: Default acceleration framework (`hvf` on macOS, `kvm` on Linux, `whpx` on Windows).
- **`images_dir`** *(string)*: Custom override path for VM disk images (defaults to `~/.config/vm-stack/images/`).
- **`cache_dir`** *(string)*: Custom override path for cached OS images (defaults to `~/.config/vm-stack/cache/`).

---

## Agent Operational Workflow

When preparing an environment for VM workloads, follow this deterministic decision flow:

```
                      +──────────────────────────+
                      |   Run Sanity Check       |
                      | sanity-check.sh --check  |
                      | Ensures:                 |
                      |  - ~/.config/vm-stack/   |
                      |  - preferences.json      |
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
                            Run Non-Privileged           Pop Open Desktop
                            Install (e.g. brew)          Setup Wizard for User
                                     │                   launch-terminal.sh ...
                                     │                           │
                                     └─────────────┬─────────────┘
                                                   │
                                     Verify with Smoke Test
                                     sanity-check.sh --check
```

### 1. Step 1: Discover Environment & Status (Non-Interactive)
Run the check script with `--json` (or `--check`) to inspect host capabilities and initialize configuration without making intrusive system changes:

```bash
# macOS / Linux
./skills/sanity-check/scripts/sanity-check.sh --check --json

# Windows (PowerShell)
.\skills\sanity-check\scripts\sanity-check.ps1 -Check -Json
```

Inspect the returned JSON object:
- `config_dir`: Path to `~/.config/vm-stack/`
- `config_dir_ready`: `true`
- `preferences_file`: Path to `~/.config/vm-stack/preferences.json`
- `preferences_ready`: `true`
- `preferences.cache_os_images`: `true` / `false`
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

### 3. Step 3: Launch Desktop Wizard When Privileged Escalation is Required
If package installation requires `sudo` / root (Debian/Ubuntu `apt`, Fedora `dnf`, Arch `pacman`, Alpine `apk`, openSUSE `zypper`, macOS MacPorts) or if hardware acceleration requires group configuration (`usermod -aG kvm $USER`) or Windows WHPX feature enablement:

> [!IMPORTANT]
> **Never run the interactive wizard inside a background subshell or agent tool call (`run_command`).**
> Agent tool subshells have no interactive TTY or keyboard access, which causes tasks to hang.
> 
> **Always launch the wizard in a visible terminal window on the user's desktop** using `launch-terminal.sh`:
> ```bash
> ./skills/sanity-check/scripts/launch-terminal.sh ./skills/sanity-check/scripts/sanity-check.sh --wizard
> ```

---

## Command-Line Reference

### macOS & Linux (`sanity-check.sh` / `launch-terminal.sh`)
```bash
# Status check & preferences initialization (Exit 0=ready, 2=missing)
./skills/sanity-check/scripts/sanity-check.sh --check

# Machine-readable JSON output
./skills/sanity-check/scripts/sanity-check.sh --check --json

# Target a specific architecture (e.g. aarch64, arm, x86_64)
./skills/sanity-check/scripts/sanity-check.sh --check --target aarch64

# Launch interactive wizard on the user's desktop
./skills/sanity-check/scripts/launch-terminal.sh ./skills/sanity-check/scripts/sanity-check.sh --wizard
```

### Windows (`sanity-check.ps1` / `qemu-wizard.ps1`)
```powershell
# Status check & preferences initialization
.\skills\sanity-check\scripts\sanity-check.ps1 -Check

# JSON output
.\skills\sanity-check\scripts\sanity-check.ps1 -Check -Json

# Target a specific architecture
.\skills\sanity-check\scripts\sanity-check.ps1 -Check -Target aarch64

# Launch interactive wizard
.\skills\sanity-check\scripts\sanity-check.ps1 -Wizard
.\skills\sanity-check\scripts\qemu-wizard.ps1
```
