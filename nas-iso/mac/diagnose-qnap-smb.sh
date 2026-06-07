#!/usr/bin/env bash
# Diagnose macOS -> QNAP SMB share problems.
#
# Walks: name resolution -> reachability -> TCP 445 -> SMB negotiation
# -> Keychain state -> active mounts -> Finder cruft -> Spotlight
# -> nsmb.conf overrides. Prints a numbered fix list at the end.
#
# Usage:
#   ./diagnose-qnap-smb.sh                          # defaults to host 'servernas'
#   ./diagnose-qnap-smb.sh servernas Multimedia     # also test a share
#   ./diagnose-qnap-smb.sh 192.168.1.50 Multimedia user

set -u
SERVER="${1:-servernas}"
SHARE="${2:-}"
USERNAME="${3:-$USER}"

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
c_red=$'\033[31m';  c_gray=$'\033[90m';  c_reset=$'\033[0m'

findings=()

sec() { printf '\n%s\n%s%s%s\n%s\n' \
        "======================================================================" \
        "$c_cyan" "$1" "$c_reset" \
        "======================================================================" ; }

res() {
    # $1=label  $2=value  $3=OK|WARN|FAIL|INFO
    local color
    case "${3:-INFO}" in
        OK)   color=$c_green  ;;
        WARN) color=$c_yellow ;;
        FAIL) color=$c_red    ;;
        *)    color=$c_gray   ;;
    esac
    printf '%s%-34s %s%s\n' "$color" "$1:" "$2" "$c_reset"
}

fix() { findings+=("$1") ; }

if [[ "$(uname)" != "Darwin" ]]; then
    echo "This script is for macOS. For Windows, use Diagnose-QnapSmb.ps1." >&2
    exit 1
fi

echo "macOS version: $(sw_vers -productVersion)  build $(sw_vers -buildVersion)"

# ---------------------------------------------------------------------------
# 1. Name resolution
# ---------------------------------------------------------------------------
sec "1. Name resolution for '$SERVER'"

IP=""
# DNS
if dns_ip=$(dscacheutil -q host -a name "$SERVER" 2>/dev/null | awk '/ip_address/ {print $2; exit}'); then
    if [[ -n "$dns_ip" ]]; then
        IP="$dns_ip"
        res "DNS (dscacheutil)" "$IP" OK
    fi
fi

# mDNS / Bonjour
mdns_ip=$(dns-sd -timeout 3 -G v4 "${SERVER%.local}.local" 2>/dev/null \
          | awk '/Add /{print $6; exit}')
if [[ -n "${mdns_ip:-}" ]]; then
    res "mDNS (.local)" "$mdns_ip" OK
    IP="${IP:-$mdns_ip}"
else
    res "mDNS (.local)" "no response" WARN
    fix "Bonjour did not announce '$SERVER.local'. On the QNAP: Control Panel -> Network & File Services -> Service Discovery -> enable 'Bonjour'. After enabling, reboot the QNAP's network service. Or just use the QNAP's IP address directly."
fi

if [[ -z "$IP" ]]; then
    res "Name resolution" "FAILED" FAIL
    fix "Neither DNS nor mDNS resolved '$SERVER'. Try the QNAP IP directly. To make 'servernas' resolve permanently, either add an A record to your router's DNS or add to /etc/hosts: sudo sh -c \"echo '192.168.x.y servernas' >> /etc/hosts\""
    echo
    echo "Re-run as: ./diagnose-qnap-smb.sh <qnap-ip> [share]"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Reachability
# ---------------------------------------------------------------------------
sec "2. Reachability of $IP"

if ping -c 2 -t 2 "$IP" >/dev/null 2>&1; then
    res "ICMP ping" "OK" OK
else
    res "ICMP ping" "FAIL" WARN
    fix "ICMP is blocked or the QNAP is offline. Some firewalls drop ping but allow SMB - continue."
fi

