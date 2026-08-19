<#
.SYNOPSIS
    Sanity checks the vm-stack environment on Windows:
    1. Ensures ~/.config/vm-stack/ directory exists.
    2. Detects QEMU installation and target emulator binaries.
    3. Verifies Windows Hypervisor Platform (WHPX) acceleration.
    4. Provides an interactive multi-stage wizard for privileged operations.
.DESCRIPTION
    Zero external dependencies (pure PowerShell). Supports WinGet, Chocolatey, Scoop, and direct installer download.
    Includes an interactive multi-stage setup wizard for steps requiring elevated (Administrator) privileges.
.PARAMETER Check
    Check status only without installing (Exit: 0=found, 2=missing).
.PARAMETER Wizard
    Launch interactive multi-stage setup wizard for privileged operations.
.PARAMETER Target
    Target architecture binary to check (e.g. x86_64, aarch64, arm, all) [default: x86_64].
.PARAMETER Json
    Output results in machine-readable JSON format.
.PARAMETER InstallMethod
    Force a specific installation method: auto, winget, choco, scoop, direct [default: auto].
.PARAMETER Quiet
    Suppress non-essential output.
.EXAMPLE
    .\sanity-check.ps1 -Check
    .\sanity-check.ps1 -Wizard
    .\sanity-check.ps1 -Json
#>

[CmdletBinding()]
param(
    [Alias("c", "CheckOnly")]
    [switch]$Check,

    [Alias("w")]
    [switch]$Wizard,

    [Alias("t")]
    [string]$Target = "x86_64",

    [Alias("j")]
    [switch]$Json,

    [ValidateSet("auto", "winget", "choco", "scoop", "direct")]
    [string]$InstallMethod = "auto",

    [Alias("q")]
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"

function Write-InfoLog([string]$message) {
    if (-not $Quiet -and -not $Json) {
        Write-Host "[INFO] $message" -ForegroundColor Cyan
    }
}

function Write-WarnLog([string]$message) {
    if (-not $Json) {
        Write-Host "[WARN] $message" -ForegroundColor Yellow
    }
}

function Write-ErrorLog([string]$message) {
    if (-not $Json) {
        Write-Host "[ERROR] $message" -ForegroundColor Red
    }
}

# ──────────────────────────────────────────────────────────────────────────
# Configuration Directory (~/.config/vm-stack/ or Windows equivalent)
# ──────────────────────────────────────────────────────────────────────────

$ConfigDir = if ($env:XDG_CONFIG_HOME) {
    Join-Path $env:XDG_CONFIG_HOME "vm-stack"
} elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE ".config\vm-stack"
} else {
    Join-Path $env:APPDATA "vm-stack"
}

if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}

# Standard installation paths for QEMU on Windows
$KnownPaths = @(
    "C:\Program Files\qemu",
    "C:\Program Files (x86)\qemu",
    "$env:ProgramData\chocolatey\bin",
    "$env:USERPROFILE\scoop\shims",
    "$env:USERPROFILE\scoop\apps\qemu\current",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
)

# Add discovered paths to current session PATH
foreach ($p in $KnownPaths) {
    if ((Test-Path $p) -and -not ($env:PATH -split ';' -contains $p)) {
        $env:PATH = "$p;$env:PATH"
    }
}

# Scan for QEMU binaries
$CandidateBinaries = @(
    "qemu-img.exe",
    "qemu-system-x86_64.exe",
    "qemu-system-aarch64.exe",
    "qemu-system-arm.exe",
    "qemu-system-i386.exe",
    "qemu-system-riscv64.exe",
    "qemu-system-x86_64w.exe"
)

$FoundBinaries = @{}
function Find-Binaries {
    $FoundBinaries.Clear()
    foreach ($bin in $CandidateBinaries) {
        $cmd = Get-Command $bin -ErrorAction SilentlyContinue
        if ($cmd) {
            $FoundBinaries[$bin] = $cmd.Source
        }
    }
}
Find-Binaries

# Determine target binary
$ReqBinary = "qemu-system-$Target.exe"
if ($Target -eq "all" -or $Target -eq "img") {
    $ReqBinary = "qemu-img.exe"
}

$IsInstalled = $false
$Version = ""

