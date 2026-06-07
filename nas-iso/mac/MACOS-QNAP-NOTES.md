# Why macOS + QNAP SMB shares break

Research notes on the known failure modes when a Mac can't open a QNAP
SMB share. Ordered roughly by how often each one is the actual cause for
"share won't open at all."

## 1. AFP is gone and SMB is the only path

QNAP removed AFP in QTS 5.0 (release notes, 2021). Macs that previously
mounted `afp://servernas/...` now silently fall back to `smb://...` and
hit problems they never had before. The Mac still remembers the old
`afp://` URL in **Finder > Go > Recent Servers** and reconnect attempts
fail with no useful error.

**Check:** `Finder > Go > Connect to Server` and confirm the URL starts
with `smb://`, not `afp://`. Delete old AFP entries from "Recent
Servers".

## 2. macOS SMB signing tightening (Sonoma 14 / Sequoia 15)

Sonoma made SMB **signing required by default** on the client. If the
QNAP doesn't advertise signing capability in the SMB2 NEGOTIATE
response, Sonoma refuses the session with an error that surfaces in
Finder as a generic "There was a problem connecting to the server."

Server-side fix on QNAP (Control Panel → Network & File Services →
Microsoft Networking → Advanced Options):
- "Enable SMB packet signing" = **on**
- Don't tick "Require signing" unless every client supports it.

Client-side workaround (**not recommended** — turns off integrity
protection): create `/etc/nsmb.conf` with:

```ini
[default]
signing_required=no
```

Use this only as a temporary unblock while you fix the QNAP.

## 3. Lowest SMB version stuck at SMB1 on the QNAP

QNAPs that were configured years ago still have **Lowest SMB version =
SMB 1**. macOS High Sierra (10.13) deprecated SMB1 on the client side
and recent macOS won't speak it at all. The handshake fails before auth.

QNAP fix: Advanced Options → Lowest SMB version = **SMB 2** (or 3),
Highest = **SMB 3**.

## 4. Bonjour / mDNS announcement broken after QTS update

Symptom: `ping servernas.local` fails, `ping servernas` works (via DNS
only), Finder sidebar doesn't show the NAS at all.

Cause: QNAP's `avahi-daemon` is wedged. QTS 5.x firmware updates have
shipped with bugs that crash it after upgrade.

Fix on QNAP: Control Panel → Network & File Services → Service
Discovery → uncheck Bonjour → Apply → recheck → Apply. Or SSH and
`/etc/init.d/avahi.sh restart`.

## 5. Stuck mount points in /Volumes

When a Finder SMB mount disconnects ungracefully (sleep, Wi-Fi drop,
NAS reboot), macOS sometimes leaves an empty directory in `/Volumes`:

```
/Volumes/servernas
/Volumes/servernas-1
/Volumes/servernas-2
```

The next `cmd-K` mount creates `servernas-3`, and Spotlight / aliases
that point to `/Volumes/servernas` open the empty dir, not the share.

Fix:

```bash
mount | grep smbfs                # what's actually mounted
ls /Volumes                       # what placeholders remain
sudo umount /Volumes/servernas-1 2>/dev/null
sudo rmdir  /Volumes/servernas-1
# repeat per stale entry
```

## 6. Keychain has two stale entries (hostname AND IP)

When you connect to `smb://servernas` and `smb://192.168.1.50` at
different times, Keychain stores two separate "Internet Password"
entries. A password change leaves one stale. Finder picks whichever it
finds first → bad credentials → endless prompt loop with no error.

Fix in **Keychain Access**:
1. Search "servernas" → delete all Network Password entries.
2. Search the QNAP's IP → delete all Network Password entries.
3. Reconnect; Finder will prompt fresh.

CLI form:

```bash
security delete-internet-password -s servernas
security delete-internet-password -s 192.168.1.50
```

## 7. Spotlight indexing destroys QNAP performance

When `mds` decides to index a newly mounted SMB share, it walks every
file. On an ISO library with thousands of files, this pegs the QNAP's
CPU and the share appears to hang for everyone, not just the indexing
Mac.

Permanent fix (per Mac):

```bash
sudo defaults write /Library/Preferences/com.apple.SpotlightServer.plist \
    NetworkServerIndexEnabled -bool false
# logout and log back in
```

Per-mount, ad-hoc:

```bash
mdutil -i off /Volumes/Multimedia
sudo mdutil -E /Volumes/Multimedia    # erase the index that already started
```

## 8. .DS_Store and ._AppleDouble trigger QNAP ransomware protection

QNAP "QuFirewall" / "Snapshot ransomware protection" detects "mass
file modification" on the share. Finder writes `.DS_Store` on every
folder navigation, and the resource-fork sidecars (`._Filename`) double
every file. On strict ransomware settings, the QNAP read-only-locks the
share and you get permission errors for hours.

Fix:

```bash
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
# logout/login
```

Then on the QNAP, either lower the ransomware sensitivity, or whitelist
the Mac, or just delete the existing `.DS_Store` / `._*` files:

```bash
ssh admin@servernas
find /share/Multimedia -name '.DS_Store' -delete
find /share/Multimedia -name '._*' -delete
```

## 9. Large ISO reads are slow specifically because of SMB signing

This is the #1 macOS-SMB performance complaint. Even when the share
mounts fine, reading a 6 GB ISO is 10 MB/s instead of 100 MB/s.
Apple's SMB client does signing in software per packet.

If the share is fine functionally but slow:

```ini
# /etc/nsmb.conf
[default]
signing_required=no
notify_off=yes
```

You're trading SMB3 integrity protection for speed. Acceptable on a
trusted home LAN; not acceptable on a shared network.

## 10. mount_smbfs from CLI to bypass Finder entirely

When Finder fails with no useful error, go around it:

```bash
mkdir -p ~/qnap-multimedia
mount_smbfs //user@servernas/Multimedia ~/qnap-multimedia
ls ~/qnap-multimedia/*.iso
```

The error from `mount_smbfs` is far more specific than Finder's "There
was a problem connecting to the server."

| `mount_smbfs` error             | Real cause                                        |
| ------------------------------- | ------------------------------------------------- |
| `Authentication error`          | Wrong password, or user has no rights on share    |
| `No route to host`              | Routing / firewall / QNAP down                    |
| `Connection refused`            | SMB service not running on QNAP                   |
| `Connection reset by peer`      | SMB1-only QNAP and macOS won't speak it           |
| `Server rejected the connection`| Signing or dialect mismatch                       |
| `Operation not permitted`       | macOS Privacy & Security → "Files and Folders" block |
| `File exists` (mount point)     | Stale `/Volumes` entry — see section 5            |

## Order of operations for your situation

For "share won't open at all, multi-client (well, multi-Mac), QNAP still
on the network":

1. Run `diagnose-qnap-smb.sh` from one of the failing Macs.
2. Look at section 3 output (SMB negotiation) — if QNAP refuses the
   handshake, jump to issue #3 (SMB1) or #2 (signing).
3. If section 5 found Keychain entries, delete them and retry — that
   alone fixes ~30% of "share won't open" cases after password changes.
4. If section 6 shows stale `/Volumes` entries, clean them out.
5. If everything client-side is clean, restart the QNAP SMB service
   (Control Panel → Network & File Services → Microsoft Networking →
   uncheck → Apply → recheck → Apply, or SSH and
   `/etc/init.d/smb.sh restart`).

Run the diagnostic, paste the Summary block back, and I can pinpoint
which of these is yours.
