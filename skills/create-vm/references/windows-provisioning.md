# Windows 11 / Windows 10 Unattended Provisioning Reference

This reference explains the zero-touch automated unattended installation pipeline implemented in `vm-stack`.

## 1. Architecture Matrix

| Host Architecture | Guest OS Target | QEMU Binary | Acceleration | Firmware |
| :--- | :--- | :--- | :--- | :--- |
| **Apple Silicon (ARM64)** | Windows 11 ARM64 | `qemu-system-aarch64` | `-accel hvf` | `edk2-aarch64-code.fd` + `_vars.fd` |
| **Apple Silicon (ARM64)** | Windows 11 x86_64 | `qemu-system-x86_64` | `-accel tcg` (explicit, slow) | `edk2-x86_64-code.fd` + `_vars.fd` |
| **Intel / AMD (x86_64)** | Windows 11 x86_64 | `qemu-system-x86_64` | `-accel hvf` / `kvm` | `edk2-x86_64-code.fd` + `_vars.fd` |

The cross-architecture row uses QEMU's Tiny Code Generator for full-system CPU
emulation. HVF does not translate x86-64 instructions onto an ARM64 host. The
creator therefore requires the caller to opt in with
`--arch x86_64 --accel tcg`, emits a performance warning, and uses a four-hour
default readiness timeout. The guest still executes x86-64 Windows and x86-64
applications; the distinction is execution speed and accelerator, not guest
architecture.

## 2. LabConfig Registry Bypasses

Windows 11 requires TPM 2.0, SecureBoot, and minimum CPU/RAM requirements by default. In QEMU environments without emulated TPM chips, `generate-unattend.sh` injects `LabConfig` registry keys during Pass 1 (`windowsPE`):

```xml
<RunSynchronous>
    <RunSynchronousCommand wcm:action="add">
        <Order>1</Order>
        <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
    <RunSynchronousCommand wcm:action="add">
        <Order>2</Order>
        <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
    <RunSynchronousCommand wcm:action="add">
        <Order>3</Order>
        <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
    <RunSynchronousCommand wcm:action="add">
        <Order>4</Order>
        <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
    <RunSynchronousCommand wcm:action="add">
        <Order>5</Order>
        <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
    </RunSynchronousCommand>
</RunSynchronous>
```

## 3. NVMe & VirtIO Storage Strategy

- Rather than relying on IDE/SCSI which requires 3rd-party drivers in WinPE, `vm-stack` attaches the primary VM disk as a native **NVMe** device (`-device nvme,drive=hd0,serial=nvme0`).
- Windows 10 and 11 include an inbox NVMe driver out of the box, ensuring the disk is recognized immediately without manual driver loading during WinPE setup.
- The installation ISO and unattend ISO are attached as native USB storage devices (`-device usb-storage`), eliminating "Missing CD/DVD drive device driver" prompts.

## 4. Deterministic Offline Guest Provisioning

The unattended ISO contains three root-level artifacts: `autounattend.xml`, a pinned and checksum-verified Win32-OpenSSH MSI, and `provision-windows.ps1`. The `oobeSystem` pass invokes only that script. Keeping guest changes behind one command avoids ordering races between multiple `FirstLogonCommands`.

The provisioner:

1. Locates the `UNATTEND` and VirtIO volumes by label.
2. Installs the architecture-matched VirtIO network driver.
3. Installs the bundled OpenSSH MSI without depending on Windows Update.
4. configures `sshd` for automatic startup, the firewall rule, and Windows PowerShell as the default SSH shell.
5. Removes automatic-logon credentials and writes `C:\ProgramData\vm-stack\provisioned` before starting `sshd`.

`create-windows-vm.sh` does not treat an open TCP port alone as success. It waits for an SSH protocol banner and then reads the provisioning marker through `manage-vms.sh exec`. The Windows guest is therefore ready for managed execution when the creator exits successfully.

## 5. OOBE Automation

The answer file supplies locale settings and creates the requested local administrator in the supported `oobeSystem` configuration. It hides the applicable OOBE pages without using the deprecated `SkipMachineOOBE` setting. A fresh acceptance run must reach SSH readiness without keyboard or mouse input; an interactive OOBE screen is a provisioning failure, not an invitation to advance it manually.

## 6. Sealed Bases and Licensing

A sealed base is a generalized, immutable QCOW2 image plus immutable firmware state and JSON metadata. It is not a running snapshot. Each VM created from it owns a small writable overlay and a writable copy of firmware variables.

After a wizard-driven Windows installation passes managed readiness, the wizard offers to run the sealing workflow. This is an explicit opt-in because Sysprep removes machine-specific identity and shuts down the source VM. Declining preserves an ordinary provisioned VM.

Under full-system x86_64 emulation on an ARM host, Sysprep can take several hours. The sealing wrapper therefore allows up to four hours for the generalized guest to shut down before it reports failure.

Before sealing, `prepare-windows-base.ps1` records the Windows edition, channel, `LicenseStatus`, remaining grace time, whether the SKU is Evaluation media, and a computed expiration when available. Evaluation media is refused by default. `manage-vms.sh create-from-base` rejects an expired base and warns when fewer than 14 days remain.

Sysprep removes machine-specific Windows state but preserves the prepared local administrator. The clone answer file must not try to add that account again. It performs one automatic logon with the preserved credentials, then a `FirstLogonCommands` provisioner generates new OpenSSH host keys, disables and removes automatic-logon credentials, creates the readiness marker, and starts `sshd`. Readiness therefore follows a real usable desktop rather than the earlier `specialize` pass. Activation is retried after networking is available. Its output is persisted at `C:\ProgramData\vm-stack\activation.log` and printed by the creator. Activation failure is reported separately from VM readiness: a clone may be technically usable while Windows remains in Notification mode. Cloning an activated disk neither guarantees activation of another virtual device nor grants licenses for the clones.

Hardware-accelerated clones use a ten-minute readiness timeout. TCG clones use
the four-hour bound shared by cross-architecture installation and sealing,
because first-boot specialization also executes entirely through emulation.
