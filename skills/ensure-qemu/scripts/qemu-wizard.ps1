<#
.SYNOPSIS
    Interactive setup wizard for QEMU and virtualization acceleration on Windows.
#>

[CmdletBinding()]
param(
    [Alias("t")]
    [string]$Target = "x86_64",

    [ValidateSet("auto", "winget", "choco", "scoop", "direct")]
    [string]$InstallMethod = "auto"
)

$scriptPath = Join-Path $PSScriptRoot "ensure-qemu.ps1"
& $scriptPath -Wizard -Target $Target -InstallMethod $InstallMethod