function Check-QemuStatus {
    Find-Binaries
    $script:IsInstalled = $false
    $script:Version = ""

    if ($FoundBinaries.ContainsKey($ReqBinary)) {
        $script:IsInstalled = $true
        try {
            $verOut = & $FoundBinaries[$ReqBinary] --version 2>$null | Select-Object -First 1
            if ($verOut -match 'version\s+([0-9\.]+)') {
                $script:Version = $matches[1]
            }
        } catch {
            $script:Version = "detected"
        }
    } elseif ($Target -eq "all" -and $FoundBinaries.Count -gt 0) {
        $script:IsInstalled = $true
        $firstKey = ($FoundBinaries.Keys | Select-Object -First 1)
        try {
            $verOut = & $FoundBinaries[$firstKey] --version 2>$null | Select-Object -First 1
            if ($verOut -match 'version\s+([0-9\.]+)') {
                $script:Version = $matches[1]
            }
        } catch {
            $script:Version = "detected"
        }
    }
}
Check-QemuStatus

# Check Administrator privileges
$IsAdmin = $false
try {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $IsAdmin = $false
}

# Detect Acceleration (WHPX / Hyper-V)
$AccelType = "whpx"
$AccelSupported = $false
$AccelAccessible = $false
$AccelDetails = "Windows Hypervisor Platform (WHPX) status unknown."
$PrivilegeRequired = $false

function Check-AccelerationStatus {
    try {
        $whpxReg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization" -ErrorAction SilentlyContinue
        if ($whpxReg) {
            $script:AccelSupported = $true
            $script:AccelAccessible = $true
            $script:AccelDetails = "Windows Hypervisor Platform / Hyper-V is enabled (-accel whpx)"
        } else {
            $feat = Get-WindowsOptionalFeature -Online -FeatureName "HypervisorPlatform" -ErrorAction SilentlyContinue
            if ($feat -and $feat.State -eq "Enabled") {
                $script:AccelSupported = $true
                $script:AccelAccessible = $true
                $script:AccelDetails = "Windows Hypervisor Platform feature is Enabled (-accel whpx)"
            } else {
                $script:AccelSupported = $true
                $script:AccelAccessible = $false
                $script:AccelDetails = "Windows Hypervisor Platform is not enabled. Enable with: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform"
                $script:PrivilegeRequired = $true
            }
        }
    } catch {
        $script:AccelDetails = "Enable WHPX for hardware acceleration: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform"
        $script:PrivilegeRequired = $true
    }

    if (-not $IsInstalled -and -not (Get-Command scoop.exe -ErrorAction SilentlyContinue)) {
        if (-not $IsAdmin) {
            $script:PrivilegeRequired = $true
        }
    }
}
Check-AccelerationStatus

# Check available package managers
$AvailablePkgMgrs = @()
if (Get-Command winget.exe -ErrorAction SilentlyContinue) { $AvailablePkgMgrs += "winget" }
if (Get-Command choco.exe -ErrorAction SilentlyContinue) { $AvailablePkgMgrs += "choco" }
if (Get-Command scoop.exe -ErrorAction SilentlyContinue) { $AvailablePkgMgrs += "scoop" }

# ──────────────────────────────────────────────────────────────────────────
# Wizard UI Primitives
# ──────────────────────────────────────────────────────────────────────────

$Global:StageIndex = 0
$Global:TotalStages = 0
$Global:ActionsDone = [System.Collections.Generic.List[string]]::new()
$Global:ActionsSkipped = [System.Collections.Generic.List[string]]::new()

function Clear-Screen {
    if ([Environment]::UserInteractive) {
        try { Clear-Host } catch {}
    }
}

function Show-Banner([string]$title) {
    Clear-Screen
    Write-Host ""
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "  $Global:TotalStages stage(s)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  This setup wizard walks you through verifying the vm-stack environment," -ForegroundColor DarkGray
    Write-Host "  installing QEMU, and configuring Windows Hypervisor Platform (WHPX)." -ForegroundColor DarkGray
    Write-Host "  Privileged steps will prompt for confirmation before execution." -ForegroundColor DarkGray
    Write-Host ""
    Pause-Prompt "Press Enter to start..."
}

