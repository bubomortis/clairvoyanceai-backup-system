# Clairvoyance Versioning Backup System

A daily, versioned, GFS-tiered backup system for [Clairvoyance](https://clairvoyance.ai) workspaces on Windows. It mirrors app data + workspaces to a network share, produces SHA-256 manifests, splits secrets into a separate AES-256 encrypted archive, applies Grandfather-Father-Son retention (Daily/Weekly/Monthly/Annual + a weekly Artifacts tier), deep-verifies archives from the share, and runs unattended as a SYSTEM scheduled task.

This repository contains the **scrubbed, shareable** build materials — no instance identifiers, hostnames, paths, or secrets. It is provided **as-is**; read [**Risks & limitations**](#risks--limitations) below before adopting.

## What's here

| Document | Purpose |
| -------- | ------- |
| [docs/Build-Runbook.md](docs/Build-Runbook.md) | Step-by-step, interview-driven build guide. Your own AI (or you) authors the scripts locally from the Companion Scripts — nothing is downloaded and run blind. |
| [docs/Companion-Scripts.md](docs/Companion-Scripts.md) | Annotated, byte-accurate source of `backup.ps1`, `restore.ps1`, and `evaluate-workspaces.ps1`, using `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders. **Canonical source of truth** for the scripts. |
| [scripts/](scripts/) | The same four scripts extracted verbatim as standalone `.ps1` files (`backup.ps1`, `restore.ps1`, `evaluate-workspaces.ps1`, `backup-preflight.ps1`), for syntax highlighting and diffs. Convenience/audit copies — kept in sync with the Companion Scripts note. |
| [config.example.json](config.example.json) | Annotated example `config.json` showing the exact structure, nesting, and types, with placeholder paths. Copy, substitute, and drop the `_comment*` keys. |

> **Note on `scripts/`:** these files still carry the `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders as parameter defaults. Substitute them for your own paths (or always invoke with an explicit `-ConfigPath`) before running. The runbook's trustless flow — where your own AI authors the scripts locally — remains the recommended install path; `scripts/` is provided for convenience and auditing, not blind download-and-run.

## Installation

> [!WARNING]
> This is an **attended, interview-driven build**, not a one-click installer. You must be present at the keyboard to answer the setup interview and to approve the machine-level steps (sealing an encryption passphrase, creating a SYSTEM scheduled task, optional folder lockdown). It **cannot** run unattended. A copy-paste prompt is a convenience, **not consent** — your agent must still stop and ask you to approve each risky step.

Requirements: Windows 10/11 · PowerShell 5.1+ · 7-Zip · robocopy (built in) · a reachable backup destination (a network share or a second fixed disk). Read [**Risks & limitations**](#risks--limitations) below before you start.

Choose **one** method.

### Option A: Ask Clairvoyance to install it

Use this if you have a trusted Clairvoyance coding agent (Staff) that can run commands on your Windows machine. Paste the following prompt to that agent verbatim:

```text
Install and configure the Clairvoyance Versioning Backup System from
https://github.com/bubomortis/clairvoyanceai-backup-system

Treat docs/Build-Runbook.md in that repository as the AUTHORITATIVE, step-by-step
procedure. Read it in full and follow it exactly. Also read AGENTS.md at the repo
root before doing anything. Observe these rules:

1. IDEMPOTENCY FIRST. Before changing anything, run the read-only probe
   backup-preflight.ps1 (author it first, the same trustless way as the other
   scripts) and branch on its VERDICT. It checks LIVE state — the scripts parse,
   config.json is valid, the sealed passphrase file actually DPAPI-unseals on this
   machine, and the "Clairvoyance Nightly Backup" SYSTEM task exists. COMPLETE ->
   report the existing install and STOP (do NOT reinstall, re-seal, or re-register);
   PARTIAL -> resume only at the first unmet invariant; DUPLICATE -> stop and ask me;
   NOT_INSTALLED -> proceed.
2. Confirm this is Windows, PowerShell is 5.1 or later, 7-Zip and robocopy are
   present, and I have a reachable backup destination (network share or fixed disk).
   Report any missing prerequisite and stop.
3. Tell me up front that this is an ATTENDED build: I must stay present to approve
   "Allow Once" permission prompts, so it cannot be run unattended.
4. Ask me to choose a permanent LOCAL tool directory on a fixed disk that both
   Clairvoyance and a SYSTEM scheduled task can reach and execute (no UNC path, no
   OneDrive-synced folder, no temp directory).
5. AUTHOR THE SCRIPTS LOCALLY (trustless): write backup.ps1, restore.ps1,
   evaluate-workspaces.ps1, and backup-preflight.ps1 into the tool directory from this repo's scripts/ (or the
   fenced source in docs/Companion-Scripts.md), substitute the <TOOL_DIR> and
   <WORKSPACES_ROOT> placeholders with my real paths, and verify each file parses
   ([Parser]::ParseFile, zero errors) before running anything.
6. Run the Build Runbook interview and confirm my answers: destination, schedule +
   time zone, instance name, staging directory, temp directory, copy method, GFS
   retention day, sources, per-workspace excludes/artifact dirs, per-workspace
   encryption (explain the LOST-PASSPHRASE risk), and orchestrator pause onboarding.
7. STOP AND GET MY EXPLICIT APPROVAL before each of these, one at a time — a prompt
   is not consent:
     (a) sealing the AES-256 secrets passphrase via DPAPI,
     (b) creating the SYSTEM scheduled task (runs as SYSTEM, highest privileges),
     (c) any folder ACL lockdown — and do the lockdown LAST, as the final go-live
         step, never mid-build.
   Leave the optional SMB signing hardening OFF by default; it can break guest-login
   network shares.
8. Do a supervised validation run and show me last-run.json before enabling any
   scheduled task for real. Do not arm go-live without my explicit approval.
9. Report every command you run and its result. Do not modify, commit to, or push to
   the source repository.
```

### Option B: Install it yourself

Open [docs/Build-Runbook.md](docs/Build-Runbook.md) and follow it top to bottom. It is written to be executed either by an agent or by a person; the same interview questions, script-authoring steps, and approval gates apply.

## Design notes

- **Trustless authoring:** you never copy-paste opaque binaries. The runbook has your AI write each script to disk from the auditable fenced source, substitute placeholders, and verify it parses before anything runs.
- **Secrets stay local:** the main archive is unencrypted for easy recovery; anything sensitive is routed to a separate AES-256 (`-mhe=on`) archive whose passphrase never leaves the machine (sealed via DPAPI).
- **Windows-specific:** requires 7-Zip, robocopy, PowerShell 5.1+, and a reachable destination (network share or fixed disk).
- **Staff-continuity check:** a Staff member isn't one file — their definition (`profiles/staff.json`), custom persona, and `.Clairvoyance/staff/` memory live in several places. The engine asserts (via `protectedPaths` in `config.example.json`) that those are actually in each archive and fails loudly if a future exclude ever silently drops them.

## Risks & limitations

No backup is risk-free. **Provided as-is, without warranty.** Adopt this only if you accept the following. If your data is critical, pair it with an offsite/immutable copy.

1. **Lose the passphrase → permanent loss** of the encrypted secrets archive (and any workspaces you elect to encrypt). There is **no key escrow / no recovery** by design. Store the passphrase in multiple safe places.
2. **The main archive is UNENCRYPTED by default.** Your notes and workspace content sit on the destination protected **only by access control**, not cryptography — and may be readable in transit if your share isn't encrypted. Mitigate with tight destination ACLs, SMB encryption, encrypted-at-rest disk, and/or electing sensitive workspaces into the encrypted archive.
3. **The passphrase is machine-bound** (LocalMachine DPAPI). The sealed key file only decrypts on that same PC. A bare-metal rebuild requires re-sealing from your password manager — lose *both* the machine and that copy and the secrets are gone.
4. **It runs elevated.** The nightly job executes as SYSTEM with backup privilege. The design minimizes this (one audited script, locked-down folder), but you are running privileged automation nightly — keep the tool folder admin-only (the runbook does this).
5. **Brief residual passphrase exposure:** 7-Zip can't take the password via stdin for *test/extract* (only for compression), so those steps pass it inline for ~1 second — visible to local process enumeration during that window. Local-only, minor, but not zero.
6. **Single destination = no offsite/immutability by itself.** It backs up to the ONE place you point it. A ransomware event could hit your live data *and* a local/LAN backup. Add offsite replication and/or immutable/versioned storage separately if you need it.
7. **Silent-corruption window:** the hash cache trusts file modified-times between the monthly full re-hash passes, so a corruption that preserves mtime could go undetected for up to ~a month.
8. **Missed/powered-off nights:** it's a scheduled daily point-in-time backup. If the PC is off at the scheduled time, that day is missed (tier slots self-heal on the next run, but that specific day's snapshot is lost).
9. **Large/media-heavy workspaces need tuning.** Setup scans your workspaces and asks how to handle big folders; skip that and huge regenerable directories can blow the time window and storage. Review the scan.
10. **AI-in-the-loop monitoring is optional.** An in-app "Archivist" Staff member can report success/failure and raise alarms, but the backup itself does not depend on it — the SYSTEM task runs and writes `last-run.json` regardless. If you use the monitor, confirm its alarm channel actually reaches you and don't treat "no alarm" as proof of success; either way, check the log periodically.
11. **Untested restores aren't backups.** Periodically run the restore *verify* and a test *in-place* recovery. This system makes that easy, but you have to actually do it.
12. **Optional SMB-signing hardening can break guest network shares.** Setup offers an *optional* step to require SMB signing (`RequireSecuritySignature`, default **off**). Enabling it breaks any SMB share using **guest/anonymous logins** (common on NAS boxes — Unraid, public/guest shares) after the next reboot, failing with a **misleading "error 67 / network name cannot be found."** Only enable it if every SMB share you use is authenticated. Recovery is one command: `Set-SmbClientConfiguration -RequireSecuritySignature $false -Force`.

## What it does not do

Not a cloud/offsite service on its own · not continuous/real-time (daily point-in-time) · not ransomware-immutable by itself · not cross-platform · doesn't image the OS or reinstall apps (it backs up Clairvoyance data + your chosen dependencies; the app is reinstalled per the recovery plan).
