param(
    [string]$Username = 'admin',
    [string]$Password = 'admin',
    [switch]$InspectOnly
)

$ErrorActionPreference = 'Stop'
$stateDirectory = Join-Path $env:ProgramData 'vm-stack'
$metadataPath = Join-Path $stateDirectory 'base-license.json'
$firstBootPath = Join-Path $stateDirectory 'first-boot.ps1'
$unattendPath = Join-Path $stateDirectory 'clone-unattend.xml'
$generalizePath = Join-Path $stateDirectory 'generalize-base.ps1'
$sealTaskName = 'vm-stack-seal'

$license = Get-CimInstance SoftwareLicensingProduct |
    Where-Object { $_.Name -like 'Windows*' -and $_.PartialProductKey } |
    Select-Object -First 1
$currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$isEvaluation = ($license.Name -match 'Evaluation') -or ($license.Description -match 'EVAL')
$expiresAt = $null
if ($isEvaluation -and $license.GracePeriodRemaining -gt 0) {
    $expiresAt = (Get-Date).ToUniversalTime().AddMinutes([double]$license.GracePeriodRemaining).ToString('o')
}

[ordered]@{
    product_name = $currentVersion.ProductName
    edition_id = $currentVersion.EditionID
    license_name = $license.Name
    license_description = $license.Description
    license_status = [int]$license.LicenseStatus
    grace_minutes_remaining = [int64]$license.GracePeriodRemaining
    evaluation = [bool]$isEvaluation
    expires_at = $expiresAt
    observed_at = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8

if ($InspectOnly) {
    exit 0
}

@'
$ErrorActionPreference = 'Stop'
$stateDirectory = Join-Path $env:ProgramData 'vm-stack'
Remove-Item -Path (Join-Path $env:ProgramData 'ssh\ssh_host_*') -Force -ErrorAction SilentlyContinue
$sshKeygen = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
& $sshKeygen -A
Set-Service -Name sshd -StartupType Automatic
& cscript.exe //Nologo (Join-Path $env:WINDIR 'System32\slmgr.vbs') /ato 2>&1 | Set-Content -LiteralPath (Join-Path $stateDirectory 'activation.log')
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0' -PropertyType String -Force | Out-Null
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -ErrorAction SilentlyContinue
Set-Content -LiteralPath (Join-Path $stateDirectory 'provisioned') -Value 'ok' -Encoding ascii
Start-Service sshd
Unregister-ScheduledTask -TaskName 'vm-stack-seal' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $stateDirectory 'generalize-base.ps1') -Force -ErrorAction SilentlyContinue
'@ | Set-Content -LiteralPath $firstBootPath -Encoding UTF8

$escapedUsername = [Security.SecurityElement]::Escape($Username)
$escapedPassword = [Security.SecurityElement]::Escape($Password)
$processorArchitecture = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$processorArchitecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine">
      <ComputerName>*</ComputerName>
    </component>
    <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="$processorArchitecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="$processorArchitecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\vm-stack\first-boot.ps1</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="$processorArchitecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$processorArchitecture" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/StateMachine">
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideLocalAccountScreen>true</HideLocalAccountScreen><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><NetworkLocation>Work</NetworkLocation><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><AdministratorPassword><Value>$escapedPassword</Value><PlainText>true</PlainText></AdministratorPassword><LocalAccounts><LocalAccount wcm:action="add"><Description>vm-stack administrator</Description><DisplayName>$escapedUsername</DisplayName><Group>Administrators</Group><Name>$escapedUsername</Name><Password><Value>$escapedPassword</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
    </component>
  </settings>
</unattend>
"@
$xml | Set-Content -LiteralPath $unattendPath -Encoding UTF8

@"
`$ErrorActionPreference = 'Stop'
Stop-Service sshd -Force
Set-Service -Name sshd -StartupType Disabled
Remove-Item -Path (Join-Path $env:ProgramData 'ssh\ssh_host_*') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $stateDirectory 'provisioned') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $stateDirectory 'provision.log') -Force -ErrorAction SilentlyContinue

`$sysprep = Join-Path `$env:WINDIR 'System32\Sysprep\Sysprep.exe'
`$sysprepProcess = Start-Process -FilePath `$sysprep -ArgumentList @('/generalize', '/oobe', '/shutdown', '/mode:vm', '/unattend:$unattendPath') -Wait -PassThru
if (`$sysprepProcess.ExitCode -ne 0) {
    throw "Sysprep failed with exit code `$(`$sysprepProcess.ExitCode). See C:\Windows\System32\Sysprep\Panther for details."
}
"@ | Set-Content -LiteralPath $generalizePath -Encoding UTF8

# Stopping sshd from the SSH-owned PowerShell process also tears down that
# process tree on Windows. Run generalization as SYSTEM in Task Scheduler so
# Sysprep survives the intentional SSH shutdown.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$generalizePath`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $sealTaskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $sealTaskName
