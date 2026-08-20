$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$stateDirectory = Join-Path $env:ProgramData 'vm-stack'
$logPath = Join-Path $stateDirectory 'provision.log'
$markerPath = Join-Path $stateDirectory 'provisioned'
New-Item -ItemType Directory -Force -Path $stateDirectory | Out-Null
Start-Transcript -Path $logPath -Append | Out-Null

try {
    $unattendVolume = Get-Volume | Where-Object FileSystemLabel -eq 'UNATTEND' | Select-Object -First 1
    if (-not $unattendVolume.DriveLetter) {
        throw 'UNATTEND provisioning media is not mounted.'
    }
    $unattendRoot = "$($unattendVolume.DriveLetter):\"

    $virtioVolume = Get-Volume | Where-Object FileSystemLabel -like 'virtio-win*' | Select-Object -First 1
    if (-not $virtioVolume.DriveLetter) {
        throw 'VirtIO driver media is not mounted.'
    }

    $driverArchitecture = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'ARM64' } else { 'amd64' }
    $netDriver = "$($virtioVolume.DriveLetter):\NetKVM\w11\$driverArchitecture\netkvm.inf"
    if (-not (Test-Path -LiteralPath $netDriver)) {
        throw "VirtIO network driver was not found: $netDriver"
    }
    & pnputil.exe /add-driver $netDriver /install
    if ($LASTEXITCODE -notin @(0, 259)) {
        throw "VirtIO network driver installation failed with exit code $LASTEXITCODE."
    }

    $openSshMsi = Join-Path $unattendRoot 'openssh.msi'
    if (-not (Test-Path -LiteralPath $openSshMsi)) {
        throw "OpenSSH installer was not found: $openSshMsi"
    }
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        $msi = Start-Process msiexec.exe -ArgumentList @('/i', $openSshMsi, '/qn', '/norestart') -Wait -PassThru
        if ($msi.ExitCode -notin @(0, 1641, 3010)) {
            throw "OpenSSH MSI installation failed with exit code $($msi.ExitCode)."
        }
    }

    Set-Service -Name sshd -StartupType Automatic
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }

    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value $powerShellPath -PropertyType String -Force | Out-Null

    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoAdminLogon -Value '0' -PropertyType String -Force | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -ErrorAction SilentlyContinue
    Set-Content -LiteralPath $markerPath -Value 'ok' -Encoding ascii
    Start-Service -Name sshd
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
