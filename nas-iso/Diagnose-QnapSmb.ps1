#Requires -Version 5.1
<#
Diagnoses why a Windows client cannot open an SMB share on a QNAP NAS.
Walks the stack: DNS -> ICMP -> TCP 445/139 -> SMB dialect negotiation ->
auth -> share enumeration. Prints the specific knob to change for any
failing layer.

Run from an *elevated* PowerShell prompt:
    powershell -ExecutionPolicy Bypass -File .\Diagnose-QnapSmb.ps1 -Server servernas

Optional:
    -Share Multimedia      # try a specific share name
    -User  myuser          # try a specific credential
#>

[CmdletBinding()]
param(
    [string]$Server = 'servernas',
    [string]$Share  = '',
    [string]$User   = ''
)

$ErrorActionPreference = 'Continue'
$findings = [System.Collections.Generic.List[string]]::new()

function Sec($t) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host $t -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkGray
}
function Res($label, $value, $status = 'INFO') {
    $color = @{OK='Green'; WARN='Yellow'; FAIL='Red'; INFO='Gray'}[$status]
    '{0,-36} {1}' -f ($label + ':'), $value | Write-Host -ForegroundColor $color
}
function Add-Fix($msg) { $findings.Add($msg) }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'WARNING: not elevated. Some checks (SMB client config, services) will be skipped.' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 1. Name resolution
# ---------------------------------------------------------------------------
Sec "1. Name resolution for '$Server'"
$ip = $null
try {
    $dns = Resolve-DnsName -Name $Server -ErrorAction Stop |
           Where-Object { $_.QueryType -in 'A','AAAA' } | Select-Object -First 1
    $ip = $dns.IPAddress
    Res 'DNS / mDNS / NetBIOS' $ip 'OK'
} catch {
    Res 'Resolve-DnsName' "FAIL ($_)" 'FAIL'
    Add-Fix "Windows cannot resolve '$Server'. Options: add a hosts entry (C:\Windows\System32\drivers\etc\hosts), enable NetBIOS over TCP/IP on the adapter, enable mDNS (Windows 10 2004+ supports .local), or use the QNAP's IP directly in the UNC path (\\192.168.x.x\share)."
}

# ---------------------------------------------------------------------------
# 2. Reachability
# ---------------------------------------------------------------------------
if ($ip) {
    Sec "2. Reachability of $ip"
    $ping = Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue
    Res 'ICMP ping' $ping ($(if($ping){'OK'}else{'WARN'}))
    if (-not $ping) {
        Add-Fix "ICMP is blocked or NAS is offline. Many firewalls drop ping but allow SMB - continue to port test."
    }

    foreach ($p in 445, 139, 8080, 443) {
        $t = Test-NetConnection -ComputerName $ip -Port $p -WarningAction SilentlyContinue
        $label = switch ($p) {
            445 {'TCP 445 (SMB direct)'}
            139 {'TCP 139 (NetBIOS)'}
            8080{'TCP 8080 (QNAP web UI)'}
            443 {'TCP 443 (QNAP HTTPS)'}
        }
        Res $label $t.TcpTestSucceeded ($(if($t.TcpTestSucceeded){'OK'}else{'FAIL'}))
        if ($p -eq 445 -and -not $t.TcpTestSucceeded) {
            Add-Fix "TCP 445 is unreachable. On the QNAP: Control Panel -> Network & File Services -> Microsoft Networking -> enable SMB and check 'Enable SMB v2/v3'. Also: QNAP Security Counselor / firewall, and the Windows network profile (must be Private not Public)."
        }
    }
}

