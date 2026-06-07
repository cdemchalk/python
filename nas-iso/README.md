# Diagnosing ISO reads from a QNAP NAS over SMB

The symptom is "share won't open at all" from multiple Windows clients.
Multi-client failure means the problem is almost certainly on the QNAP or
the SMB protocol negotiation, not any one PC.

## What's in here

- `Diagnose-QnapSmb.ps1` - run this from any failing Windows client.
  Walks DNS -> ICMP -> TCP 445/139 -> SMB client config -> guest-auth
  policy -> NTLM level -> stored credentials -> live `net view` and
  prints a numbered list of fixes for each layer that failed.

- `QNAP-CHECKLIST.md` - the server-side counterpart. Walk this on the
  QNAP if the client-side diagnostic comes back clean.

## Run it

On a Windows client (PowerShell as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-QnapSmb.ps1 -Server servernas
```

Add `-Share <name>` to test enumeration of a specific share:

```powershell
.\Diagnose-QnapSmb.ps1 -Server servernas -Share Multimedia
```

## What to expect

A healthy result for a QNAP serving ISOs over SMB should show:

```
Resolve-DnsName               : 192.168.x.y         OK
TCP 445 (SMB direct)          : True                OK
Network profile               : Private             OK
EnableSMB2Protocol            : True                OK
AllowInsecureGuestAuth policy : <not set or 1>      OK
net view                      : success             OK
Get-SmbConnection dialect     : 3.1.1
```

If any line is red, the script prints the exact PowerShell or QNAP UI fix
in the Summary section at the bottom.

## Most likely fix for your situation

Given "share won't open at all, multiple clients, QNAP, SMB," the top
three causes are:

1. **Windows blocking unauthenticated guest** -> put a real user on the
   share (see `QNAP-CHECKLIST.md` section 3, fix A).
2. **QNAP Samba in a bad state after firmware update** -> uncheck/recheck
   "Enable file service for Microsoft networking" or SSH and
   `/etc/init.d/smb.sh restart`.
3. **SMB version range** set wrong -> Lowest SMB = 2, Highest = 3
   (`QNAP-CHECKLIST.md` section 2).

Run the diagnostic, paste the Summary block back, and I can point at the
exact fix.
