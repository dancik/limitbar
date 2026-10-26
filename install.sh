#!/bin/bash
# limitbar installer. Read it before you run it — it is short on purpose.
#
#   bash install.sh                 download the release build, verify it, install it to /Applications
#                                   (or ~/Applications when this account cannot write there)
#   bash install.sh --from-source   build this exact commit yourself instead (needs Command Line Tools)
#   bash install.sh --uninstall     remove the app, its cache and its settings
#
# What it does NOT do: no sudo, no changes outside /Applications/LimitBar.app, ~/Applications,
# ~/Library/Caches/limitbar and (on --uninstall) LimitBar's own preferences, no
# Gatekeeper/quarantine overrides, no telemetry, no installing or signing in to any AI CLI.
set -euo pipefail

REPO="dancik/limitbar"
VERSION="1.1.0"
# Pinned by this commit of install.sh: the release zip must match it byte for byte, and the source build
# must check out exactly this commit.
ZIP_SHA256="2261c588c6a16ab5d538f0b8109262b404e6a81cb4bc1f1e310d13ee292b0999"
SOURCE_COMMIT="64cfc8682f2d04addb560a044ddf649205a9f322"

BUNDLE_ID="io.github.dancik.limitbar"
# /Applications when this account may write there — every admin account can, without a password, the
# same way a drag-and-drop install works. Spotlight and Launchpad find apps there; ~/Applications is
# often not indexed. A standard (non-admin) account gets ~/Applications, as before.
# LIMITBAR_PER_USER=1 keeps it in ~/Applications even for an admin (see README → Install).
if [[ -w /Applications && "${LIMITBAR_PER_USER:-}" != 1 ]]; then APP_DIR="/Applications"; else APP_DIR="$HOME/Applications"; fi
APP="$APP_DIR/LimitBar.app"
# The path older releases used and the README's status line points at. With the app in /Applications
# it is a symlink to it, so an existing status-line setting keeps working.
HOME_APP="$HOME/Applications/LimitBar.app"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'limitbar install: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$EUID" -ne 0 ]] || die "do not run as root — run it as yourself, no sudo needed"
if [[ "${LIMITBAR_PER_USER:-}" == 1 ]] && [[ -L "$HOME/Applications" || "$HOME/Applications" -ef /Applications ]]; then
  die "LIMITBAR_PER_USER=1 needs ~/Applications to be your own folder, but it is a link — not installing"
fi
major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$major" -ge 14 ]] || die "needs macOS 14 or later (this is $(sw_vers -productVersion))"

