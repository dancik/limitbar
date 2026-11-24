# Changelog

## 1.2.0

- **Several accounts.** A second Claude or Codex login gets its own entry in the menu bar and the panel.
  Accounts come from `~/Library/Application Support/limitbar/extra-accounts.json` and, automatically, from the
  provider instances of T3 Code (read-only). The same login behind two folders is shown once. All polling
  rules apply per account. Details in the README.
- **`accounts.json`** in `~/Library/Caches/limitbar` (percentages, reset times, plan, display name) for other
  apps, and two distributed notifications: `io.github.dancik.limitbar.refresh` and `.quit`.
- **No menu bar icon:** `defaults write io.github.dancik.limitbar showStatusItem -bool false`.
- Codex accounts read their session logs first; a T3 Code account uses the latest log reading when LimitBar
  cannot see its sign-in. If `agy` is missing, T3 Code's copy of the Antigravity program is used.
- `LimitBar --probe --accounts`, `--list-accounts`, `--snapshot <png>`.

## 1.1.0

- **Usage view.** A **Limits | Usage** switch at the top of the panel. Usage shows, per service, the
  tokens and model calls of today or the last 7 days, a bar per day, and a line per model. Counted from
  the CLIs' own local records (Claude Code, Codex, Grok Build, Antigravity). They are read only while you
  look at Usage, incrementally. Nothing of a conversation is kept; the README lists exactly which files
  are read and what the index stores.
- `LimitBar --usage` prints the same numbers as JSON.
- **Gemini limits:** a Gemini model group nobody uses (0 %) is no longer listed under the one that binds,
  and a reset time is never cut off.

## 1.0.3

- **App icon.** LimitBar now has its own icon in Finder, Spotlight and Launchpad (it had the generic one).
- **Installs into `/Applications`**, where Spotlight and Launchpad find it. Before, it went to
  `~/Applications`, which Spotlight often does not index, so typing "LimitBar" found nothing. Any admin
  account can write to `/Applications` without a password (the same as a drag-and-drop install), so the
  installer still needs no `sudo`. A standard, non-admin account keeps getting `~/Applications`.
- **Upgrading from 1.0.2** moves the app: the copy in `~/Applications` is replaced by a link to the one in
  `/Applications`, so a Claude Code status line pointing at `~/Applications/LimitBar.app` keeps working.
- The installer and `--uninstall` only ever remove a real LimitBar bundle owned by your account (checked by
  bundle id and owner, again after moving it aside) or a link; anything else named `LimitBar.app` —
  including another account's copy in `/Applications` — is left alone and the install stops.
- `--uninstall` exits with an error when it could not remove everything.
- `LIMITBAR_PER_USER=1` keeps the app in `~/Applications` for those who do not want it in the shared
  `/Applications`.

## 1.0.2

- Recognise a signed-out Codex and Antigravity (shown as "Signed out", not as an error).

## 1.0.1

- Codex installed with npm works inside the sandbox.
- The installer checks build provenance only when the GitHub CLI is signed in (an unauthenticated `gh`
  no longer aborts the install).
- Clearer instructions for AI agents in INSTALL.md.

## 1.0.0

- First public release.
