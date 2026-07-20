# Clairvoyance Versioning Backup System

A daily, versioned, GFS-tiered backup system for [Clairvoyance](https://clairvoyance.ai) workspaces on Windows. It mirrors app data + workspaces to a network share, produces SHA-256 manifests, splits secrets into a separate AES-256 encrypted archive, applies Grandfather-Father-Son retention (Daily/Weekly/Monthly/Annual + a weekly Artifacts tier), deep-verifies archives from the share, and runs unattended as a SYSTEM scheduled task.

This repository contains the **scrubbed, shareable** build materials — no instance identifiers, hostnames, paths, or secrets. It is provided **as-is**; read the risks section in the Forum Description before adopting.

## What's here

| Document | Purpose |
| -------- | ------- |
| [docs/Build-Runbook.md](docs/Build-Runbook.md) | Step-by-step, interview-driven build guide. Your own AI (or you) authors the scripts locally from the Companion Scripts — nothing is downloaded and run blind. |
| [docs/Companion-Scripts.md](docs/Companion-Scripts.md) | Annotated, byte-accurate source of `backup.ps1`, `restore.ps1`, and `evaluate-workspaces.ps1`, using `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders. **Canonical source of truth** for the scripts. |
| [scripts/](scripts/) | The same three scripts extracted verbatim as standalone `.ps1` files, for syntax highlighting and diffs. Convenience/audit copies — kept in sync with the Companion Scripts note. |
| [docs/Forum-Description.md](docs/Forum-Description.md) | Adopter-facing overview: what it does, what it doesn't, dependencies, and the full list of known risks/limitations. |

> **Note on `scripts/`:** these files still carry the `<TOOL_DIR>` / `<WORKSPACES_ROOT>` placeholders as parameter defaults. Substitute them for your own paths (or always invoke with an explicit `-ConfigPath`) before running. The runbook's trustless flow — where your own AI authors the scripts locally — remains the recommended install path; `scripts/` is provided for convenience and auditing, not blind download-and-run.

## Design notes

- **Trustless authoring:** you never copy-paste opaque binaries. The runbook has your AI write each script to disk from the auditable fenced source, substitute placeholders, and verify it parses before anything runs.
- **Secrets stay local:** the main archive is unencrypted for easy recovery; anything sensitive is routed to a separate AES-256 (`-mhe=on`) archive whose passphrase never leaves the machine (sealed via DPAPI).
- **Windows-specific:** requires 7-Zip, robocopy, PowerShell 5.1+, and a reachable destination (network share or fixed disk).

Provided without warranty. See the Forum Description for the complete risk list (unencrypted-main default, machine-bound DPAPI, single-destination/no-offsite, restore caveats, and more).
