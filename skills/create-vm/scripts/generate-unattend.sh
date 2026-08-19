#!/usr/bin/env bash
# ==============================================================================
# generate-unattend.sh
# Generates automated Windows 11/10 autounattend.xml and packages into an
# unattended ISO (unattend.iso) for automated zero-touch QEMU installation.
# ==============================================================================

set -euo pipefail

# Terminal styling
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
  BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
  BLUE=$(tput setaf 4); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
  BOLD=""; DIM=""; RESET=""; BLUE=""; GREEN=""; YELLOW=""; RED=""
fi

log_info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
log_error() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat << EOF
${BOLD}Usage:${RESET} generate-unattend.sh [options]

Generates Windows unattended installation files and builds unattend.iso.

${BOLD}Options:${RESET}
  -o, --output <path>        Output ISO path [default: ~/.config/vm-stack/media/unattend.iso]
  -a, --arch <arch>          Target architecture (arm64, amd64) [default: auto-detected]
  -u, --username <user>      Default local admin username [default: admin]
  -p, --password <pass>      Default local admin password [default: admin]
  -n, --hostname <name>      Computer hostname [default: WINDOWS-VM]
  --xml-only <path>          Output raw autounattend.xml file only (skip ISO)
  -h, --help                 Show this help message
EOF
}

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vm-stack"
OUTPUT_ISO="$CONFIG_DIR/media/unattend.iso"
XML_ONLY=""
USERNAME="admin"
PASSWORD="admin"
HOSTNAME="WINDOWS-VM"
TARGET_ARCH="arm64"

# Auto-detect architecture
host_m="$(uname -m 2>/dev/null || echo "arm64")"
if [[ "$host_m" = "x86_64" || "$host_m" = "amd64" ]]; then
  TARGET_ARCH="amd64"
else
  TARGET_ARCH="arm64"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      OUTPUT_ISO="$2"
      shift 2
      ;;
    -a|--arch)
      if [[ "$2" = "x86_64" || "$2" = "amd64" ]]; then
        TARGET_ARCH="amd64"
      else
        TARGET_ARCH="arm64"
      fi
      shift 2
      ;;
    -u|--username)
      USERNAME="$2"
      shift 2
      ;;
    -p|--password)
      PASSWORD="$2"
      shift 2
      ;;
    -n|--hostname)
      HOSTNAME="$2"
      shift 2
      ;;
    --xml-only)
      XML_ONLY="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

generate_xml_content() {
  cat << EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <!-- Pass 1: Windows PE (LabConfig Bypass + Disk Partitioning) -->
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="${TARGET_ARCH}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <!-- Bypass Windows 11 TPM, SecureBoot, RAM, CPU & Storage checks -->
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

            <!-- Automatic Disk Partitioning (Target NVMe Disk 0) -->
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                    <CreatePartitions>
                        <!-- EFI System Partition -->
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Type>EFI</Type>
                            <Size>100</Size>
                        </CreatePartition>
                        <!-- MSR Partition -->
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Type>MSR</Type>
                            <Size>128</Size>
                        </CreatePartition>
                        <!-- Windows Primary Partition -->
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Type>Primary</Type>
                            <Extend>true</Extend>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>FAT32</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>3</PartitionID>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
                            <Letter>C</Letter>
                        </ModifyPartition>
                    </ModifyPartitions>
                </Disk>
            </DiskConfiguration>

            <ImageInstall>
                <OSImage>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                    <WillShowUI>OnError</WillShowUI>
                </OSImage>
            </ImageInstall>

            <UserData>
                <AcceptEula>true</AcceptEula>
                <FullName>${USERNAME}</FullName>
                <Organization>vm-stack</Organization>
            </UserData>
        </component>
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="${TARGET_ARCH}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>

    <!-- Pass 4: Specialize (Hostname & Network) -->
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="${TARGET_ARCH}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>${HOSTNAME}</ComputerName>
            <TimeZone>UTC</TimeZone>
        </component>
    </settings>

    <!-- Pass 7: OOBE System (Local Account + OpenSSH / WinRM Setup) -->
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="${TARGET_ARCH}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <AutoLogon>
                <Password>
                    <Value>${PASSWORD}</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>5</LogonCount>
                <Username>${USERNAME}</Username>
            </AutoLogon>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreens>true</HideOEMRegistrationScreens>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <AdministratorPassword>
                    <Value>${PASSWORD}</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Description>Default Administrator Account</Description>
                        <DisplayName>${USERNAME}</DisplayName>
                        <Group>Administrators</Group>
                        <Name>${USERNAME}</Name>
                        <Password>
                            <Value>${PASSWORD}</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <FirstLogonCommands>
                <!-- Enable OpenSSH Server on First Boot -->
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType 'Automatic'; New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22"</CommandLine>
                    <Description>Enable OpenSSH Server</Description>
                </SynchronousCommand>
                <!-- Configure WinRM -->
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>powershell -Command "Set-NetFirewallRule -DisplayGroup 'Windows Remote Management' -Enabled True"</CommandLine>
                    <Description>Enable WinRM Firewall Rules</Description>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
EOF
}

if [[ -n "$XML_ONLY" ]]; then
  mkdir -p "$(dirname "$XML_ONLY")" 2>/dev/null || true
  generate_xml_content > "$XML_ONLY"
  log_info "Generated raw XML: $XML_ONLY"
  exit 0
fi

# Build unattend.iso
mkdir -p "$(dirname "$OUTPUT_ISO")" 2>/dev/null || true
TEMP_ISO_DIR="$(mktemp -d -t vm_unattend_XXXXXX)"
generate_xml_content > "$TEMP_ISO_DIR/autounattend.xml"

log_info "Building unattend ISO (${TARGET_ARCH}) -> $OUTPUT_ISO"

if command -v hdiutil >/dev/null 2>&1; then
  # Native macOS ISO generation
  hdiutil makehybrid -o "$OUTPUT_ISO" -iso -joliet -default-volume-name UNATTEND "$TEMP_ISO_DIR" >/dev/null 2>&1
elif command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -o "$OUTPUT_ISO" -V UNATTEND -J -r "$TEMP_ISO_DIR" >/dev/null 2>&1
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -o "$OUTPUT_ISO" -V UNATTEND -J -r "$TEMP_ISO_DIR" >/dev/null 2>&1
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -o "$OUTPUT_ISO" -V UNATTEND -J -r "$TEMP_ISO_DIR" >/dev/null 2>&1
else
  log_error "No tool found to create ISO (hdiutil, xorriso, mkisofs, genisoimage)."
  rm -rf "$TEMP_ISO_DIR"
  exit 1
fi

rm -rf "$TEMP_ISO_DIR"
log_info "Created unattended setup media: $OUTPUT_ISO"
exit 0
