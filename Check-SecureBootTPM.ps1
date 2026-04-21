#Requires -Version 5.1
<#
Diagnoses why Windows / an application reports Secure Boot or TPM 2.0 as
missing even when the BIOS shows them enabled.

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Check-SecureBootTPM.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Write-Section($title) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host $title -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}

function Write-Result {
    param(
        [string]$Label,
        [string]$Value,
        [ValidateSet('OK','WARN','FAIL','INFO')][string]$Status = 'INFO'
    )
    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    '{0,-34} {1}' -f ($Label + ':'), $Value | Write-Host -ForegroundColor $color
}

$findings = [System.Collections.Generic.List[string]]::new()
function Add-Finding([string]$msg) { $findings.Add($msg) }

# ---- Admin check ----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
           [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'WARNING: not elevated. Some checks (TPM, BCD) will be incomplete.' -ForegroundColor Yellow
}

# ---- Firmware / boot mode -------------------------------------------------
Write-Section 'Firmware and boot mode'

$firmwareType = 'Unknown'
try {
    $sig = '[DllImport("kernel32.dll")] public static extern uint GetFirmwareType(out uint FirmwareType);'
    $k32 = Add-Type -MemberDefinition $sig -Name 'K32FW' -Namespace 'Win32' -PassThru
    $ft = 0
    [void]$k32::GetFirmwareType([ref]$ft)
    $firmwareType = switch ($ft) { 1 { 'BIOS (Legacy)' } 2 { 'UEFI' } default { "Unknown ($ft)" } }
} catch { $firmwareType = "Error: $_" }

Write-Result 'Firmware type' $firmwareType ($(if ($firmwareType -eq 'UEFI') {'OK'} else {'FAIL'}))
if ($firmwareType -ne 'UEFI') {
    Add-Finding 'System is not booted in UEFI mode. Secure Boot and modern TPM attestation REQUIRE UEFI. Disable CSM/Legacy in BIOS and, if the disk is MBR, convert to GPT with `mbr2gpt`.'
}

# ---- Disk partition style -------------------------------------------------
try {
    $sysDrive = ($env:SystemDrive).TrimEnd(':')
    $part = Get-Partition -DriveLetter $sysDrive -ErrorAction Stop
    $disk = Get-Disk -Number $part.DiskNumber
    Write-Result 'System disk partition style' $disk.PartitionStyle ($(if ($disk.PartitionStyle -eq 'GPT') {'OK'} else {'FAIL'}))
    if ($disk.PartitionStyle -ne 'GPT') {
        Add-Finding "System disk is $($disk.PartitionStyle). Secure Boot requires GPT. Convert with: mbr2gpt /validate /disk:$($disk.Number) /allowFullOS  (then /convert)."
    }
} catch {
    Write-Result 'System disk partition style' "Error: $_" 'WARN'
}

# ---- Secure Boot ----------------------------------------------------------
Write-Section 'Secure Boot'

try {
    $sb = Confirm-SecureBootUEFI -ErrorAction Stop
    Write-Result 'Confirm-SecureBootUEFI' $sb ($(if ($sb) {'OK'} else {'FAIL'}))
    if (-not $sb) {
        Add-Finding 'Secure Boot is disabled in Windows. BIOS may show "Enabled" while actually being in Setup Mode (no keys enrolled). In BIOS: load/restore factory default Secure Boot keys (PK/KEK/db/dbx) and set Secure Boot to "Enabled" with Platform Key present.'
    }
} catch [System.PlatformNotSupportedException] {
    Write-Result 'Confirm-SecureBootUEFI' 'Not supported (Legacy BIOS)' 'FAIL'
    Add-Finding 'Confirm-SecureBootUEFI reports the platform is not UEFI. Same fix as firmware-type finding.'
} catch {
    Write-Result 'Confirm-SecureBootUEFI' "Error: $_" 'WARN'
}

# msinfo32-equivalent data from registry / WMI
try {
    $secureBootState = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled
    Write-Result 'Registry UEFISecureBootEnabled' $secureBootState
} catch {
    Write-Result 'Registry UEFISecureBootEnabled' 'Not present' 'WARN'
}

try {
    $setupMode = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).SetupMode
    if ($null -ne $setupMode) {
        Write-Result 'Secure Boot SetupMode' $setupMode ($(if ($setupMode -eq 0) {'OK'} else {'WARN'}))
        if ($setupMode -ne 0) {
            Add-Finding 'Platform is in Secure Boot Setup Mode (no Platform Key enrolled). In BIOS, restore/install default Secure Boot keys.'
        }
    }
} catch { }

# ---- TPM ------------------------------------------------------------------
Write-Section 'TPM'