for port in 445 139 8080 443 5353; do
    label="TCP $port"
    case $port in
        445)  label="TCP 445 (SMB)" ;;
        139)  label="TCP 139 (NetBIOS)" ;;
        8080) label="TCP 8080 (QNAP UI)" ;;
        443)  label="TCP 443 (QNAP HTTPS)" ;;
        5353) label="UDP 5353 (mDNS)"; continue ;;
    esac
    if nc -z -G 2 "$IP" "$port" >/dev/null 2>&1; then
        res "$label" "open" OK
    else
        res "$label" "closed/filtered" FAIL
        if [[ $port == 445 ]]; then
            fix "TCP 445 is unreachable. On the QNAP: Control Panel -> Network & File Services -> Microsoft Networking -> 'Enable file service for Microsoft networking'. Also check QuFirewall / Security Counselor for a deny rule against this Mac's IP."
        fi
    fi
done

# ---------------------------------------------------------------------------
# 3. SMB negotiation - what the QNAP actually offers
# ---------------------------------------------------------------------------
sec "3. SMB dialect negotiation"

# smbutil can list the dialects the server supports without auth
if neg=$(smbutil status "//$IP" 2>&1); then
    echo "$neg" | sed 's/^/  /'
fi

if dialects=$(smbutil view -g "//guest@$IP" 2>&1); then
    echo "$dialects" | sed 's/^/  /'
else
    msg="$dialects"
    echo "$msg" | sed 's/^/  /'
    case "$msg" in
        *"Authentication error"*)
            fix "Guest enumeration is rejected (this is fine if guest is disabled on QNAP). The share itself may still work with a real user. Run: smbutil view //YOURUSER@$IP" ;;
        *"Connection reset"*|*"Connection refused"*)
            fix "QNAP refused the SMB handshake. Almost always: 'Lowest SMB version' on QNAP is set to SMB1 and macOS no longer offers SMB1. Fix on QNAP: Control Panel -> Network & File Services -> Microsoft Networking -> Advanced -> Lowest=SMB2, Highest=SMB3." ;;
        *"server signatures"*|*"signing"*)
            fix "macOS refused the connection because SMB signing was not offered. Sonoma+ requires signing. On QNAP enable: Advanced Options -> 'Enable SMB packet signing'. Do NOT disable signing on the Mac as a workaround unless you also accept the security tradeoff." ;;
    esac
fi

# ---------------------------------------------------------------------------
# 4. macOS SMB client config (~/Library/Preferences/nsmb.conf, /etc/nsmb.conf)
# ---------------------------------------------------------------------------
sec "4. macOS SMB client config (nsmb.conf)"

for f in /etc/nsmb.conf "$HOME/Library/Preferences/nsmb.conf"; do
    if [[ -f "$f" ]]; then
        res "$f" "exists" INFO
        sed 's/^/    /' "$f"
        if grep -qiE 'signing_required\s*=\s*no|protocol_vers_map\s*=\s*[12]\b' "$f"; then
            fix "$f weakens SMB security (disabled signing or capped at SMB1/2). On Sonoma+ this can cause connection refusal. Review and delete if unsure: sudo rm $f (or rm for the user file)."
        fi
    else
        res "$f" "not present (default behavior)" OK
    fi
done

# ---------------------------------------------------------------------------
# 5. Keychain entries for this server
# ---------------------------------------------------------------------------
sec "5. Keychain entries"

found_keychain=0
for who in "$SERVER" "$IP"; do
    if security find-internet-password -s "$who" >/dev/null 2>&1; then
        acct=$(security find-internet-password -s "$who" 2>/dev/null \
                | awk -F'"' '/"acct"<blob>/{print $4}')
        res "Keychain entry for $who" "account=$acct" INFO
        found_keychain=1
    fi
done
if [[ $found_keychain -eq 1 ]]; then
    fix "Keychain has stored credentials for this server. If the QNAP password was changed, this is what causes the infinite 'connecting...' or 'authentication error' loop. Open Keychain Access, search for '$SERVER' AND '$IP', delete BOTH entries, then reconnect (Finder will prompt fresh). Alternatively from CLI: security delete-internet-password -s '$SERVER'  (and the IP form)."
else
    res "Keychain entries" "none" OK
fi

# ---------------------------------------------------------------------------
# 6. Existing mounts & Finder cruft
# ---------------------------------------------------------------------------
sec "6. Current mounts and /Volumes"

mount | grep -i smbfs | sed 's/^/  /' || true

