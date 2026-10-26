#!/bin/bash
# What a user sees with each CLI missing, signed out or unsafe — with fake CLIs, so it needs no account
# and never touches real sessions. Usage: tests/states.sh <path to LimitBar.app>
set -euo pipefail
APP="${1:?usage: tests/states.sh <LimitBar.app>}"
BIN="$APP/Contents/MacOS/LimitBar"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# Signed-out fakes, written the way each real CLI reports it.
cat > "$T/claude" <<'S'
#!/bin/bash
[[ "$1 $2" == "auth status" ]] && { echo '{"loggedIn":false}'; exit 1; }
echo "Not logged in · Please run /login"; exit 1
S
cat > "$T/agy" <<'S'
#!/bin/bash
echo "Error: not signed in. Please sign in by running agy."; exit 1
S
# Codex 0.163 signed out, verbatim: `login status` says it on stderr only; app-server answers with an error.
cat > "$T/codex" <<'S'
#!/bin/bash
[[ "$1 $2" == "login status" ]] && { echo "Not logged in" >&2; exit 1; }
read -r _; echo '{"jsonrpc":"2.0","id":1,"result":{}}'; read -r _; read -r _
echo '{"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}'
S
# grok runs under Resources/cli.sb, which lets only its own executable (and install folder) run. The fake
# Grok is a tiny compiled program, the way the real one is a native binary.
cat > "$T/grok.c" <<'S'
#include <stdio.h>
int main(void) {
  char line[4096];
  if (!fgets(line, sizeof line, stdin)) return 1;
  puts("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1}}"); fflush(stdout);
  if (!fgets(line, sizeof line, stdin)) return 1;
  puts("{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32000,\"message\":\"Not authenticated\"}}");
  fflush(stdout);
  return 0;
}
S
cc -o "$T/grok" "$T/grok.c"
chmod 755 "$T/claude" "$T/agy" "$T/codex" "$T/grok"
cp "$T/codex" "$T/codex-unsafe"; chmod 775 "$T/codex-unsafe"     # group-writable file: must never run
mkdir "$T/shared"; chmod 777 "$T/shared"; cp "$T/codex" "$T/shared/codex"   # safe file, unsafe folder

probe() { "$BIN" --probe "$@" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join("%s=%s" % (k, d[k]["state"]) for k in sorted(d)))'; }
expect() { local got; got="$(probe "${@:2}")"; [[ "$got" == "$1" ]] && echo "ok   $got" || { echo "FAIL got: $got"; echo "     want: $1"; exit 1; }; }

expect "claude=missing codex=missing gemini=missing grok=missing" \
  -claudePath /nonexistent/claude -codexPath /nonexistent/codex -agyPath /nonexistent/agy -grokPath /nonexistent/grok
expect "claude=signedOut codex=signedOut gemini=signedOut grok=signedOut" \
  -claudePath "$T/claude" -codexPath "$T/codex" -agyPath "$T/agy" -grokPath "$T/grok"
expect "claude=missing codex=untrusted gemini=missing grok=missing" \
  -claudePath /nonexistent/claude -codexPath "$T/codex-unsafe" -agyPath /nonexistent/agy -grokPath /nonexistent/grok
expect "claude=missing codex=untrusted gemini=missing grok=missing" \
  -claudePath /nonexistent/claude -codexPath "$T/shared/codex" -agyPath /nonexistent/agy -grokPath /nonexistent/grok
mkdir "$T/badinterp"; chmod 777 "$T/badinterp"; cp /bin/bash "$T/badinterp/bash"
printf '#!%s/badinterp/bash\necho Not logged in\n' "$T" > "$T/codex-badinterp"; chmod 755 "$T/codex-badinterp"
expect "claude=missing codex=untrusted gemini=missing grok=missing" \
  -claudePath /nonexistent/claude -codexPath "$T/codex-badinterp" -agyPath /nonexistent/agy -grokPath /nonexistent/grok

# Gemini quota: the most-used Gemini group is the bar and always listed; Gemini groups at 0 % are left
# out of the panel, and so are unused non-Gemini groups. On a tie, agy's own order stands.
mkdir "$T/quota"
cat > "$T/quota/agy" <<'S'
#!/bin/bash
r='"reset_time":"2030-01-07T10:00:00Z"'
echo '{"command":{"data":{"groups":[
 {"name":"Gemini Test Model","buckets":[{"remaining_fraction":0.9,"window":"week",'"$r"'}]},
 {"name":"Gemini Models","buckets":[{"remaining_fraction":1,"window":"week",'"$r"'},{"remaining_fraction":1,"window":"5h",'"$r"'}]},
 {"name":"Claude Models","buckets":[{"remaining_fraction":1,"window":"week",'"$r"'}]},
 {"name":"GPT Models","buckets":[{"remaining_fraction":0.5,"window":"week",'"$r"'}]}]}}}'
S
cat > "$T/quota/agy-idle" <<'S'
#!/bin/bash
r='"reset_time":"2030-01-07T10:00:00Z"'
echo '{"command":{"data":{"groups":[
 {"name":"Gemini Test Model","buckets":[{"remaining_fraction":1,"window":"week",'"$r"'}]},
 {"name":"Gemini Models","buckets":[{"remaining_fraction":1,"window":"week",'"$r"'}]}]}}}'
S
chmod 755 "$T/quota/agy" "$T/quota/agy-idle"
windows() { "$BIN" --probe -claudePath /nonexistent/claude -codexPath /nonexistent/codex -grokPath /nonexistent/grok -agyPath "$1" \
  | /usr/bin/python3 -c 'import json,sys; g=json.load(sys.stdin)["gemini"]; print(g["state"], "|", ", ".join("%s %s %d" % (w["label"], w["short"], round(w["used"])) for w in g["windows"]), "| bar:", g["bar"]["label"])'; }
want="ok | Gemini Test Model w 10, GPT Models w 50 | bar: Gemini Test Model"
got="$(windows "$T/quota/agy")"; [[ "$got" == "$want" ]] && echo "ok   $got" || { echo "FAIL got: $got"; echo "     want: $want"; exit 1; }
want="ok | Gemini Test Model w 0 | bar: Gemini Test Model"
got="$(windows "$T/quota/agy-idle")"; [[ "$got" == "$want" ]] && echo "ok   $got" || { echo "FAIL got: $got"; echo "     want: $want"; exit 1; }
echo "PASS: states"