try {
    $tpm = Get-Tpm -ErrorAction Stop
    Write-Result 'TpmPresent'       $tpm.TpmPresent       ($(if ($tpm.TpmPresent)      {'OK'} else {'FAIL'}))
    Write-Result 'TpmReady'          $tpm.TpmReady          ($(if ($tpm.TpmReady)          {'OK'} else {'FAIL'}))
    Write-Result 'TpmEnabled'        $tpm.TpmEnabled        ($(if ($tpm.TpmEnabled)        {'OK'} else {'FAIL'}))
    Write-Result 'TpmActivated'      $tpm.TpmActivated      ($(if ($tpm.TpmActivated)      {'OK'} else {'FAIL'}))
    Write-Result 'TpmOwned'          $tpm.TpmOwned
    Write-Result 'ManagedAuthLevel'  $tpm.ManagedAuthLevel
    if (-not $tpm.TpmReady) {
        Add-Finding 'TPM is present but "not ready for use". Open tpm.msc -> Clear TPM (you will need to physically confirm at next boot). Or run: Initialize-Tpm -AllowClear -AllowPhysicalPresence.'
    }
} catch {
    Write-Result 'Get-Tpm' "Error: $_" 'FAIL'
    Add-Finding 'Get-Tpm failed. Run PowerShell as Administrator. If the cmdlet is missing, TPM management tools are not installed or TPM is not exposed to the OS.'
}

try {
    $tpmWmi = Get-CimInstance -Namespace 'Root\CIMv2\Security\MicrosoftTpm' `
                              -ClassName Win32_Tpm -ErrorAction Stop
    $spec = $tpmWmi.SpecVersion
    Write-Result 'SpecVersion (raw)' $spec
    $major = ($spec -split ',')[0].Trim()
    $is20 = $major -like '2.0*'
    Write-Result 'TPM 2.0 detected' $is20 ($(if ($is20) {'OK'} else {'FAIL'}))
    Write-Result 'ManufacturerIdTxt' $tpmWmi.ManufacturerIdTxt
    Write-Result 'ManufacturerVersion' $tpmWmi.ManufacturerVersion
    Write-Result 'PhysicalPresenceVersionInfo' $tpmWmi.PhysicalPresenceVersionInfo
    if (-not $is20) {
        Add-Finding 'TPM is reporting a spec version below 2.0. In BIOS switch TPM mode from 1.2 to 2.0 (Intel: "PTT"; AMD: "fTPM" / "AMD CPU fTPM"). On some boards both a discrete TPM header and firmware TPM exist — pick one.'
    }
} catch {
    Write-Result 'Win32_Tpm WMI'   "Error: $_" 'WARN'
    Add-Finding 'Win32_Tpm WMI class is not responding. Windows is not seeing the TPM at all. In BIOS make sure TPM / PTT / fTPM is enabled AND exposed to the OS, then reboot. On some boards you must also disable "Hide TPM".'
}

# ---- PCR banks (apps like BitLocker / attestation want SHA-256) -----------
try {
    $pcr = & tpmtool getdeviceinformation 2>$null
    if ($LASTEXITCODE -eq 0 -and $pcr) {
        Write-Section 'tpmtool getdeviceinformation'
        $pcr | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        if ($pcr -match 'PCR banks\s*:\s*(.*)') {
            $banks = $Matches[1]
            if ($banks -notmatch 'SHA-?256') {
                Add-Finding "Active PCR banks = '$banks'. Some apps require SHA-256. Allocate it in BIOS TPM settings or via tpm.msc."
            }
        }
    }
} catch { }

# ---- BCD boot entry -------------------------------------------------------
Write-Section 'Boot configuration (bcdedit)'
try {
    $bcd = & bcdedit /enum '{current}' 2>$null
    if ($LASTEXITCODE -eq 0) {
        $bcd | Select-String -Pattern '^(path|device|identifier)' | ForEach-Object {
            Write-Host "  $($_.Line)" -ForegroundColor Gray
        }
        if ($bcd -match 'winload\.exe') {
            Add-Finding 'Boot loader is winload.EXE (Legacy). UEFI should use winload.EFI. This confirms Legacy/CSM boot.'
        }
    }
} catch { }

# ---- Device Guard / VBS status (what many apps actually query) ------------
Write-Section 'Device Guard / VBS'
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard `
          -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
    Write-Result 'VirtualizationBasedSecurityStatus' $dg.VirtualizationBasedSecurityStatus
    Write-Result 'SecurityServicesRunning' ($dg.SecurityServicesRunning -join ',')
    Write-Result 'RequiredSecurityProperties' ($dg.RequiredSecurityProperties -join ',')
    Write-Result 'AvailableSecurityProperties' ($dg.AvailableSecurityProperties -join ',')
} catch {
    Write-Result 'Win32_DeviceGuard' "Error: $_" 'WARN'
}

# ---- Summary --------------------------------------------------------------
Write-Section 'Summary'
if ($findings.Count -eq 0) {
    Write-Host 'No issues detected. Secure Boot is active and TPM 2.0 is ready.' -ForegroundColor Green
    Write-Host 'If an app still reports otherwise, it may be checking HVCI / Memory Integrity or a specific attestation, not Secure Boot / TPM themselves.' -ForegroundColor Gray
} else {
    for ($i = 0; $i -lt $findings.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $findings[$i]) -ForegroundColor Yellow
    }
}
