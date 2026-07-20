# Clairvoyance Versioning Backup System

A daily, versioned, GFS-tiered backup system for [Clairvoyance](https://clairvoyance.ai) workspaces on Windows. It mirrors app data + workspaces to a network share, produces SHA-256 manifests, splits secrets into a separate AES-256 encrypted archive, applies Grandfather-Father-Son retention (Daily/Weekly/Monthly/Annual + a weekly Artifacts tier), deep-verifies archives from the share, and runs unattended as a SYSTEM scheduled task.

This repository contains the **scrubbed, shareable** build materials — no instance identifiers, hostnames, paths, or secrets. It is provided **as-is**; read the risks section in the Forum Description before adopting.

## What's here

| Document | Purpose |
| -------- | ------- |
| [docs/Build-Runbook.md](docs/Build-Runbook.md) | Step-by-step, interview-driven build guide. Your own AI (or you) authors the scripts locally from the Companion Scripts — nothing is downloaded and run blind. |
| [docs/Companion-Scripts.md](docs/Companion-Scripts.md) | Annotated, byte-accurate source of `backup.ps1`, `restore.ps1`, and `evaluate-workspaces.ps1`, using `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders. **Canonical source of truth** for the scripts. |
| [scripts/](scripts/) | The same three scripts extracted verbatim as standalone `.ps1` files, for syntax highlighting and diffs. Convenience/audit copies — kept in sync with the Companion Scripts note. |
| [config.example.json](config.example.json) | Annotated example `config.json` showing the exact structure, nesting, and types, with placeholder paths. Copy, substitute, and drop the `_comment*` keys. |
| [docs/Forum-Description.md](docs/Forum-Description.md) | Adopter-facing overview: what it does, what it doesn't, dependencies, and the full list of known risks/limitations. |

> **Note on `scripts/`:** these files still carry the `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders as parameter defaults. Substitute them for your own paths (or always invoke with an explicit `-ConfigPath`) before running. The runbook's trustless flow — where your own AI authors the scripts locally — remains the recommended install path; `scripts/` is provided for convenience and auditing, not blind download-and-run.

## Installation

> [!WARNING]
> This is an **attended, interview-driven build**, not a one-click installer. You must be present at the keyboard to answer the setup interview and to approve the machine-level steps (sealing an encryption passphrase, creating a SYSTEM scheduled task, optional folder lockdown). It **cannot** run unattended. A copy-paste prompt is a convenience, **not consent** — your agent must still stop and ask you to approve each risky step.

Requirements: Windows 10/11 · PowerShell 5.1+ · 7-Zip · robocopy (built in) · a reachable backup destination (a network share or a second fixed disk). See [docs/Forum-Description.md](docs/Forum-Description.md) for the full dependency and risk list before you start.

Choose **one** method.

### Option A: Ask Clairvoyance to install it

Use this if you have a trusted Clairvoyance coding agent (Staff) that can run commands on your Windows machine. Paste the following prompt to that agent verbatim:

```text
Install and configure the Clairvoyance Versioning Backup System from
https://github.com/bubomortis/clairvoyanceai-backup-system

Treat docs/Build-Runbook.md in that repository as the AUTHORITATIVE, step-by-step
procedure. Read it in full and follow it exactly. Also read AGENTS.md at the repo
root before doing anything. Observe these rules:

1. IDEMPOTENCY FIRST. Before changing anything, check whether the backup system is
   already installed and valid on this machine: an existing tool directory holding
   backup.ps1 / restore.ps1 / evaluate-workspaces.ps1 + config.json, a sealed
   passphrase file, and the "Clairvoyance Nightly Backup" SYSTEM scheduled task. If
   it verifies, DO NOT reinstall, re-seal, or re-register anything — report the
   existing installation and stop.
2. Confirm this is Windows, PowerShell is 5.1 or later, 7-Zip and robocopy are
   present, and I have a reachable backup destination (network share or fixed disk).
   Report any missing prerequisite and stop.
3. Tell me up front that this is an ATTENDED build: I must stay present to approve
   "Allow Once" permission prompts, so it cannot be run unattended.
4. Ask me to choose a permanent LOCAL tool directory on a fixed disk that both
   Clairvoyance and a SYSTEM scheduled task can reach and execute (no UNC path, no
   OneDrive-synced folder, no temp directory).
5. AUTHOR THE SCRIPTS LOCALLY (trustless): write backup.ps1, restore.ps1, and
   evaluate-workspaces.ps1 into the tool directory from this repo's scripts/ (or the
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

Provided without warranty. See the Forum Description for the complete risk list (unencrypted-main default, machine-bound DPAPI, single-destination/no-offsite, restore caveats, and more).