stale=$(ls /Volumes 2>/dev/null | grep -E "^${SERVER}([- ][0-9]+)?$" || true)
if [[ -n "$stale" ]]; then
    res "Stale /Volumes entries" "$(echo "$stale" | wc -l | tr -d ' ')" WARN
    echo "$stale" | sed 's/^/    /'
    fix "Finder left empty mount points in /Volumes (e.g. 'servernas-1', 'servernas-2'). Even one stale entry makes cmd-K reuse a broken cached mount. Fix: for each empty dir, sudo umount /Volumes/<name> 2>/dev/null; sudo rmdir /Volumes/<name>"
fi

# ---------------------------------------------------------------------------
# 7. Spotlight indexing on SMB
# ---------------------------------------------------------------------------
sec "7. Spotlight on SMB shares"

# Apple's preference key that disables Spotlight network indexing
ignore=$(defaults read /Library/Preferences/com.apple.SpotlightServer.plist NetworkServerIndexEnabled 2>/dev/null || echo "<unset>")
res "NetworkServerIndexEnabled" "$ignore"
if [[ "$ignore" != "0" && "$ignore" != "NO" ]]; then
    fix "Spotlight will try to index SMB shares (mds_stores), which hammers the QNAP's CPU and makes the share appear to hang. Disable globally: sudo defaults write /Library/Preferences/com.apple.SpotlightServer.plist NetworkServerIndexEnabled -bool false  (logout/login to apply). Per-mount: mdutil -i off /Volumes/<share>."
fi

# ---------------------------------------------------------------------------
# 8. .DS_Store on network shares
# ---------------------------------------------------------------------------
sec "8. .DS_Store on network shares"

dsstore=$(defaults read com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null || echo "<unset>")
res "DSDontWriteNetworkStores" "$dsstore"
if [[ "$dsstore" != "1" && "$dsstore" != "true" && "$dsstore" != "YES" ]]; then
    fix "macOS writes .DS_Store files onto SMB shares. QNAP's ransomware/snapshot features sometimes treat the constant rewrites as suspicious and read-only-quarantine the share. Disable: defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true  (logout/login). Then on the QNAP, delete existing .DS_Store / ._* files."
fi

# ---------------------------------------------------------------------------
# 9. Live connect test
# ---------------------------------------------------------------------------
if [[ -n "$SHARE" ]]; then
    sec "9. Connect test to //${USERNAME}@${SERVER}/${SHARE}"
    mountpoint="/Volumes/_diag_${SHARE}"
    sudo mkdir -p "$mountpoint" 2>/dev/null || mkdir -p "$mountpoint" 2>/dev/null
    if mount_smbfs "//${USERNAME}@${IP}/${SHARE}" "$mountpoint" 2>&1 | tee /tmp/diag_mount.log; then
        if mount | grep -q "$mountpoint"; then
            res "mount_smbfs" "success" OK
            echo "  First 5 ISOs:"
            find "$mountpoint" -maxdepth 2 -iname '*.iso' 2>/dev/null | head -5 | sed 's/^/    /'
            sudo umount "$mountpoint" 2>/dev/null || true
            sudo rmdir "$mountpoint" 2>/dev/null || true
        fi
    else
        res "mount_smbfs" "FAILED" FAIL
        case "$(cat /tmp/diag_mount.log)" in
            *"Authentication error"*)
                fix "Authentication rejected. Wrong password, or the user has no permission on share '$SHARE'. On QNAP: edit shared folder permissions for '$SHARE' and confirm the user has at least read access." ;;
            *"No route to host"*|*"Operation timed out"*)
                fix "Network unreachable at mount time despite TCP 445 succeeding earlier - intermittent. Could be QuFirewall rate-limiting due to earlier failed attempts." ;;
            *"Permission denied"*)
                fix "Local /Volumes permission issue. Run: sudo chown root:wheel /Volumes && sudo chmod 755 /Volumes" ;;
            *"server rejected"*|*"connection reset"*)
                fix "QNAP closed the SMB session after handshake - usually 'signing required' mismatch or SMB1-only QNAP setting. See finding from section 3." ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
sec "Summary"
if [[ ${#findings[@]} -eq 0 ]]; then
    echo "${c_green}No client-side issues detected.${c_reset}"
    echo "If the share still fails, the problem is on the QNAP - see MACOS-QNAP-NOTES.md."
else
    for i in "${!findings[@]}"; do
        printf "%s%d. %s%s\n\n" "$c_yellow" "$((i+1))" "${findings[$i]}" "$c_reset"
    done
fi
