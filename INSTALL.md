# Installing LimitBar — instructions for an AI agent

You are installing LimitBar, a macOS menu bar app that shows the user's AI CLI usage limits.
Follow these steps exactly. Do not improvise other install methods.

1. **Check the machine.** Run `sw_vers -productVersion`. Continue only on macOS 14 or later.
2. **Download and show the installer** in one command (pinned to one commit — do not substitute `main`;
   shell variables may not survive between your tool calls, so keep the printed path):
   ```bash
   d="$(mktemp -d)" && curl -fsSLo "$d/install.sh" https://raw.githubusercontent.com/dancik/limitbar/7105981982e652368b15e01b777164c999e213dd/install.sh && echo "$d/install.sh" && cat "$d/install.sh"
   ```
3. **Tell the user** in two or three sentences what it does: downloads the release zip from GitHub,
   checks its SHA-256 against the digest written in the script (and GitHub build provenance if the
   GitHub CLI `gh` is installed and signed in — without it the SHA-256 check alone applies, which is
   expected), quits a running LimitBar, installs `LimitBar.app` into `/Applications` (into
   `~/Applications` on a standard, non-admin account) and opens it. No sudo, no password prompt.
   `~/Applications/LimitBar.app` always exists afterwards (a link when the app is in `/Applications`).
4. **Run it:** `bash <the printed path>`. Never with `sudo`. If it exits with any error — a failed check,
   or "exists and is not your LimitBar" — stop and report it. Do not work around it, and never delete or
   move a file the installer refused to touch.
5. **Check what LimitBar sees** (asks every installed CLI once; allow up to ~60 s):
   ```bash
   ~/Applications/LimitBar.app/Contents/MacOS/LimitBar --probe
   ```
   Services are `claude` (Claude Code), `codex` (Codex CLI), `gemini` (the Google Antigravity CLI,
   `agy`) and `grok` (Grok Build). For each, report the `state`:
   - `ok` — working. `bar.used` is the percentage **used** (not left) of the window in the menu bar,
     rounded; `notes` may add details worth passing on.
   - `missing` — that CLI is not installed. Only mention it if the user uses that service.
   - `signedOut` — tell the user to sign in **themselves**: `claude` then `/login`, `codex login`,
     run `agy` once, or `grok login`.
   - `untrusted` — the CLI (or its interpreter) is writable by another account, so LimitBar will not
     run it; tell the user, do not change permissions yourself.
   - `failed` — report the `error` text.
6. **Never** ask the user for, read, copy or print any token, API key, cookie or credential file. Signing
   in is always done by the user inside the official CLI.
7. Tell the user: LimitBar is in the menu bar; hover it for details; the panel has "Launch at Login".

To remove it later: run step 2, then `bash <the printed path> --uninstall` (removes the app, its cache
folder and its preferences).
