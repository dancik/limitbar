# LimitBar

**How much of your AI coding limits you've used — in the macOS menu bar.** One glance for Claude Code,
Codex, Gemini (Google Antigravity) and Grok Build; hover for the 5-hour and weekly windows and when
they reset.

![LimitBar in the menu bar with its hover panel open](docs/screenshot.png)

- **Native and light.** A Swift menu bar app, no Electron, no background browser. It asks each CLI only
  when that CLI has been used, so an idle Mac spends ~nothing.
- **Never touches your credentials.** LimitBar asks the official CLIs you already use. It never reads,
  stores or sends a token, cookie or password — sign-in stays inside each CLI.
- **Only what you have.** CLIs you don't have installed stay out of the menu bar.

## Install

Paste this into your AI agent (Claude Code, Codex, Gemini, Grok…):

> Install LimitBar by following https://github.com/dancik/limitbar/blob/main/INSTALL.md

Or run it yourself in Terminal:

```bash
d="$(mktemp -d)" && curl -fsSLo "$d/install.sh" https://raw.githubusercontent.com/dancik/limitbar/831be887b637875199b19e14a91b721b44048dd1/install.sh && bash "$d/install.sh"
```

The link is pinned to one commit, so the script you run is exactly the one you can read
[here](https://github.com/dancik/limitbar/blob/831be887b637875199b19e14a91b721b44048dd1/install.sh). It downloads the release
build, checks its SHA-256 against the digest written into that script, checks GitHub's build provenance
when the [GitHub CLI](https://cli.github.com) is installed and signed in, and copies `LimitBar.app` to
`/Applications`, where Spotlight and Launchpad find it. Any admin account can write there without a
password, the same as a drag-and-drop install; on a standard account it goes to `~/Applications`
instead. No `sudo`, nothing outside `LimitBar.app`, `~/Applications` and `~/Library/Caches/limitbar`.

`/Applications` is shared by every account on the Mac, and any admin account can replace an app there
without a password — that is true of every app installed there, not only this one. If you'd rather keep
LimitBar private to your account, run the last command as `LIMITBAR_PER_USER=1 bash "$d/install.sh"`
and it goes to `~/Applications` (Spotlight may not find it there).

Prefer to compile it yourself? `bash "$d/install.sh" --from-source` builds the same pinned
commit on your Mac (needs Command Line Tools: `xcode-select --install`).

Requirements: macOS 14 or later, Apple silicon or Intel, and at least one of the CLIs below signed in.

## Sign in to the CLIs you use

LimitBar shows whatever is installed in the standard places (`~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.grok/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`). Sign in with
the CLI itself — once:

| Service | CLI | Sign in | What the menu bar shows |
|---|---|---|---|
| Claude (Pro / Max) | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) `claude` | run `claude`, then `/login` | 5-hour window |
| Codex (ChatGPT plans) | [Codex CLI](https://github.com/openai/codex) `codex` | `codex login` | 5-hour window |
| Gemini | [Google Antigravity CLI](https://antigravity.google) `agy` | run `agy` once | the most-used Gemini quota (often weekly) |
| Grok | [Grok Build](https://x.ai) `grok` | `grok login` | weekly credits |

Installed somewhere else? Point LimitBar at it:
`defaults write io.github.dancik.limitbar codexPath /full/path/to/codex` (same for `claudePath`,
`agyPath`, `grokPath`), then quit and reopen LimitBar.

## Reading the menu bar

| You see | Meaning |
|---|---|
| `23` | 23 % of the window **used** (5-hour for Claude and Codex) |
| `81ʷ` | a **weekly** window — that service has no 5-hour limit, or the weekly one is what binds |
| **red** | 90 % or more used |
| `23!` | the number shown is fine, but another window of the same service (e.g. the weekly) is at 90 %+ |
| `—` | no reading yet, or the window has reset since the last reading |
| dimmed | the reading is more than 45 minutes old |

Hover (or click to pin) for every window, reset times, plan, and anything that needs attention —
"Signed out — run `codex login`", for example.

Click **Providers** at the bottom of the panel to choose which services appear. Choices are saved
between launches and apply to the menu bar, panel and missing-CLI list. Hidden providers are excluded
from future refreshes; a reading already queued or running may finish. Turning a provider back on
requests a fresh reading. If all providers are off, the LimitBar menu item stays available so you can
turn them back on. All providers are enabled by default.

For confirmed 5-hour and 7-day windows, the panel also shows pacing. A solid usage bar sits above a
segmented time bar: five hourly segments for 5-hour limits, seven daily segments for weekly limits.
The lower bar fills as time passes, including a partial segment for the current hour or day. Both bars
share the same scale. Usage ahead of the time bar is over an even allowance; usage behind it is under.
Each row shows the time remaining. Hover a row for the elapsed percentage, exact reset time and
the difference in percentage points (pp). This compares usage with even spending over the full window.
Time includes nights and weekends.

Pacing updates every 30 seconds while the panel is open. It uses the last reported usage, whose age is
shown above the rows. Missing reset times, expired windows and unconfirmed window lengths have no pacing.
Older cached readings gain pacing after the next successful refresh.

## Optional: free Claude readings from the status line

By default LimitBar runs `claude -p /usage` at most once every 20 minutes (no model call, ~3 s of CPU).
If you want live Claude numbers at no cost, let Claude Code hand them over on every reply: add this to
`~/.claude/settings.json` (it **replaces** any status line you already have):

```json
"statusLine": { "type": "command", "command": "~/Applications/LimitBar.app/Contents/MacOS/LimitBar --statusline" }
```

`~/Applications/LimitBar.app` works wherever LimitBar was installed: with the app in `/Applications` it is
a link to it. It prints `Claude Opus · 5h 23% · 7d 41%` in Claude Code and saves only those percentages and reset
times to `~/Library/Caches/limitbar/claude-status.json`. LimitBar never edits your settings itself.

## Security and privacy

LimitBar runs these commands, and nothing else:

| Service | Command | Notes |
|---|---|---|
| Claude | `claude auth status --json` | only `loggedIn` and the plan name are kept; the email in its answer is dropped |
| Claude | `claude -p /usage --output-format json --max-turns 1 --restricted --strict-mcp-config --no-session-persistence --settings '{"disableAllHooks":true}'` | no model call; your hooks, MCP servers and settings files are not loaded; no transcript saved |
| Codex | reads `rate_limits` lines from `~/.codex/sessions/<today>/*.jsonl`; `codex app-server` → `account/rateLimits/read`; `codex login status` | in the sandbox below |
| Gemini | `agy -p /quota --output-format json` | no model call; in the sandbox below |
| Grok | `grok agent stdio` → `_x.ai/billing` | in the sandbox below |

**The sandbox.** `codex`, `agy` and `grok` run inside the macOS kernel sandbox profile
[`Resources/cli.sb`](Resources/cli.sb): each CLI can start no program outside its own install folder — so
no MCP server, hook or plugin you configured runs — and can read or write nothing in your home folder but
its own state folder (`~/.codex`, `~/.gemini`, `~/.grok`), nor other users' folders, mounted volumes or
shared temp. `agy` additionally needs `/usr/bin/security` and your keychain (that is where its sign-in
lives), `/tmp` (its local helper). Every CLI may still `stat` a path (Node and Go resolve paths that way) — that
reveals whether a path exists, never its contents or a folder listing. If the sandbox is unavailable,
the CLI is not run at all.

How it protects you:

- **No credentials, ever.** No token, cookie, keychain item or credential file is opened by LimitBar.
- **Minimal environment.** Each CLI gets only `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG` and a fixed
  `PATH` — none of your API keys, GitHub tokens or SSH agent socket.
- **Only trustworthy executables.** A CLI is run only if it and its real file are owned by you or root
  and not writable by group or others. Anything else shows as "not run" in the panel.
- **Private working directory.** CLIs run in an empty folder of LimitBar's own, never in a project.
- **Hard limits.** One CLI at a time, 20–40 s deadline, the whole process group killed afterwards.
- **What it stores.** `~/Library/Caches/limitbar/state.json` (percentages, reset times, plan names;
  folder `0700`, files `0600`). No analytics, no network requests of its own.
- **Tested.** [`tests/claude-canary.sh`](tests/claude-canary.sh) proves canary hooks and MCP servers
  fire *without* the flags above and stay silent *with* them; [`tests/sandbox.sh`](tests/sandbox.sh)
  proves the sandbox; [`tests/states.sh`](tests/states.sh) covers missing, signed-out and
  unsafe CLIs. CI runs them plus [gitleaks](https://github.com/gitleaks/gitleaks) on every push.
- **Release builds** are made by [`.github/workflows/release.yml`](.github/workflows/release.yml) on
  GitHub-hosted runners from the tagged commit, with a signed
  [build provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds).
  Check it yourself: `gh attestation verify LimitBar-1.0.3.zip --repo dancik/limitbar`.

The app is ad-hoc signed, not notarized (there is no paid Apple Developer ID behind it). Installed with
the script, macOS opens it normally; a zip downloaded **in a browser** will be blocked by Gatekeeper —
use the script or `--from-source` instead.

Found a problem? See [SECURITY.md](SECURITY.md).

## Uninstall

```bash
d="$(mktemp -d)" && curl -fsSLo "$d/install.sh" https://raw.githubusercontent.com/dancik/limitbar/831be887b637875199b19e14a91b721b44048dd1/install.sh && bash "$d/install.sh" --uninstall
```

or quit LimitBar from its panel and delete `LimitBar` from Applications, `~/Applications/LimitBar.app`
(if present) and `~/Library/Caches/limitbar`.

## Build and test

```bash
scripts/build-app.sh build                  # → build/LimitBar.app (native arch)
swift test                                 # pacing arithmetic and edge cases
build/LimitBar.app/Contents/MacOS/LimitBar --preview-panel build/preview  # sample PNGs, no account access
build/LimitBar.app/Contents/MacOS/LimitBar --probe   # what every CLI returns right now, as JSON
tests/states.sh build/LimitBar.app
tests/sandbox.sh
tests/claude-canary.sh                      # needs Claude Code installed; makes no model call
```

## License

MIT. Service names and marks belong to their owners; LimitBar is not affiliated with Anthropic, Google,
OpenAI or xAI. Icon credits: [Resources/marks/README.md](Resources/marks/README.md).
