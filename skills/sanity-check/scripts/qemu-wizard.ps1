<#
.SYNOPSIS
    Interactive setup wizard for sanity-check on Windows.
#>

[CmdletBinding()]
param(
    [Alias("t")]
    [string]$Target = "x86_64",

    [ValidateSet("auto", "winget", "choco", "scoop", "direct")]
    [string]$InstallMethod = "auto"
)

$scriptPath = Join-Path $PSScriptRoot "sanity-check.ps1"
& $scriptPath -Wizard -Target $Target -InstallMethod $InstallMethod