# ---------------------------------------------------------------------------
# 3. Windows network profile
# ---------------------------------------------------------------------------
Sec '3. Windows network profile'
try {
    Get-NetConnectionProfile | ForEach-Object {
        $s = if ($_.NetworkCategory -eq 'Public') {'FAIL'} else {'OK'}
        Res ("  " + $_.InterfaceAlias) $_.NetworkCategory $s
        if ($_.NetworkCategory -eq 'Public') {
            Add-Fix "Adapter '$($_.InterfaceAlias)' is on a Public network. SMB outbound is restricted. Fix: Set-NetConnectionProfile -InterfaceAlias '$($_.InterfaceAlias)' -NetworkCategory Private"
        }
    }
} catch { Res 'Get-NetConnectionProfile' "Error: $_" 'WARN' }

# ---------------------------------------------------------------------------
# 4. SMB client configuration
# ---------------------------------------------------------------------------
Sec '4. SMB client configuration on this PC'
try {
    $cfg = Get-SmbClientConfiguration
    Res 'EnableSMB1Protocol'      $cfg.EnableSMB1Protocol      ($(if($cfg.EnableSMB1Protocol){'WARN'}else{'OK'}))
    Res 'EnableSMB2Protocol'      $cfg.EnableSMB2Protocol      ($(if($cfg.EnableSMB2Protocol){'OK'}else{'FAIL'}))
    Res 'RequireSecuritySignature' $cfg.RequireSecuritySignature
    Res 'EnableSecuritySignature'  $cfg.EnableSecuritySignature
    Res 'EnableInsecureGuestLogons' $cfg.EnableInsecureGuestLogons

    if (-not $cfg.EnableSMB2Protocol) {
        Add-Fix "SMB2 client disabled on this PC. Enable: Set-SmbClientConfiguration -EnableSMB2Protocol `$true -Confirm:`$false"
    }
} catch { Res 'Get-SmbClientConfiguration' "Error: $_" 'WARN' }

# Group Policy that blocks guest SMB (this is the #1 cause of QNAP failures)
try {
    $gp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' `
                           -ErrorAction Stop
    $allowInsecure = $gp.AllowInsecureGuestAuth
    Res 'AllowInsecureGuestAuth (registry)' $(if($null -eq $allowInsecure){'<not set>'} else {$allowInsecure})
} catch { }

try {
    $lan = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' `
                            -ErrorAction Stop
    if ($lan.AllowInsecureGuestAuth -eq 0) {
        Res 'Policy: AllowInsecureGuestAuth' 0 'FAIL'
        Add-Fix "Group Policy blocks guest SMB. If your QNAP share allows guest access, Windows 10/11 will refuse with 'You can't access this shared folder because your organization's security policies block unauthenticated guest access.' Two fixes: (A) on QNAP, require a user account on the share; or (B) on Windows, gpedit.msc -> Computer Config -> Admin Templates -> Network -> Lanman Workstation -> 'Enable insecure guest logons' = Enabled. Option A is safer."
    }
} catch { }

# Check NTLM compat
try {
    $lmcl = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction Stop).LmCompatibilityLevel
    Res 'LmCompatibilityLevel' $lmcl
    if ($lmcl -ge 5) {
        Add-Fix "LmCompatibilityLevel=5 (NTLMv2 only, refuse LM/NTLMv1). If QNAP is configured for legacy auth, enable NTLMv2 on QNAP: Control Panel -> Network & File Services -> Microsoft Networking -> Advanced Options -> Authentication = NTLMv2."
    }
} catch { }

# ---------------------------------------------------------------------------
# 5. SMB1 client install state (rare but happens with old QNAPs)
# ---------------------------------------------------------------------------
Sec '5. SMB1 client feature'
try {
    $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Client -ErrorAction Stop
    Res 'SMB1Protocol-Client'  $f.State
    if ($f.State -ne 'Enabled') {
        Add-Fix "SMB1 client is not installed. Only install if the QNAP cannot do SMB2/3 (very old QTS). Prefer upgrading QTS instead. To install temporarily: Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol-Client"
    }
} catch { Res 'Get-WindowsOptionalFeature' "Error: $_" 'WARN' }

