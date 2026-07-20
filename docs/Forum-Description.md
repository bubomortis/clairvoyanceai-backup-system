# Clairvoyance Backup Automation — Forum Description (for adopters)

# A daily, versioned, verified backup system for Clairvoyance (Windows) — read before adopting

This is a self-hosted backup automation for a Clairvoyance install: it backs up your Clairvoyance app data, all your workspaces, and chosen dependency folders to a destination you control, every day, with versioned history and integrity verification. It's driven by a build **runbook** an in-app Staff member executes — it interviews you and generates the whole thing for your environment. Posting this so anyone considering it understands exactly what they're getting, what it needs, and — importantly — the **risks that remain**.

## What it does
- **Daily** backup of app-data + workspaces + dependencies to your destination (local disk or SMB/NAS share).
- **Grandfather-Father-Son versioning:** ~7 daily, 12 weekly, 12 monthly, and keep-forever annual snapshots (all configurable), with **self-healing** — a missed day's weekly/monthly/annual slot is back-filled by the next successful run.
- **Two archives per run:** a `_main.7z` (your data) and an **AES-256-encrypted `_secrets.7z`** (credentials/tokens, plus any workspaces you *choose* to encrypt).
- **Efficient:** incremental delta copy + a hash cache (only changed files re-hash), a separate low-frequency archive for large/regenerable folders, and hash-verified uploads. Typical nightly runs are small and fast once tuned.
- **Verified:** every archive is integrity-tested, a random sample is extracted from the *destination* copy and hash-checked, and a full monthly re-hash catches silent corruption.
- **Recoverable:** each archive embeds a file manifest + a bare-metal `RECOVERY.md`; a restore script does verify / in-place / clean-install recovery.
- **Least-privilege execution:** the nightly job runs as a Windows **SYSTEM scheduled task** calling one audited script; an in-app "Archivist" only monitors, logs, and alarms.

## Platform — this is Windows-specific
Built and tested on **Windows 11** (should work on Windows 10). It relies on Windows-only pieces: **robocopy** (delta mirror + open-file `/B` mode), **DPAPI** (machine-bound passphrase sealing), **Task Scheduler** (the SYSTEM job), **PowerShell 5.1**, and **7-Zip**. It is **not** portable to macOS/Linux without a rewrite.

## Dependencies / requirements
- Windows 10/11, PowerShell 5.1+.
- **7-Zip** installed.
- `robocopy` (ships with Windows).
- **Local administrator** rights (for the SYSTEM task, elevated open-file copy, and the folder lockdown).
- A backup **destination** reachable as a path (a second local drive, or a NAS/SMB share).
- The **Clairvoyance app** running (to create the Archivist Staff member that monitors runs).
- A **password manager** to hold the encryption passphrase.

## Risks that remain (read this part)
No backup is risk-free. Adopt this only if you accept these:

