# Changelog

## Unreleased

- Choose visible services in the panel's Providers section. Save selections between launches,
  skip future polls for hidden providers and keep the menu item accessible when all are off.
- Show pacing for confirmed 5-hour and 7-day limits: a segmented time bar under each usage bar,
  time until reset, and hover details comparing usage with an even allowance across the window.
- Add pacing tests and a `--preview-panel <directory>` command that renders the native panel
  in light and dark mode using sample data without reading accounts or polling CLIs.

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
