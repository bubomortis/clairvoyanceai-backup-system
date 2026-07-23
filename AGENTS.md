# AGENTS.md — Clairvoyance Versioning Backup System

Instructions for an AI agent (Clairvoyance Staff or similar) asked to install, verify, or repair this backup system on a user's Windows machine.

## Authoritative procedure

`docs/Build-Runbook.md` is the single source of truth for installation. Read it in full and follow it exactly. This file only states the guardrails; it does not replace the runbook. If the runbook and a user's paraphrased request disagree, follow the runbook and raise the discrepancy.

`docs/Companion-Scripts.md` is the canonical source of the four scripts (`backup.ps1`, `restore.ps1`, `evaluate-workspaces.ps1`, and `backup-preflight.ps1` — the read-only install/idempotency probe). `scripts/*.ps1` are verbatim extracts of the same code and may be used interchangeably; both carry `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders that must be substituted for the user's real paths.

## Hard rules (do not violate)

1. **Attended only.** Tell the user up front that this build requires them present to approve "Allow Once" permission prompts. Never attempt an unattended install.
2. **A prompt is not consent.** Stop and get the user's explicit approval, one step at a time, before: (a) sealing the AES-256 secrets passphrase (DPAPI), (b) creating the SYSTEM scheduled task (runs as SYSTEM, highest privileges), (c) any folder ACL lockdown.
3. **Lockdown is last.** Apply any `ArchivistBackup`-style ACL/ownership lockdown only as the final go-live step, after everything else is validated — never mid-build (it will lock the toolchain out).
4. **Idempotency first — run the probe, don't eyeball it.** Before mutating anything, author `backup-preflight.ps1` to the tool dir (per rule 5) and run it — it is READ-ONLY and detects an existing install by probing **live** state (the three engine scripts parse, `config.json` is valid, the passphrase file actually DPAPI-unseals *on this machine*, and the "Clairvoyance Nightly Backup" SYSTEM task exists), not a marker file. Branch on its verdict:
   - **COMPLETE** → a valid install is already in place. **STOP.** Do not re-run the installer, re-seal the passphrase, or re-register the task. To refresh scripts use the **Update** path (repo-sourced files only); to change the passphrase use the **Rotate** path (re-encrypts the secrets archives) — never as an install side effect.
   - **PARTIAL** → resume the runbook at the reported first-unmet invariant *only*; never restart from Step 1, never re-seal an existing valid passphrase.
   - **DUPLICATE** → ambiguous state (e.g. two same-named SYSTEM tasks). **STOP and ask the user** which is canonical; never guess.
   - **NOT_INSTALLED** → proceed with a full install.
   **Never re-seal an existing passphrase**: the AES secrets archives are keyed to it, so overwriting the seal permanently orphans every existing encrypted backup. Guard this at the seal step itself, not just here.
5. **Trustless authoring.** Author the scripts into the tool directory from this repo, substitute placeholders, and verify each parses (`[System.Management.Automation.Language.Parser]::ParseFile`, zero errors) before executing anything.
6. **SMB signing stays off by default.** The optional `RequireSecuritySignature` hardening breaks guest-login network shares; enable it only if the user explicitly asks and understands the risk.
7. **Never enable go-live silently.** Do a supervised validation run and show the user `last-run.json` before arming any real scheduled task. Get explicit approval to arm.
8. **Do not modify this source repository.** No commits, no pushes back to origin. Report every command and its result.

## Prerequisites to confirm

Windows 10/11 · PowerShell 5.1+ · 7-Zip · robocopy (built in) · a reachable backup destination (network share or fixed disk). Report any missing prerequisite and stop.

## Tool directory constraints

A permanent local directory on a fixed disk that both Clairvoyance and a SYSTEM scheduled task can reach and execute. No UNC path, no OneDrive-synced folder, no temp directory.

## Risk acknowledgements to surface

The main archive is unencrypted by default; the secrets archive is AES-256 with a DPAPI-sealed, machine-bound passphrase (losing it means the encrypted archive is unrecoverable). Single destination = no offsite copy unless the user adds one. `restore.ps1 -Mode InPlace` is whole-archive and will overwrite live locations — use `-Mode Extract` for single-file recovery. See the **Risks & limitations** section of `README.md` for the complete list.