quit_running() { pkill -x -u "$(id -u)" LimitBar 2>/dev/null || true; sleep 0.5; }
# A real LimitBar bundle (not a symlink, our bundle id, owned by this account) — the only kind of thing
# this script removes or replaces. Another admin's copy in /Applications is theirs: left alone.
is_ours() {
  [[ -d "$1" && ! -L "$1" ]] && [[ "$(stat -f %u "$1")" == "$(id -u)" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" == "$BUNDLE_ID" ]]
}

# Put whatever is at $1 back, or, if something new took its place meanwhile, next to it under a new name.
# Success is judged by $1 being gone; if it is still here, the temp folder is kept, never deleted.
KEEP=""
put_back() {
  mv -n "$1" "$2" 2>/dev/null || true
  if [[ -e "$1" || -L "$1" ]]; then mv -n "$1" "$2.kept-$$-$RANDOM" 2>/dev/null && echo "kept it next to $2"; fi
  if [[ -e "$1" || -L "$1" ]]; then KEEP=1; echo "could not put $2 back — it is safe in $(dirname "$1")" >&2; fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  quit_running
  ASIDE="$(mktemp -d)"
  trap '[[ -n "$KEEP" ]] || rm -rf "$ASIDE"' EXIT
  LEFT=0
  for p in "/Applications/LimitBar.app" "$HOME_APP"; do
    if [[ -L "$p" ]]; then
      mv "$p" "$ASIDE/link" 2>/dev/null || { echo "could not remove the link $p"; LEFT=1; KEEP=1; continue; }
      if [[ -L "$ASIDE/link" ]]; then rm -f "$ASIDE/link"; else put_back "$ASIDE/link" "$p"; LEFT=1; fi
      continue
    fi
    [[ -e "$p" ]] || continue
    # Move it aside first and check what was actually moved, so nothing swapped in after a check is deleted.
    if ! is_ours "$p"; then echo "left $p alone: it is not your LimitBar"; LEFT=1; continue; fi
    mv "$p" "$ASIDE/LimitBar.app" 2>/dev/null || { echo "could not remove $p — delete it in Finder"; LEFT=1; KEEP=1; continue; }
    if is_ours "$ASIDE/LimitBar.app"; then rm -rf "$ASIDE/LimitBar.app"
    else put_back "$ASIDE/LimitBar.app" "$p"; echo "left $p alone: it is not your LimitBar"; LEFT=1
    fi
  done
  rm -rf "$HOME/Library/Caches/limitbar"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  if [[ "$LEFT" == 1 ]]; then echo "limitbar install: not everything was removed (see above)" >&2; exit 1; fi
  say "limitbar removed. If you turned on Launch at Login, macOS drops that entry by itself."
  exit 0
fi

STAGE="$(mktemp -d)"
trap '[[ -n "$KEEP" ]] || rm -rf "$STAGE"' EXIT

if [[ "${1:-}" == "--from-source" ]]; then
  xcrun --find swift >/dev/null 2>&1 || die "Swift not found. Install Command Line Tools first: xcode-select --install"
  say "Fetching source commit $SOURCE_COMMIT"
  git -C "$STAGE" init -q src
  git -C "$STAGE/src" fetch -q --depth 1 "https://github.com/$REPO.git" "$SOURCE_COMMIT"
  git -C "$STAGE/src" -c advice.detachedHead=false checkout -q FETCH_HEAD
  [[ "$(git -C "$STAGE/src" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || die "checked-out commit does not match the pin"
  say "Building (about 2 minutes)"
  "$STAGE/src/scripts/build-app.sh" "$STAGE/out" >/dev/null
  NEW="$STAGE/out/LimitBar.app"
else
  URL="https://github.com/$REPO/releases/download/v$VERSION/LimitBar-$VERSION.zip"
  say "Downloading LimitBar $VERSION"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$STAGE/LimitBar.zip" "$URL"
  got="$(shasum -a 256 "$STAGE/LimitBar.zip" | cut -d' ' -f1)"
  [[ "$got" == "$ZIP_SHA256" ]] || die "SHA-256 mismatch: got $got, expected $ZIP_SHA256 — not installing"
  say "SHA-256 verified"
  # Checked whenever the GitHub CLI can do it (installed and signed in); the pinned SHA-256 above is
  # always checked and is what guarantees these are the published bytes.
  if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    gh attestation verify "$STAGE/LimitBar.zip" --repo "$REPO" \
      --signer-workflow "$REPO/.github/workflows/release.yml" --deny-self-hosted-runners >/dev/null \
      || die "build provenance check failed — not installing"
    say "Build provenance verified (built by this repo's release workflow on GitHub-hosted runners)"
  else
    echo "(GitHub CLI not installed or not signed in: build provenance not checked; the pinned SHA-256 above was.)"
  fi
  # Refuse archives with absolute paths, '..' or symlinks before extracting anything.
  if zipinfo -1 "$STAGE/LimitBar.zip" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then die "unsafe path in archive"; fi
  if zipinfo -l "$STAGE/LimitBar.zip" | grep -q '^l'; then die "symlink in archive"; fi
  mkdir "$STAGE/out"
  ditto -x -k "$STAGE/LimitBar.zip" "$STAGE/out"
  NEW="$STAGE/out/LimitBar.app"
fi

[[ -d "$NEW" ]] || die "no LimitBar.app produced"
[[ -z "$(find "$NEW" -type l)" ]] || die "symlink inside the app bundle"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist")" == "$BUNDLE_ID" ]] || die "unexpected bundle id"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist")" == "$VERSION" ]] || die "unexpected version"
codesign --verify --strict "$NEW" || die "code signature does not verify — bundle was modified"

# The compatibility link is only needed when ~/Applications is a separate folder (it can itself be a
# link to /Applications — then the two paths are the same bundle and there is nothing to migrate).
MIGRATE=false
if [[ "$APP_DIR" == "/Applications" && ! "$HOME/Applications" -ef /Applications ]]; then MIGRATE=true; fi

# Never replace something that is not LimitBar: a clear message up front...
if [[ -e "$APP" || -L "$APP" ]] && ! is_ours "$APP"; then
  die "$APP exists and is not your LimitBar (a different app, a link, or another account's copy) — not touching it"
fi
if $MIGRATE && [[ ! -L "$HOME_APP" && -e "$HOME_APP" ]] && ! is_ours "$HOME_APP"; then
  die "$HOME_APP exists and is not your LimitBar — not touching it"
fi

# ...and the same check again on what was actually moved aside, so nothing swapped in after the check
# above is ever deleted with $STAGE.
set_aside() {   # set_aside <path> <name in $STAGE> [link-ok]
  [[ -e "$1" || -L "$1" ]] || return 0
  mv "$1" "$STAGE/$2" || { KEEP=1; die "could not move $1 aside — anything already moved is kept in $STAGE"; }
  if is_ours "$STAGE/$2" || [[ "${3:-}" == link-ok && -L "$STAGE/$2" ]]; then return 0; fi
  put_back "$STAGE/$2" "$1"
  die "$1 changed during the install and is not LimitBar — left as it was"
}

quit_running
mkdir -p "$APP_DIR"
set_aside "$APP" previous.app
if $MIGRATE; then set_aside "$HOME_APP" old-home.app link-ok; fi   # an older install, or our link
mv "$NEW" "$APP"
# mv into a directory that appeared in the meantime would nest the app inside it: refuse that too.
if ! is_ours "$APP" || [[ -e "$APP/LimitBar.app" ]]; then die "$APP changed during the install — not finished"; fi
if $MIGRATE; then
  mkdir -p "$HOME/Applications"
  ln -s "$APP" "$HOME_APP" || die "could not link $HOME_APP"
fi
say "Installed $APP"
open "$APP"
cat <<'MSG'

LimitBar is in your menu bar. It shows every AI CLI you have installed and signed in to:
  Claude Code (claude) · Google Antigravity (agy) · Codex (codex) · Grok Build (grok)
Hover it for 5-hour and weekly details. Not signed in to one? Sign in with that CLI itself —
LimitBar never asks for, reads or stores your credentials.
MSG
