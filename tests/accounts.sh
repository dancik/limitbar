#!/bin/bash
# Accounts: T3 Code discovery from a sample settings.json (tests/fixtures), the user's own list, which
# folders are accepted as account folders, and de-duplication of one sign-in behind several folders — with
# fake CLIs, so it needs no account and never touches real sessions or a real ~/.t3.
# Usage: tests/accounts.sh <path to LimitBar.app>
set -euo pipefail
APP="${1:?usage: tests/accounts.sh <LimitBar.app>}"
BIN="$APP/Contents/MacOS/LimitBar"
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
H="$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser("~")))')"
D="$H/.limitbar-accounts-test-$$"            # account folders must be dot-folders of $HOME
trap 'rm -rf "$T" "$D"' EXIT
mkdir -p "$D"

# ---- T3 Code: sample data folder -------------------------------------------------------------------
mkdir -p "$T/t3/userdata/providers/codex/codex_abc/shadow" "$T/t3/tools/codex/9.9.9/bin"
cp "$HERE/fixtures/t3-settings.json" "$T/t3/userdata/settings.json"
echo '{"version":"9.9.9"}' > "$T/t3/tools/codex/active.json"
printf '#!/bin/sh\nexit 0\n' > "$T/t3/tools/codex/9.9.9/bin/codex"; chmod 755 "$T/t3/tools/codex/9.9.9/bin/codex"

echo '{"accounts":[
  {"vendor":"claude","name":"Claude Extra","configDir":"~/.claude-extra"},
  {"vendor":"codex","name":"Codex Extra","configDir":"~/.codex-extra","binary":"/opt/homebrew/bin/codex"},
  {"vendor":"gemini","name":"Nope","configDir":"~/.gemini-x"},
  {"vendor":"claude","name":"Relative","configDir":"relative/dir"}]}' > "$T/extra.json"

