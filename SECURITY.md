# Security policy

LimitBar runs other programs (the AI CLIs you installed) and is installed with a script, so its security
matters more than its size suggests. Reports are welcome.

**Report privately:** use GitHub's "Report a vulnerability" button on this repository's Security tab
(private vulnerability reporting). Please do not open a public issue for a vulnerability.

In scope, for example:
- any way LimitBar could read, store or send a credential, or expose one to a CLI's environment;
- running an executable it should have refused (see `CLI.trusted` in `Sources/LimitBar/Spawn.swift`);
- escaping or weakening the CLI sandbox (`Resources/cli.sb`) that codex, agy and grok run in;
- a `claude` invocation that loads user hooks, MCP servers or settings despite the isolation flags;
- an account folder outside the rules in `Accounts.checkedDir` (`Sources/LimitBar/Accounts.swift`) reaching a CLI, or
  widening the Codex sandbox's state folder;
- reading anything from T3 Code's `settings.json` beyond the fields the README names, or any credential file;
- anything identifying a person (e-mail, organisation, token) ending up in `accounts.json`, `state.json` or the panel;
- the installer accepting a modified archive, or `--from-source` building a different commit.

Not a vulnerability by itself: on an admin account the installer puts LimitBar into `/Applications`, which
every admin account on the Mac can write to without a password, as with any app installed there. The
`~/Applications/LimitBar.app` link then runs whatever is in `/Applications`. Use `LIMITBAR_PER_USER=1` (see
README → Install) to keep it in your own `~/Applications` instead.

Supported: the latest release.