function Invoke-Stage([string]$name) {
    Clear-Screen
    $Global:StageIndex++
    Write-Host ""
    Write-Host "▸ Stage $($Global:StageIndex)/$($Global:TotalStages) · $name" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Say([string]$msg) { Write-Host "  $msg" }
function Write-Step([string]$msg) { Write-Host "  • " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Write-Note([string]$msg) { Write-Host "  $msg" -ForegroundColor DarkGray }
function Write-WarnMsg([string]$msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-SuccessMsg([string]$msg) { Write-Host "  ✓ $msg" -ForegroundColor Green }

function Pause-Prompt([string]$msg = "Press Enter to continue") {
    Write-Host "  $msg " -ForegroundColor DarkGray -NoNewline
    [void][System.Console]::ReadLine()
}

function Confirm-Prompt([string]$question) {
    Write-Host "  ? $question [Y/n] " -ForegroundColor Yellow -NoNewline
    $reply = [System.Console]::ReadLine()
    return ([string]::IsNullOrWhiteSpace($reply) -or $reply.Trim() -match '^[Yy]')
}

function Show-Summary {
    Clear-Screen
    Write-Host ""
    Write-Host "  ✓ Sanity Check & Setup Complete" -ForegroundColor Green
    Write-Host ""
    if ($Global:ActionsDone.Count -gt 0) {
        Write-Note "Actions completed:"
        foreach ($act in $Global:ActionsDone) {
            Write-Host "  ✓ " -ForegroundColor Green -NoNewline
            Write-Host $act
        }
        Write-Host ""
    }
    if ($Global:ActionsSkipped.Count -gt 0) {
        Write-WarnMsg "Actions skipped or requiring manual follow-up:"
        foreach ($sk in $Global:ActionsSkipped) {
            Write-Host "  - " -ForegroundColor Yellow -NoNewline
            Write-Host $sk
        }
        Write-Host ""
    }

    Write-Host "  Config Directory: $ConfigDir"
    Write-Host "  Host OS: Windows"
    Write-Host "  QEMU Installed: $(if ($IsInstalled) { "Yes (v$Version)" } else { "No" })"
    Write-Host "  Target Emulator: $(if ($FoundBinaries.ContainsKey($ReqBinary)) { $FoundBinaries[$ReqBinary] } else { "Not found" })"
    Write-Host "  Hardware Acceleration: $AccelDetails"
    Write-Host ""
}

function Install-QemuWindows {
    param([string]$Method)

    $SelectedMethod = $Method
    if ($SelectedMethod -eq "auto") {
        if ($AvailablePkgMgrs -contains "winget") { $SelectedMethod = "winget" }
        elseif ($AvailablePkgMgrs -contains "choco") { $SelectedMethod = "choco" }
        elseif ($AvailablePkgMgrs -contains "scoop") { $SelectedMethod = "scoop" }
        else { $SelectedMethod = "direct" }
    }

    Write-Say "Installing QEMU via $SelectedMethod..."

    switch ($SelectedMethod) {
        "winget" {
            Write-Step "Executing: winget install --id SoftwareFreedomConservancy.QEMU -e --silent"
            winget install --id SoftwareFreedomConservancy.QEMU -e --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Retrying with alternate WinGet ID: StefanWeil.QEMU..."
                winget install --id StefanWeil.QEMU -e --accept-source-agreements --accept-package-agreements --silent
            }
        }
        "choco" {
            Write-Step "Executing: choco install -y qemu"
            choco install -y qemu
        }
        "scoop" {
            Write-Step "Executing: scoop install qemu"
            scoop install qemu
        }
        "direct" {
            Write-Step "Downloading official QEMU 64-bit installer for Windows..."
            $InstallerUrl = "https://qemu.weilnetz.de/w64/qemu-w64-setup-20240904.exe"
            $TempInstaller = "$env:TEMP\qemu-setup.exe"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $TempInstaller -UseBasicParsing
            Write-Step "Executing installer silently into C:\Program Files\qemu..."
            Start-Process -FilePath $TempInstaller -ArgumentList "/S" -Wait
            Remove-Item -Path $TempInstaller -Force -ErrorAction SilentlyContinue
        }
    }
}

function Run-Wizard {
    $Global:ActionsDone.Add("Initialized config directory: $ConfigDir")

    Check-QemuStatus
    Check-AccelerationStatus

    $needInstall = (-not $IsInstalled)
    $needWhpx = (-not $AccelAccessible)

    $Global:TotalStages = 1 # Verification stage always runs
    if ($needInstall) { $Global:TotalStages++ }
    if ($needWhpx) { $Global:TotalStages++ }

    Show-Banner "vm-stack Sanity Check & Setup Wizard (Windows)"

    # Stage: Package Installation
    if ($needInstall) {
        Invoke-Stage "Install QEMU Packages"
        Write-Say "QEMU executables were not detected on this system."

        $method = $InstallMethod
        if ($method -eq "auto") {
            if ($AvailablePkgMgrs -contains "winget") { $method = "winget" }
            elseif ($AvailablePkgMgrs -contains "choco") { $method = "choco" }
            elseif ($AvailablePkgMgrs -contains "scoop") { $method = "scoop" }
            else { $method = "direct" }
        }

        Write-Say "Selected installation method: $method"
        if (-not $IsAdmin -and $method -ne "scoop") {
            Write-Note "Note: Installing via $method may trigger a UAC prompt or require Administrator rights."
        }

        if (Confirm-Prompt "Proceed with QEMU installation via $method?") {
            try {
                Install-QemuWindows -Method $method
                $Global:ActionsDone.Add("Installed QEMU packages via $method")
                Write-SuccessMsg "Installation command completed."
            } catch {
                Write-WarnMsg "Installation encountered an error: $_"
                $Global:ActionsSkipped.Add("QEMU installation failed via $method")
            }
        } else {
            $Global:ActionsSkipped.Add("Package installation skipped by user")
        }
        Check-QemuStatus
    }

    # Stage: WHPX Acceleration
    if ($needWhpx) {
        Invoke-Stage "Configure Windows Hypervisor Platform (WHPX)"
        Write-Say "Hardware acceleration (WHPX) enables near-native VM execution."
        Write-Say "Windows feature 'HypervisorPlatform' can be enabled automatically."
        Write-Host ""
        Write-Host "    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All" -ForegroundColor Cyan
        Write-Host ""

        if (-not $IsAdmin) {
            Write-WarnMsg "Enabling Windows optional features requires an elevated (Administrator) session."
        }

        if (Confirm-Prompt "Enable Windows Hypervisor Platform?") {
            if ($IsAdmin) {
                try {
                    Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart -ErrorAction Stop
                    $Global:ActionsDone.Add("Enabled Windows Hypervisor Platform (WHPX)")
                    Write-SuccessMsg "Windows Hypervisor Platform enabled successfully (restart may be required)."
                } catch {
                    Write-WarnMsg "Failed to enable feature: $_"
                    $Global:ActionsSkipped.Add("WHPX feature enablement failed")
                }
            } else {
                Write-WarnMsg "Skipping in non-elevated session. Please re-run the wizard as Administrator."
                $Global:ActionsSkipped.Add("Enable WHPX in an elevated Administrator PowerShell session")
            }
        } else {
            $Global:ActionsSkipped.Add("WHPX configuration skipped by user")
        }
        Check-AccelerationStatus
    }

    # Stage: Verification & Smoke Test
    Invoke-Stage "Verify QEMU Installation & Smoke Test"
    Write-Say "Verifying binary accessibility and disk image creation..."

    # Re-scan paths
    foreach ($p in $KnownPaths) {
        if ((Test-Path $p) -and -not ($env:PATH -split ';' -contains $p)) {
            $env:PATH = "$p;$env:PATH"
        }
    }
    Check-QemuStatus
    Check-AccelerationStatus

    $smokePassed = $true
    if ($FoundBinaries.ContainsKey("qemu-img.exe")) {
        Write-Step "Testing 'qemu-img.exe' disk creation..."
        $testImg = "$env:TEMP\qemu_test_$([System.Guid]::NewGuid().ToString('N')).qcow2"
        try {
            & $FoundBinaries["qemu-img.exe"] create -f qcow2 $testImg 10M 2>$null | Out-Null
            & $FoundBinaries["qemu-img.exe"] info $testImg 2>$null | Out-Null
            Write-SuccessMsg "qemu-img verification passed."
            Remove-Item $testImg -Force -ErrorAction SilentlyContinue
        } catch {
            Write-WarnMsg "qemu-img test encountered an issue."
            $smokePassed = $false
        }
    } else {
        Write-WarnMsg "'qemu-img.exe' not found in PATH."
        $smokePassed = $false
    }

    if ($FoundBinaries.ContainsKey($ReqBinary)) {
        Write-Step "Testing '$ReqBinary --version'..."
        try {
            $verOut = & $FoundBinaries[$ReqBinary] --version 2>$null | Select-Object -First 1
            Write-SuccessMsg "$ReqBinary is operational ($verOut)."
        } catch {
            Write-WarnMsg "Failed to execute $ReqBinary."
            $smokePassed = $false
        }
    } else {
        Write-WarnMsg "Target emulator '$ReqBinary' not found in PATH."
        $smokePassed = $false
    }

    if ($smokePassed) {
        $Global:ActionsDone.Add("Verification smoke test passed")
    }

    Pause-Prompt "Press Enter to view final summary..."
    Show-Summary
}

# ──────────────────────────────────────────────────────────────────────────
# Execution Routing
# ──────────────────────────────────────────────────────────────────────────

if ($Wizard) {
    Run-Wizard
    exit 0
}

if ($Check) {
    if ($Json) {
        [PSCustomObject]@{
            config_dir         = $ConfigDir
            config_dir_ready   = $true
            installed          = $IsInstalled
            target_arch        = $Target
            version            = $Version
            os                 = "windows"
            package_managers   = $AvailablePkgMgrs
            privilege_required = $PrivilegeRequired
            wizard_recommended = $PrivilegeRequired
            wizard_command     = "powershell -ExecutionPolicy Bypass -File .\scripts\sanity-check.ps1 -Wizard"
            binaries           = $FoundBinaries
            acceleration       = @{
                type       = $AccelType
                supported  = $AccelSupported
                accessible = $AccelAccessible
                details    = $AccelDetails
            }
        } | ConvertTo-Json -Depth 4
    } else {
        Write-InfoLog "Config directory: $ConfigDir (ready)"
        if ($IsInstalled) {
            Write-InfoLog "QEMU is installed (Version: $Version)."
            Write-InfoLog "Target binary: $($FoundBinaries[$ReqBinary])"
            Write-InfoLog "Acceleration ($AccelType): $AccelDetails"
        } else {
            Write-WarnLog "QEMU (target: $Target) is not installed on this Windows system."
            if ($PrivilegeRequired) {
                Write-WarnLog "Installation or WHPX configuration requires elevated privileges."
                Write-InfoLog "Run the interactive wizard: powershell -ExecutionPolicy Bypass -File .\scripts\sanity-check.ps1 -Wizard"
            }
        }
    }
    if ($IsInstalled) { exit 0 } else { exit 2 }
}

# Non-interactive / Default Install Mode
if (-not $IsInstalled) {
    if ([Environment]::UserInteractive -and $PrivilegeRequired) {
        Run-Wizard
        exit 0
    }

    Write-InfoLog "QEMU is not installed. Initiating installation..."
    Install-QemuWindows -Method $InstallMethod

    # Refresh PATH and check again
    foreach ($p in $KnownPaths) {
        if ((Test-Path $p) -and -not ($env:PATH -split ';' -contains $p)) {
            $env:PATH = "$p;$env:PATH"
        }
    }
    Check-QemuStatus
    Check-AccelerationStatus

    if ($IsInstalled) {
        Write-InfoLog "Successfully installed QEMU."
    } else {
        Write-ErrorLog "Installation completed but QEMU executable was not found."
        Write-InfoLog "Launch the interactive setup wizard: powershell -ExecutionPolicy Bypass -File .\scripts\sanity-check.ps1 -Wizard"
        exit 1
    }
}

if ($Json) {
    [PSCustomObject]@{
        config_dir         = $ConfigDir
        config_dir_ready   = $true
        installed          = $IsInstalled
        target_arch        = $Target
        version            = $Version
        os                 = "windows"
        package_managers   = $AvailablePkgMgrs
        privilege_required = $PrivilegeRequired
        wizard_recommended = $PrivilegeRequired
        wizard_command     = "powershell -ExecutionPolicy Bypass -File .\scripts\sanity-check.ps1 -Wizard"
        binaries           = $FoundBinaries
        acceleration       = @{
            type       = $AccelType
            supported  = $AccelSupported
            accessible = $AccelAccessible
            details    = $AccelDetails
        }
    } | ConvertTo-Json -Depth 4
} else {
    Write-InfoLog "Config directory: $ConfigDir (ready)"
    Write-InfoLog "QEMU is installed and ready to use."
}

exit 0