list() { "$BIN" --list-accounts -t3Dir "$1" -extraAccountsFile "$2" | /usr/bin/python3 -c '
import json,sys,os
h=os.path.expanduser("~")
for a in json.load(sys.stdin)["accounts"]:
    cd=(a["configDir"] or "-").replace(h,"~"); b=(a["binary"] or "-").replace(h,"~")
    print(" ".join([a["id"],a["vendor"],a["source"],repr(a["name"]),cd,b]+(["unsupported"] if a["unsupported"] else [])))'; }

got="$(list "$T/t3" "$T/extra.json" | sed "s#$T#T#g")"
want="claude:default claude default 'Claude Home' - -
claude:claude-extra claude config 'Claude Extra' ~/.claude-extra -
claude:claude-work claude t3code 'Claude Work' ~/.claude-work -
claude:claude-work-2 claude t3code 'Claude Work' ~/.claude-work2 -
gemini:default gemini default 'Gemini' - -
gemini:antigravity gemini t3code 'Antigravity' - - unsupported
codex:default codex default 'Codex' - -
codex:codex-extra codex config 'Codex Extra' ~/.codex-extra /opt/homebrew/bin/codex
codex:codex-work codex t3code 'Codex Work' T/t3/userdata/providers/codex/codex_abc/shadow T/t3/tools/codex/9.9.9/bin/codex
codex:codex-own codex t3code 'Codex Own' ~/.codex-own -
grok:default grok default 'Grok' - -"
[[ "$got" == "$want" ]] && echo "ok   T3 Code + extra accounts found, disabled/other drivers skipped, same folder merged" \
  || { echo "FAIL list"; diff <(echo "$want") <(echo "$got") || true; exit 1; }

# no T3 Code, no list: the four standard accounts, nothing else
got="$("$BIN" --list-accounts -t3Dir "$T/none" -extraAccountsFile "$T/none.json" | /usr/bin/python3 -c 'import json,sys; print(" ".join(a["id"] for a in json.load(sys.stdin)["accounts"]))')"
[[ "$got" == "claude:default gemini:default codex:default grok:default" ]] && echo "ok   without T3 Code only the standard accounts" || { echo "FAIL standard: $got"; exit 1; }

# a broken settings.json must not break anything
echo '{ not json' > "$T/t3/userdata/settings.json"
got="$("$BIN" --list-accounts -t3Dir "$T/t3" -extraAccountsFile "$T/none.json" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)["accounts"]))')"
[[ "$got" == "4" ]] && echo "ok   unreadable settings.json ignored" || { echo "FAIL broken json: $got"; exit 1; }

# ---- account folders: only dot-folders of $HOME ------------------------------------------------------
mkdir -p "$D/ok" "$H/.limitbar-w-$$"; chmod 777 "$H/.limitbar-w-$$"
chk() { local got; got="$("$BIN" --check-dir "$2")"; [[ "$got" == "$1" ]] && echo "ok   folder $3: $got" || { echo "FAIL folder $3: $got"; exit 1; }; }
trap 'rm -rf "$T" "$D" "$H/.limitbar-w-$$"' EXIT
chk accepted "$D/ok"                     "a dot-folder of the home"
chk rejected "$H"                        "the home itself"
chk rejected "$H/.ssh"                   "~/.ssh"
chk rejected "/etc"                      "outside the home"
chk rejected "$T"                        "a temp folder"
chk rejected "$D/missing"                "a folder that does not exist"
chk rejected "$H/.limitbar-w-$$"         "a world-writable folder"
chk rejected "$H/.t3"                    "T3 Code's data folder itself"
ln -s /etc "$D/link"; chk rejected "$D/link" "a link to /etc"

# ---- one sign-in behind several folders is one account -----------------------------------------------
cat > "$T/claude" <<'S'
#!/bin/bash
id=std; [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && id="$(cat "$CLAUDE_CONFIG_DIR/identity")"
if [[ "$1 $2" == "auth status" ]]; then
  echo "{\"loggedIn\":true,\"email\":\"$id@example.com\",\"orgId\":\"org-$id\",\"orgName\":\"Org $id\",\"subscriptionType\":\"max\"}"; exit 0
fi
echo '{"result":"Current session: 12% used · resets Dec 24 at 9pm (UTC)\nCurrent week (all models): 30% used · resets Dec 30 at 9pm (UTC)"}'
S
chmod 755 "$T/claude"
for n in a b c; do mkdir -p "$D/$n"; done
echo same > "$D/a/identity"; echo same > "$D/b/identity"; echo other > "$D/c/identity"
cat > "$T/extra2.json" <<J
{"accounts":[{"vendor":"claude","name":"Claude A","configDir":"$D/a"},{"vendor":"claude","name":"Claude B","configDir":"$D/b"},
             {"vendor":"claude","name":"Claude C","configDir":"$D/c"},{"vendor":"claude","name":"Claude Bad","configDir":"$H/.ssh"}]}
J
"$BIN" --probe --accounts -claudePath "$T/claude" -codexPath /nonexistent/codex -agyPath /nonexistent/agy -grokPath /nonexistent/grok \
  -t3Dir "$T/none" -extraAccountsFile "$T/extra2.json" > "$T/probe.json"
/usr/bin/python3 - "$T/probe.json" <<'P'
import json,sys
raw=open(sys.argv[1]).read(); d=json.loads(raw)
for secret in ("example.com","org-","Org "): assert secret not in raw, "identity leaked into output: "+secret
st={a["id"]:a["state"] for a in d["accounts"]}
assert st["claude:claude-a"]==st["claude:claude-b"]==st["claude:claude-c"]=="ok", st
assert st["claude:claude-bad"]=="failed", st
assert d["duplicateOf"]=={"claude:claude-b":"claude:claude-a"}, d["duplicateOf"]
a=[x for x in d["accounts"] if x["id"]=="claude:claude-c"][0]
assert a["bar"]["used"]==12 and a["windows"][1]["used"]==30 and a["plan"]=="Max" and a["source"]=="config", a
print("ok   same sign-in found behind two folders, different one kept, no identity in output, bad folder refused")
P
# ---- Codex without a usable CLI: values from the session log (synthetic log, fixture) ----------------
CH="$D/codex-home"; DAY="$CH/sessions/$(date +%Y/%m/%d)"; mkdir -p "$DAY"
sed "s/@TS@/$(date -u +%Y-%m-%dT%H:%M:%S.000Z)/; s/@RESET@/$(( $(date +%s) + 3600 ))/g" "$HERE/fixtures/codex-rate-limits.jsonl" > "$DAY/rollout-test.jsonl"
cat > "$T/extra3.json" <<J
{"accounts":[{"vendor":"codex","name":"Codex Logs","configDir":"$CH","binary":"$T/no-such-codex"}]}
J
"$BIN" --probe --accounts -claudePath /nonexistent/claude -codexPath /nonexistent/codex -agyPath /nonexistent/agy -grokPath /nonexistent/grok \
  -t3Dir "$T/none" -extraAccountsFile "$T/extra3.json" > "$T/probe3.json"
/usr/bin/python3 - "$T/probe3.json" <<'P'
import json,sys
d=json.load(open(sys.argv[1]))
a=[x for x in d["accounts"] if x["id"]=="codex:codex-logs"][0]
assert a["state"]=="ok" and a["bar"]["used"]==17 and a["bar"]["short"]=="5h" and a["notes"]==["from session log"], a
assert [x["state"] for x in d["accounts"] if x["id"]=="codex:default"]==["missing"]
print("ok   Codex account without CLI reads its session log (note: from session log)")
P

# ---- Antigravity: T3 Code's copy of the program is the last-resort `agy`, and the hint names the command ----
case "$(uname -m)" in arm64) PL=darwin-arm64;; *) PL=darwin-x64;; esac
AV="$T/t3g/tools/antigravity-acp/$PL"; mkdir -p "$AV/versions/rel1" "$T/t3g/userdata"
echo '{"releaseId":"rel1"}' > "$AV/active.json"
cat > "$T/agy.c" <<'C'
#include <stdio.h>
int main(void) {
  puts("{\"command\":{\"data\":{\"groups\":[{\"name\":\"Gemini Test\",\"buckets\":[{\"window\":\"5h\",\"remaining_fraction\":0.97,\"reset_time\":\"2030-01-01T00:00:00Z\"}]}]}}}");
  return 0;
}
C
cc -o "$AV/versions/rel1/antigravity" "$T/agy.c"
chmod 755 "$AV/versions/rel1/antigravity"
echo '{"providerInstances":{"antigravity":{"driver":"antigravity","displayName":"Antigravity"}}}' > "$T/t3g/userdata/settings.json"
hint="$("$BIN" --list-accounts -t3Dir "$T/t3g" -extraAccountsFile "$T/none.json" | /usr/bin/python3 -c 'import json,sys; print([a["unsupported"] for a in json.load(sys.stdin)["accounts"] if a["unsupported"]][0])')"
[[ "$hint" == *"run "*"/versions/rel1/antigravity in Terminal" ]] && echo "ok   Antigravity entry names the sign-in command" || { echo "FAIL hint: $hint"; exit 1; }
if ls "$HOME/.local/bin/agy" /opt/homebrew/bin/agy /usr/local/bin/agy >/dev/null 2>&1; then echo "skip agy fallback (agy installed)"; else
  got="$("$BIN" --probe -claudePath /nonexistent/claude -codexPath /nonexistent/codex -grokPath /nonexistent/grok -t3Dir "$T/t3g" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin)["gemini"]; print(d["state"], round(d["bar"]["used"]))')"
  [[ "$got" == "ok 3" ]] && echo "ok   T3 Code's Antigravity program used when agy is missing" || { echo "FAIL agy fallback: $got"; exit 1; }
fi
echo "PASS: accounts"
