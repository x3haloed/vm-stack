# Windows 11 / Windows 10 Unattended Provisioning Reference

This reference explains the zero-touch automated unattended installation pipeline implemented in `vm-stack`.

## 1. Architecture Matrix

| Host Architecture | Guest OS Target | QEMU Binary | Acceleration | Firmware |
| :--- | :--- | :--- | :--- | :--- |
| **Apple Silicon (ARM64)** | Windows 11 ARM64 | `qemu-system-aarch64` | `-accel hvf` | `edk2-aarch64-code.fd` + `_vars.fd` |
| **Intel / AMD (x86_64)** | Windows 11 x86_64 | `qemu-system-x86_64` | `-accel hvf` / `kvm` | `edk2-x86_64-code.fd` + `_vars.fd` |

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
