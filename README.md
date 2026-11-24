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
- **Where the tokens went.** Switch the panel to **Usage** for tokens and calls per model, today or over
  the last 7 days, with a bar per day — counted from the CLIs' own logs on your Mac.
- **Several accounts.** A second Claude (work and private) or Codex login gets its own entry; profiles
  you already set up in [T3 Code](https://t3.codes) are picked up by themselves, and the same login
  behind two folders is shown once.

## Install

Paste this into your AI agent (Claude Code, Codex, Gemini, Grok…):

> Install LimitBar by following https://github.com/dancik/limitbar/blob/main/INSTALL.md

Or run it yourself in Terminal:

```bash
d="$(mktemp -d)" && curl -fsSLo "$d/install.sh" https://raw.githubusercontent.com/dancik/limitbar/7105981982e652368b15e01b777164c999e213dd/install.sh && bash "$d/install.sh"
```

The link is pinned to one commit, so the script you run is exactly the one you can read
[here](https://github.com/dancik/limitbar/blob/7105981982e652368b15e01b777164c999e213dd/install.sh). It downloads the release
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

## Several accounts

An **account** is a service, a display name and the CLI's configuration folder (`CLAUDE_CONFIG_DIR` for
Claude, `CODEX_HOME` for Codex), optionally its own executable. The four standard accounts above (the CLI's
standard folder) always exist. More come from two places:

**1. Your own list** — `~/Library/Application Support/limitbar/extra-accounts.json`:

```json
{ "accounts": [
  { "vendor": "claude", "name": "Claude Work", "configDir": "~/.claude-work" },
  { "vendor": "codex",  "name": "Codex Work",  "configDir": "~/.codex-work", "binary": "/opt/homebrew/bin/codex" }
] }
```

`vendor` is `claude` or `codex`; `binary` is optional (the CLI from the usual places is used otherwise).
A folder is only accepted when it is a dot-folder of your home (`~/.claude-work`, not `~` or `~/.ssh`), owned
by you and not writable by others. LimitBar re-reads the file every 5 minutes. (Another path: `defaults write
io.github.dancik.limitbar extraAccountsFile /abs/path`.)

**2. T3 Code, automatically.** LimitBar reads the provider instances in `~/.t3/userdata/settings.json`
(read-only, and only `driver`, `displayName`, `enabled` and `config.homePath` / `setupMode` / `binaryPath` —
nothing that looks like a key, token or secret is touched). Claude instances with their own `homePath` become
Claude accounts; Codex instances with `homePath` or `setupMode: managed` become Codex accounts (with T3
Code's own `codex`); disabled instances are skipped; the name is T3 Code's `displayName`. Google Antigravity
instances are listed as *not supported*: Antigravity's `/quota` only reads `~/.gemini`, T3 Code runs it as an
ACP server with its own sign-in, and that server has no quota method — so there is no token-free way to ask it.

**Same login behind two folders = one account.** Claude's `auth status` and Codex's `account/read` identify
a login; LimitBar hashes it (SHA-256, in memory only — never written or shown) and shows each login once.
The standard account stays, and takes the name of a copy when that one has a better name (your own list >
T3 Code > the generic "Claude"). A copy is not polled again, only re-checked every 30 minutes. A signed-out
standard account is hidden while another account of the same service works.

All the polling rules above apply **per account**: activity, minimum gaps, the 20-minute limit for
`claude -p /usage`, sleep, one CLI at a time. The optional status-line file belongs to the standard
Claude account only. Codex accounts read their session logs first (`rate_limits` lines, no credentials; a symlinked `sessions` folder such as T3 Code's is resolved and checked like an account folder); when the CLI is missing or says signed out, a log reading younger than 45 minutes still counts (note "from session log"). For an account from T3 Code (whose sign-in LimitBar cannot see) a log reading of any age is used (dimmed when old); without any log it says "no reading yet — use ChatGPT in T3 Code once". A standard Codex account yields to a named one with the same logs. Two Codex accounts with a working CLI each that share one `sessions` folder cannot be told apart in the logs, so they are asked through `codex app-server` only.

If `agy` is not installed, LimitBar falls back to the same program in T3 Code's tools folder (checked like any binary); sign in once with it and `/quota` works.

## Reading the menu bar

| You see | Meaning |
|---|---|
| `23` | 23 % of the window **used** (5-hour for Claude and Codex) |
| `81ʷ` | a **weekly** window — that service has no 5-hour limit, or the weekly one is what binds |
| **red** | 90 % or more used |
| `23!` | the number shown is fine, but another window of the same service (e.g. the weekly) is at 90 %+ |
| `—` | no reading yet, or the window has reset since the last reading |
| dimmed | the reading is more than 45 minutes old |
| `p 23` | with several accounts of one service, a short tag (here for "privat") tells them apart; the panel has the full names |

Hover (or click to pin) for every window, reset times, plan, and anything that needs attention —
"Signed out — run `codex login`", for example.

## Usage: tokens per model

The **Limits | Usage** switch at the top of the panel turns it into a token count: per service the total
tokens and model calls, a bar per day (with **7 days**), and one line per model. Tokens are everything the
model processed — input, cached input and output — so a long Claude session with a big cached context
shows billions; that is normal.

| Service | Counted from | Notes |
|---|---|---|
| Claude | `~/.claude/projects/**/*.jsonl` | every reply Claude Code saved, interactive or `claude -p`; a reply is counted once, at its final size |
| Codex | `~/.codex/sessions/**/*.jsonl` | the running token total Codex writes after every model call |
| Grok | `~/.grok/sessions/*/*/usage.json` | per-turn totals per model, written by Grok Build itself |
| Gemini | `~/.gemini/antigravity-cli/conversations/*.db` | one database per conversation, opened read-only; each model step records its time and token counts. A conversation agy is still writing is counted once it is done |

The logs are read only while the panel shows Usage — when it opens, then every 30 seconds while it stays
open, never more than once a minute unless you press Refresh. Claude and Codex logs are read only from
where the last read stopped; Grok's `usage.json` and Antigravity's databases are small and read whole
when they change. Closing the panel stops a read in progress. The first read of a busy week can take a
few seconds.

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

## Without a menu bar icon

```bash
defaults write io.github.dancik.limitbar showStatusItem -bool false   # back: -bool true
```

LimitBar keeps running without the symbol (it picks the setting up within 30 seconds), collects as before and
writes `accounts.json`. Quit it with `pkill LimitBar` or by posting the distributed notification
`io.github.dancik.limitbar.quit`.

## For other apps: accounts.json and refresh

Every change of an account is written to `~/Library/Caches/limitbar/accounts.json` (atomic, `0600`, folder
`0700`): `{ "version": 1, "writtenAt", "accounts": [ { "id": "claude:work", "vendor", "name", "source":
"default|config|t3code", "state": "ok|missing|untrusted|signedOut|failed|unsupported", "plan", "bar", "windows":
[{ "label", "short", "used", "resetsAt" }], "notes", "measuredAt", "error" } ] }`. `used` is percent **used**
(`null` when unknown or the window has reset since the reading), times are ISO 8601 UTC, the order is the
display order. Never in it: token, cookie, e-mail, organisation name, account number. Copies of another
account and a hidden signed-out standard account are left out. `state.json` keeps its old shape (the
standard accounts, keyed by service).

An app can ask LimitBar to freshen up by posting the distributed notification
`io.github.dancik.limitbar.refresh` (no payload; handled at most every 5 s). It refreshes accounts whose reading
is older than 90 s, under the usual rules — it cannot make LimitBar run anything more often than hovering would.

## Security and privacy

For the limits, LimitBar runs these commands, and nothing else:

| Service | Command | Notes |
|---|---|---|
| Claude | `claude auth status --json` | only `loggedIn` and the plan name are kept; the email and organisation id in its answer are hashed in memory to recognise a repeated login, then dropped |
| Claude | `claude -p /usage --output-format json --max-turns 1 --restricted --strict-mcp-config --no-session-persistence --settings '{"disableAllHooks":true}'` | no model call; your hooks, MCP servers and settings files are not loaded; no transcript saved |
| Codex | reads `rate_limits` lines from `~/.codex/sessions/<today>/*.jsonl`; `codex app-server` → `account/rateLimits/read` and `account/read` (hashed like Claude's); `codex login status` | in the sandbox below |
| Gemini | `agy -p /quota --output-format json` | no model call; in the sandbox below |
| Grok | `grok agent stdio` → `_x.ai/billing` | in the sandbox below |

For the Usage view, LimitBar itself reads (never writes) the log files listed in
[Usage](#usage-tokens-per-model) — nothing else in those folders. These logs hold your conversations. Only
records that carry token counts are looked at: a Claude reply's structure is walked without decoding its
text, Codex's `turn_context`/`token_count` lines and Grok's `usage.json` are parsed in memory, and of
Antigravity's databases only each step's metadata is read, never its content. Nothing of a conversation
is stored, shown or sent: what is shown is model names, days and numbers, and what is stored is listed
under "What it stores" below. No CLI is run for it.
Every file is treated as untrusted: links inside those folders are not followed, counts and model names
are bounded, and Antigravity's databases are opened read-only and immutable, with a time limit.

**The sandbox.** `codex`, `agy` and `grok` run inside the macOS kernel sandbox profile
[`Resources/cli.sb`](Resources/cli.sb): each CLI can start no program outside its own install folder — so
no MCP server, hook or plugin you configured runs — and can read or write nothing in your home folder but
its own state folder (`~/.codex`, `~/.gemini`, `~/.grok`), nor other users' folders, mounted volumes or
shared temp. `agy` additionally needs `/usr/bin/security` and your keychain (that is where its sign-in
lives), `/tmp` (its local helper). For an account with its own `CODEX_HOME` the sandbox's "own state folder" is that folder instead of `~/.codex` — only after it passed the folder check above (a dot-folder of your home, yours, not writable by others; never `~`, `~/.ssh` and the like). Every CLI may still `stat` a path (Node and Go resolve paths that way) — that
reveals whether a path exists, never its contents or a folder listing. If the sandbox is unavailable,
the CLI is not run at all.

How it protects you:

- **No credentials, ever.** No token, cookie, keychain item or credential file is opened by LimitBar.
- **Minimal environment.** Each CLI gets only `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG` and a fixed
  `PATH` — none of your API keys, GitHub tokens or SSH agent socket — plus, for an extra account, its own
  `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
- **Only trustworthy executables.** A CLI is run only if it and its real file are owned by you or root
  and not writable by group or others. Anything else shows as "not run" in the panel.
- **Private working directory.** CLIs run in an empty folder of LimitBar's own, never in a project.
- **Hard limits.** One CLI at a time, 20–40 s deadline, the whole process group killed afterwards.
- **What it stores.** `~/Library/Caches/limitbar/state.json` and `accounts.json` (percentages, reset times,
  plan names, account display names) and `usage.json`: per log file a hashed key (not its name), its size, modification time and file identity,
  the read offset and token counts per model and day; for Claude, the week's replies under hashed ids so
  each counts once; for Codex, the current model and the session's running total; and the name of your
  time zone (days are local; another zone means counting again). Folder `0700`, files `0600`. No analytics, no network requests of its own.
  T3 Code's settings file is only read, and only the fields named above.
- **Tested.** [`tests/claude-canary.sh`](tests/claude-canary.sh) proves canary hooks and MCP servers
  fire *without* the flags above and stay silent *with* them; [`tests/sandbox.sh`](tests/sandbox.sh)
  proves the sandbox; [`tests/states.sh`](tests/states.sh) covers missing, signed-out and
  unsafe CLIs; [`tests/accounts.sh`](tests/accounts.sh) covers account discovery (a sample T3 Code settings
  file in [`tests/fixtures`](tests/fixtures)), the account-folder check and de-duplication;
  [`tests/usage.sh`](tests/usage.sh) checks the token counts against fake logs. CI runs them plus [gitleaks](https://github.com/gitleaks/gitleaks) on every push.
- **Release builds** are made by [`.github/workflows/release.yml`](.github/workflows/release.yml) on
  GitHub-hosted runners from the tagged commit, with a signed
  [build provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds).
  Check it yourself: `gh attestation verify LimitBar-1.1.0.zip --repo dancik/limitbar`.

The app is ad-hoc signed, not notarized (there is no paid Apple Developer ID behind it). Installed with
the script, macOS opens it normally; a zip downloaded **in a browser** will be blocked by Gatekeeper —
use the script or `--from-source` instead.

Found a problem? See [SECURITY.md](SECURITY.md).

## Uninstall

```bash
d="$(mktemp -d)" && curl -fsSLo "$d/install.sh" https://raw.githubusercontent.com/dancik/limitbar/7105981982e652368b15e01b777164c999e213dd/install.sh && bash "$d/install.sh" --uninstall
```

or quit LimitBar from its panel and delete `LimitBar` from Applications, `~/Applications/LimitBar.app`
(if present) and `~/Library/Caches/limitbar`.

## Build and test

```bash
scripts/build-app.sh build                  # → build/LimitBar.app (native arch)
build/LimitBar.app/Contents/MacOS/LimitBar --probe   # what every CLI returns right now, as JSON
build/LimitBar.app/Contents/MacOS/LimitBar --usage   # the Usage view's numbers, as JSON
build/LimitBar.app/Contents/MacOS/LimitBar --probe --accounts   # the same for every account, copies marked
build/LimitBar.app/Contents/MacOS/LimitBar --list-accounts      # the accounts found; no CLI is asked
build/LimitBar.app/Contents/MacOS/LimitBar --snapshot panel.png   # renders tray and panel off screen (no permission needed)
tests/states.sh build/LimitBar.app
tests/accounts.sh build/LimitBar.app
tests/sandbox.sh
tests/usage.sh build/LimitBar.app
tests/claude-canary.sh                      # needs Claude Code installed; makes no model call
```

## License

MIT. Service names and marks belong to their owners; LimitBar is not affiliated with Anthropic, Google,
OpenAI or xAI. Icon credits: [Resources/marks/README.md](Resources/marks/README.md).
