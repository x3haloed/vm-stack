<#
.SYNOPSIS
    Wrapper alias for sanity-check.ps1
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

$scriptPath = Join-Path $PSScriptRoot "sanity-check.ps1"
& $scriptPath @PSBoundParameters
