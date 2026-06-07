# QNAP-side checklist when multiple Windows clients can't open the SMB share

If `Diagnose-QnapSmb.ps1` reports the client side is clean and the share
still won't open, the fix is on the QNAP. Work top to bottom — these are
ordered by how often they cause exactly the symptom "share won't open at
all."

## 1. SMB service is actually running

QTS / QuTS hero:

- **Control Panel → Network & File Services → Microsoft Networking**
- "Enable file service for Microsoft networking" must be **checked**.
- If it's already checked, uncheck → Apply → check → Apply (forces Samba
  restart). This single step fixes maybe a quarter of post-firmware-update
  failures.

SSH check (admin SSH must be enabled in Control Panel → Telnet/SSH first):

```bash
ssh admin@servernas
/etc/init.d/smb.sh status
/etc/init.d/smb.sh restart
```

## 2. SMB version range

**Control Panel → Network & File Services → Microsoft Networking → Advanced**

- **Highest SMB version**: SMB 3
- **Lowest SMB version**: SMB 2

Do **not** set the lowest to SMB 1 just because something old needs it —
modern Windows refuses to install the SMB1 client. If you genuinely have a
device stuck on SMB1, give it a dedicated share via a second SMB service
instance.

## 3. Guest access vs. unauthenticated guest auth

This is the **single most common cause** when the symptom is "all Windows
clients fail with access denied" after a Windows update.

- If the share is set to **Allow guest access**, modern Windows 10/11 will
  refuse to connect with the error:
  > You can't access this shared folder because your organization's
  > security policies block unauthenticated guest access.

Two fixes — pick **A**:

  - **A (recommended):** On the QNAP, edit the share → **Shared Folder
    Permissions** → remove "guest", add a real user with Read/Write. Then
    on Windows, connect with that username/password (Windows will remember
    it in Credential Manager).
  - **B:** On each Windows PC, `gpedit.msc` → Computer Config → Admin
    Templates → Network → Lanman Workstation → "Enable insecure guest
    logons" = Enabled. This re-opens a known vector and isn't recommended.

## 4. Authentication mode

**Control Panel → Network & File Services → Microsoft Networking → Advanced**

- **Authentication**: **NTLMv2** (not NTLM, not LM+NTLMv1)

Modern Windows defaults to `LmCompatibilityLevel = 5` (NTLMv2 only). If
QNAP is set to NTLMv1 the negotiation just fails.

## 5. SMB signing

**Control Panel → Network & File Services → Microsoft Networking → Advanced**

- **Enable SMB packet signing**: enabled
- **Require signing**: only if every client supports it (all Windows ≥10 do)

After QNAP security advisories QSA-23-xx, several firmware versions force
signing on by default. If you ever disabled signing on Windows (Group
Policy "Digitally sign communications (always) = Disabled"), the
negotiation fails.

## 6. Account state

**Control Panel → Privilege → Users**

- Confirm the user account isn't **disabled** or **password-expired**.
- Check **Shared Folder Permissions** on the ISO share for that user.
- If the account just had a password change, clear stale Windows creds:
  ```powershell
  cmdkey /list
  cmdkey /delete:servernas
  cmdkey /delete:192.168.x.x
  ```

## 7. Firewall / Security Counselor

QNAP "Security Counselor" and "QuFirewall" can rate-limit or block SMB if a
client retried with a bad password too many times.

- **Control Panel → Security → Allow / Deny List**: confirm your client IP
  isn't in the deny list.
- **QuFirewall**: temporarily set profile to "Basic protection" to test.

## 8. Recycle Bin / @Recycle interference

If the share has Network Recycle Bin enabled and the `@Recycle` folder has
grown huge or has permission damage, share enumeration can hang. Disable
the recycle bin on the share, browse, then re-enable.

## 9. The ISO itself

Once the share opens, large ISOs (>4 GB) need:

- A share on an **ext4/Btrfs/ZFS** volume (FAT32 caps at 4 GB).
- SMB **large MTU / multichannel** for speed — enable in *Advanced
  Options*. Multichannel needs ≥SMB 3.0 on both ends.
- If Windows then can't **mount** the ISO with "Sorry, there was a problem
  mounting the file," that's a Windows-side issue (NTFS Sparse / file is
  on a network drive — Windows 10 can't mount ISOs from network paths
  directly; copy locally or use Windows 11, which can).

## After fixing, verify with the diagnostic

```powershell
.\Diagnose-QnapSmb.ps1 -Server servernas -Share Multimedia
```

You should see `Get-SmbConnection` report `Dialect = 3.1.1` (or at minimum
`3.0`), `Signed = True`, and the test enumerate ISO filenames.
