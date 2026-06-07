# macOS -> QNAP SMB diagnostic

For when Finder says "There was a problem connecting to the server" or
just spins forever, and the QNAP is still on the network.

## Files

- `diagnose-qnap-smb.sh` - bash diagnostic. Tests name resolution, TCP
  445/139, SMB dialect negotiation, nsmb.conf, Keychain entries, stale
  /Volumes mounts, Spotlight settings, and (optionally) a live mount.
- `MACOS-QNAP-NOTES.md` - the underlying research: ten known failure
  modes for macOS + QNAP SMB, what triggers each, and the exact fix.

## Run it

From a failing Mac:

```bash
chmod +x diagnose-qnap-smb.sh
./diagnose-qnap-smb.sh                          # default host: 'servernas'
./diagnose-qnap-smb.sh servernas Multimedia     # also test mounting share 'Multimedia'
./diagnose-qnap-smb.sh 192.168.1.50 Multimedia myuser
```

It'll prompt for `sudo` once if it needs to create a temporary mount
point under `/Volumes` to test the connection.

## What it actually checks

| Section | What | Why it can break the share |
| ------- | ---- | -------------------------- |
| 1 | DNS + mDNS resolution of `servernas` | QNAP Bonjour dies after firmware updates |
| 2 | ICMP, TCP 445/139/443/8080 | Confirms it's not a network/firewall issue |
| 3 | SMB dialect from `smbutil view` | Catches SMB1-only QNAPs and signing mismatches |
| 4 | `/etc/nsmb.conf` overrides | Earlier "performance fix" may now block Sonoma+ |
| 5 | Keychain entries (hostname AND IP) | Stale creds after password change = prompt loop |
| 6 | `mount` output and stale `/Volumes/*` dirs | Finder caches dead mounts |
| 7 | `NetworkServerIndexEnabled` for Spotlight | Spotlight indexing hangs the share |
| 8 | `DSDontWriteNetworkStores` | `.DS_Store` writes trip QNAP ransomware protection |
| 9 | Live `mount_smbfs` test (if share specified) | Gets a real error code from the kernel, not Finder |

## Most likely fix for "macOS + QNAP + share won't open"

In order of probability:

1. **Delete stale Keychain entries** for both `servernas` and its IP,
   then reconnect.
2. **Lowest SMB version on QNAP** is still SMB1 - change to SMB2.
3. **Stale `/Volumes` entries** - `sudo rmdir` them.
4. **QNAP Bonjour wedged** - toggle it off/on in QNAP Control Panel.
5. **Sonoma signing tightening** - enable SMB packet signing on the QNAP.

Run the script, paste the Summary block back, and I'll point at the
exact knob.