1. **Lose the passphrase → permanent loss** of the encrypted secrets archive (and any workspaces you elected to encrypt). There is **no key escrow / no recovery** by design. Store the passphrase in multiple safe places.
2. **The main archive is UNENCRYPTED by default.** Your notes and workspace content sit on the destination protected **only by access control**, not cryptography. Anyone who can read that file reads your data, and it may be readable in transit if your share isn't encrypted. Mitigate by hardening the destination (tight ACLs, SMB encryption, encrypted-at-rest disk) and/or electing sensitive workspaces into the encrypted archive.
3. **The passphrase is machine-bound** (LocalMachine DPAPI). The sealed key file only decrypts on that same PC. A bare-metal rebuild requires re-sealing from your password manager — and if you lose *both* the machine and the password-manager copy, the secrets are gone.
4. **It runs elevated.** The nightly job executes as SYSTEM with backup privilege. The design minimizes this (one audited script, locked-down folder), but you are running privileged automation nightly — keep the tool folder and scripts admin-only (the runbook does this).
5. **Brief residual passphrase exposure:** 7-Zip can't take the password via stdin for *test/extract* (only for compression), so those steps pass it inline for ~1 second — visible to local process enumeration during that window. Local-only, minor, but not zero.
6. **Single destination = no offsite/immutability by itself.** It backs up to the ONE place you point it. If that's a local disk or LAN NAS, you have no geographic redundancy and no ransomware immutability — a ransomware event could hit your live data *and* the backup. Add offsite replication and/or immutable/versioned storage separately if you need it.
7. **Silent-corruption window:** the hash cache trusts file modified-times between the monthly full re-hash passes, so a corruption that preserves mtime could go undetected for up to ~a month.
8. **Missed-window / powered-off nights:** it's a scheduled daily point-in-time backup. If the PC is off at the scheduled time, that day is missed (the tier slots self-heal on the next run, but that specific day's snapshot is lost).
9. **Large/media-heavy workspaces need tuning.** The setup scans your workspaces and asks how to handle big folders; if you skip that, huge regenerable directories can blow the time window and storage. Review the scan.
10. **AI-in-the-loop monitoring:** an in-app Staff member reports success/failure and raises alarms. If you depend on those alarms, confirm the alarm channel actually reaches you, and don't treat "no alarm" as proof of success without occasionally checking the log.
11. **Untested restores aren't backups.** Periodically run the restore *verify* and a test *in-place* recovery. This system makes that easy, but you have to actually do it.
12. **Optional SMB-signing hardening can break guest network shares.** Setup offers an *optional* step to require SMB signing on the client (`RequireSecuritySignature`). It defaults to **off**. If you enable it and any of your SMB shares use **guest/anonymous logins** (common on NAS boxes — Unraid, public/guest shares), those shares will stop working after the next reboot, failing with a **misleading "error 67 / network name cannot be found"** (guest sessions can't be signed). It can also break the backup destination if you reach it as a guest share. Only enable it if every SMB share you use is authenticated. Recovery is one command: `Set-SmbClientConfiguration -RequireSecuritySignature $false -Force`.

## What it does NOT do
- Not a cloud/offsite service on its own · not continuous/real-time (daily point-in-time) · not ransomware-immutable by itself · not cross-platform · doesn't image the OS or reinstall apps (it backs up Clairvoyance data + your chosen dependencies; the app is reinstalled per the recovery plan).

## Adopting it
The build **runbook** does the setup: an in-app Staff member interviews you (destination, schedule, versioning, which folders/workspaces to include or encrypt, etc.), scans your workspaces to right-size the backup, generates the config + scripts + scheduled task + monitoring, and walks you through sealing the passphrase and locking things down. Budget ~30–60 minutes and have admin rights, 7-Zip, and your destination ready.

**Expect a hands-on, attended build — not a one-click install.** This is heavily interactive from start to finish:
- **An upfront interview** you have to answer (destination, schedule, timezone, versioning, per-workspace include/exclude/encrypt choices, staging/temp dirs, etc.) — the system is generated from *your* answers, so it can't proceed without them.
- **Then you must stay at the machine for the whole build and approve permissions as they come up.** The Staff member runs many discrete actions (create files, run PowerShell, robocopy, 7-Zip, schtasks, ACL changes, UAC-elevated steps), and each can prompt for approval. **Some prompts only offer "Allow Once"** (no "always allow"/remember option), so you'll be clicking approvals repeatedly and can't walk away — an unapproved prompt stalls the build until you return. Plan to sit with it for the full ~30–60 minutes.
- **Elevation prompts:** several steps trigger Windows UAC; you approve those too.

Pre-granting broader permissions in your harness settings before starting will **reduce** the number of clicks, but it does **not** make the build unattended: the **"Allow Once"-only prompts are not covered by pre-granted/broad permissions**, so some approval dialogs will still appear no matter what you pre-authorize. Plan to be present and clicking for the whole build regardless.

**Provided as-is, no warranty.** Test it in your environment, verify you can restore, and make sure you understand the passphrase and encryption trade-offs before relying on it. If your data is critical, pair this with an offsite/immutable copy.