# ---------------------------------------------------------------------------
# 6. Stored credentials
# ---------------------------------------------------------------------------
Sec '6. Stored credentials for this server'
try {
    $list = & cmdkey /list 2>$null
    $matchLines = $list | Select-String -Pattern $Server, $ip -SimpleMatch
    if ($matchLines) {
        $matchLines | ForEach-Object { Res '  cmdkey entry' $_.Line.Trim() 'INFO' }
        Add-Fix "Stored credentials exist for this server. If the password was changed on the QNAP, this causes a credential prompt loop or access denied. Clear with: cmdkey /delete:$Server  (and: cmdkey /delete:$ip)"
    } else {
        Res 'cmdkey entries' 'none' 'OK'
    }
} catch { }

# ---------------------------------------------------------------------------
# 7. Live SMB negotiation
# ---------------------------------------------------------------------------
Sec '7. SMB negotiation and share enumeration'
$path = "\\$Server"
try {
    $shares = & net view $path 2>&1
    if ($LASTEXITCODE -eq 0) {
        Res 'net view' 'success' 'OK'
        $shares | Where-Object { $_ -match '\s+Disk\s+' } | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Gray
        }
    } else {
        Res 'net view' 'failed' 'FAIL'
        $shares | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        $err = ($shares -join ' ')
        switch -Regex ($err) {
            'System error 5'    { Add-Fix "Access Denied (error 5). Either credentials are wrong, the QNAP user is disabled/locked, or guest access is blocked - see finding #4 above." }
            'System error 53'   { Add-Fix "Network path not found (error 53). Name doesn't resolve or TCP 445 is blocked - see findings #1 and #2." }
            'System error 67'   { Add-Fix "Network name cannot be found (error 67). Share doesn't exist or SMB service is stopped on the QNAP." }
            'System error 86'   { Add-Fix "Wrong password (error 86)." }
            'System error 1219' { Add-Fix "Multiple connections by same user (error 1219). Run: net use * /delete   then retry." }
            'System error 1326' { Add-Fix "Logon failure - unknown user or bad password (error 1326)." }
            'unauthenticated guest' { Add-Fix "Windows refused unauthenticated guest auth - see policy fix in finding #4." }
        }
    }
} catch { Res 'net view' "Error: $_" 'FAIL' }

if ($Share) {
    $full = "\\$Server\$Share"
    Sec "8. Connect to $full"
    try {
        $c = & net use $full 2>&1
        if ($LASTEXITCODE -eq 0) {
            Res 'net use' 'success' 'OK'
            $listing = Get-ChildItem $full -Filter *.iso -ErrorAction Stop | Select-Object -First 5
            Res 'ISOs found' $listing.Count
            $listing | ForEach-Object { Write-Host ("  {0}  {1:N0} bytes" -f $_.Name, $_.Length) -ForegroundColor Gray }
            & net use $full /delete /y | Out-Null
        } else {
            Res 'net use' 'failed' 'FAIL'
            $c | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }
    } catch { Res 'Get-ChildItem' "Error: $_" 'FAIL' }
}

# ---------------------------------------------------------------------------
# 8. Active SMB connection inventory (what dialect did we actually use?)
# ---------------------------------------------------------------------------
Sec '9. Active SMB connections (post-test)'
try {
    Get-SmbConnection -ErrorAction Stop |
        Where-Object { $_.ServerName -like "*$Server*" -or $_.ServerName -eq $ip } |
        Format-Table ServerName, ShareName, Dialect, Encrypted, Signed, UserName -AutoSize
} catch { Res 'Get-SmbConnection' 'no active connection' 'INFO' }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Sec 'Summary'
if ($findings.Count -eq 0) {
    Write-Host 'No issues detected on the client side.' -ForegroundColor Green
    Write-Host 'If the share still fails, the problem is on the QNAP - see QNAP-CHECKLIST.md.' -ForegroundColor Gray
} else {
    for ($i = 0; $i -lt $findings.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $findings[$i]) -ForegroundColor Yellow
        Write-Host ''
    }
}
