#!/bin/bash
# The Usage view's numbers from fake CLI logs, and what its index keeps. Covers: Claude replies written in
# several lines (last wins, also across other replies), copies of a reply in a second file, nested replies
# and look-alike keys inside content, keys in another order; Codex running totals and a compaction;
# Grok turns on their own days; Antigravity's conversation databases; files older than the window; a line
# completed after a read; a replaced file; and day boundaries in zones on both sides of UTC.
# Usage: tests/usage.sh <path to LimitBar.app>
set -euo pipefail
APP="${1:?usage: tests/usage.sh <LimitBar.app>}"
BIN="$APP/Contents/MacOS/LimitBar"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

run_zone() {   # run_zone <TZ>: the whole fixture set, with local times computed in that zone
export TZ="$1"
T="$ROOT/$(echo "$1" | tr / _)"
mkdir -p "$T"

# Local noon today and yesterday, and 23:30 local today (another UTC date on either side of UTC), written
# the way each CLI writes them.
read -r NOW YDAY LATE DAYDIR NOWSEC YSEC <<<"$(/usr/bin/python3 -c '
import datetime as d
t = d.datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
u = lambda x: x.astimezone(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
late = t.replace(hour=23, minute=30)
print(u(t), u(t - d.timedelta(days=1)), u(late), t.strftime("%Y/%m/%d"), int(t.timestamp()), int((t - d.timedelta(days=1)).timestamp()))')"

P="$T/.claude/projects/-tmp-secret-project"
mkdir -p "$P" "$T/.codex/sessions/$DAYDIR" "$T/.grok/sessions/p/s1/deeper" "$T/.gemini/antigravity-cli/conversations"
C="$P/s.jsonl"
# The real key order of a Claude Code reply line, shortened. msg_1 is written twice (output 10, then 50)
# with another reply in between; content carries look-alike keys and a quoted "usage".
line() {  # line <id> <model> <out> <time> [content]
  printf '{"parentUuid":"p","isSidechain":false,"message":{"model":"%s","id":"%s","type":"message","role":"assistant","content":[%s],"stop_reason":"end_turn","usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":1000,"output_tokens":%s,"cache_creation":{"ephemeral_5m_input_tokens":0},"iterations":[{"input_tokens":1}]}},"requestId":"r","type":"assistant","uuid":"u","timestamp":"%s","userType":"external","cwd":"/tmp/secret-project","sessionId":"s","version":"2"}\n' \
    "$2" "$1" "${5:-}" "$3" "$4"
}
{
  echo "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"what is \\\"usage\\\":{\\\"input_tokens\\\":999999} in the secret plan\"},\"timestamp\":\"$NOW\"}"
  line msg_1 claude-opus-test 10 "$NOW" '{"type":"tool_use","input":{"model":"leaked-title","id":"leaked-id","usage":{"output_tokens":5}}}'
  line msg_2 claude-sonnet-test 5 "$YDAY"
  line msg_1 claude-opus-test 50 "$NOW" '{"type":"text","text":"see \"usage\":{\"output_tokens\":777}"}'
  # A subagent progress record carrying a whole reply of its own: counted in the subagent's file, not here.
  echo "{\"type\":\"progress\",\"data\":{\"message\":{\"type\":\"assistant\",\"message\":{\"model\":\"claude-opus-test\",\"id\":\"msg_9\",\"usage\":{\"input_tokens\":5000,\"output_tokens\":5000}}}},\"timestamp\":\"$NOW\"}"
  # Keys in another order (usage first) still parse.
  echo "{\"type\":\"assistant\",\"timestamp\":\"$NOW\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":2},\"content\":[],\"id\":\"msg_4\",\"model\":\"claude-opus-test\"}}"
  echo "{\"message\":{\"model\":\"<synthetic>\",\"id\":\"msg_x\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}},\"type\":\"assistant\",\"timestamp\":\"$NOW\"}"
  printf '%s' "$(line msg_5 claude-opus-test 7 "$NOW")"          # no newline yet: written later
} > "$C"
# A resumed session copied msg_1 (final) into a second file: one reply, counted once.
line msg_1 claude-opus-test 50 "$NOW" > "$P/resumed.jsonl"
# A log untouched for 10 days is outside the window, whatever it says.
line msg_old claude-opus-test 1 "$NOW" > "$P/old.jsonl"
touch -t "$(date -v-10d +%Y%m%d%H%M)" "$P/old.jsonl"

CX="$T/.codex/sessions/$DAYDIR/rollout-test.jsonl"
cat > "$CX" <<J
{"timestamp":"$NOW","type":"session_meta","payload":{"id":"x","cwd":"/tmp/secret-project"}}
{"timestamp":"$NOW","type":"turn_context","payload":{"model":"gpt-test","cwd":"/tmp/secret-project"}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":null}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":90,"output_tokens":30}}}}
{"timestamp":"$NOW","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":0,"output_tokens":5}}}}
J

cat > "$T/.grok/sessions/p/s1/usage.json" <<J
{"session":{"totalTokens":700},"turns":[
 {"endedAt":"$NOW","modelUsage":{"grok-test":{"totalTokens":500,"modelCalls":2}}},
 {"endedAt":"$YDAY","modelUsage":{"grok-test":{"totalTokens":200,"modelCalls":1}}}]}
J
# Not where Grok Build writes usage: ignored.
echo "{\"turns\":[{\"endedAt\":\"$NOW\",\"modelUsage\":{\"grok-test\":{\"totalTokens\":99999,\"modelCalls\":9}}}]}" \
  > "$T/.grok/sessions/p/s1/deeper/usage.json"

# Antigravity: one conversation database (WAL mode, closed). Two model steps today, one yesterday, one
# step without usage; a step's payload holds conversation text that must never be read.
/usr/bin/python3 - "$T/.gemini/antigravity-cli/conversations/conv-1.db" "$NOWSEC" "$YSEC" <<'P'
import sqlite3, sys
def v(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def f(num, val):
    if isinstance(val, int): return v(num << 3) + v(val)
    return v(num << 3 | 2) + v(len(val)) + val
usage = lambda new, out, cached: f(1, 7) + f(2, new) + f(3, out) + (f(5, cached) if cached else b"") + f(6, 24) + f(7, b"bot-x")
step = lambda sec, u: f(1, f(1, sec) + f(2, 5)) + f(3, 2) + (f(9, u) if u else b"") + f(11, 7)
db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA journal_mode=WAL")
db.execute("CREATE TABLE steps (idx integer primary key, step_type integer, metadata blob, step_payload blob)")
db.execute("CREATE TABLE gen_metadata (idx integer primary key, data blob, size integer)")
now, yday = int(sys.argv[2]), int(sys.argv[3])
for i, (sec, u) in enumerate([(now, usage(100, 20, 0)), (now, usage(50, 10, 300)), (yday, usage(7, 3, 0)), (now, None)]):
    db.execute("INSERT INTO steps VALUES (?, 15, ?, ?)", (i, step(sec, u), b"the secret prompt"))
db.execute("INSERT INTO gen_metadata VALUES (0, ?, 0)", (f(1, f(4, usage(100, 20, 0)) + f(19, b"gemini-test")),))
db.commit(); db.close()
P

check() {   # check <label> <python expression over d (the --usage output)>
  "$BIN" --usage --home "$T" > "$T/out.json"
  /usr/bin/python3 - "$T/out.json" "$2" <<'P' || { echo "FAIL [$TZ] $1"; cat "$T/out.json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1]))
assert eval(sys.argv[2]), sys.argv[2]
P
  echo "ok   [$TZ] $1"
}

# msg_1 = 100+20+1000+50 = 1170, msg_4 = 3; msg_5 has no newline yet.
check "claude: one reply per id, last line wins, across files" \
  'd["claude"]["today"] == {"tokens": 1173, "calls": 2} and d["claude"]["models"]["claude-sonnet-test"] == {"tokens": 1125, "calls": 1}'
check "claude: nested, synthetic and look-alike keys ignored" \
  'set(d["claude"]["models"]) == {"claude-opus-test", "claude-sonnet-test"}'
check "codex: running totals become deltas; a compaction starts over" 'd["codex"]["today"] == {"tokens": 375, "calls": 3}'
check "grok: per-turn totals on their own day; deeper files ignored" \
  'd["grok"]["today"] == {"tokens": 500, "calls": 2} and d["grok"]["tokens"] == 700 and d["grok"]["calls"] == 3'
check "gemini: model steps from the conversation database" \
  'd["gemini"]["today"] == {"tokens": 480, "calls": 2} and d["gemini"]["tokens"] == 490 and d["gemini"]["models"] == {"gemini-test": {"tokens": 490, "calls": 3}}'

# The unfinished line is completed, and a reply arrives late in the evening.
{ echo; line msg_6 claude-opus-test 3 "$LATE"; } >> "$C"
check "a line completed after a read counts, and 23:30 local is still today" \
  'd["claude"]["today"] == {"tokens": 1173 + 1127 + 1123, "calls": 4}'
check "a read with nothing new changes nothing" 'd["claude"]["today"] == {"tokens": 3423, "calls": 4}'

# The Codex log is replaced by a different one of the same size: read again from the start.
sed 's/gpt-test/gpt-new!/' "$CX" > "$CX.new" && mv "$CX.new" "$CX"
check "a replaced file is read from the start" '"gpt-new!" in d["codex"]["models"] and "gpt-test" not in d["codex"]["models"]'

# agy writing a conversation (non-empty WAL) or a torn Grok rewrite: the counts already known stay.
G="$T/.gemini/antigravity-cli/conversations/conv-1.db"
echo "pending" > "$G-wal"; touch "$G"
cp "$T/.grok/sessions/p/s1/usage.json" "$T/grok.bak"; echo '{"turns":[' > "$T/.grok/sessions/p/s1/usage.json"
check "a database being written and a torn file keep their counts" \
  'd["gemini"]["tokens"] == 490 and d["grok"]["tokens"] == 700'
rm -f "$G-wal"; mv "$T/grok.bak" "$T/.grok/sessions/p/s1/usage.json"
check "and are counted again once readable" 'd["gemini"]["tokens"] == 490 and d["grok"]["tokens"] == 700'

# A log that cannot be read yet (permissions) is counted once it can, though its size and time are the same.
CY="$T/.codex/sessions/$DAYDIR/rollout-locked.jsonl"
printf '%s\n' "{\"timestamp\":\"$NOW\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-locked\"}}" \
  "{\"timestamp\":\"$NOW\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":7,\"output_tokens\":0}}}}" > "$CY"
chmod 000 "$CY"
check "an unreadable log counts nothing yet" '"gpt-locked" not in d["codex"]["models"]'
chmod 644 "$CY"
check "and is counted once readable" 'd["codex"]["models"]["gpt-locked"] == {"tokens": 7, "calls": 1}'

# What the index keeps: no path, project name, reply id or conversation text.
I="$T/limitbar-usage-index.json"
for s in secret msg_ leaked "what is" tmp- conv-1 bot-x; do
  if grep -q -- "$s" "$I"; then echo "FAIL [$TZ] the index contains '$s'"; exit 1; fi
done
echo "ok   [$TZ] the index holds no paths, ids or text"
}

for zone in UTC America/Los_Angeles Asia/Tokyo; do run_zone "$zone"; done

# Hostile or corrupt files must neither crash, hang nor be followed: absurd counts saturate, over-long
# model names and links are ignored, a database whose "steps" is a view (here an endless one) is refused
# before any query runs, and corrupt protobuf yields nothing.
export TZ=UTC
H="$ROOT/hostile"; HP="$H/.claude/projects/p"; HG="$H/.gemini/antigravity-cli/conversations"
mkdir -p "$HP" "$HG" "$ROOT/outside"
NOW="$(date -u +%Y-%m-%dT12:00:00.000Z)"
big=9223372036854775807
for i in 1 2 3; do
  echo "{\"message\":{\"model\":\"m\",\"id\":\"b$i\",\"usage\":{\"input_tokens\":$big,\"output_tokens\":$big}},\"type\":\"assistant\",\"timestamp\":\"$NOW\"}"
done > "$HP/big.jsonl"
long="$(printf 'x%.0s' $(seq 300))"
echo "{\"message\":{\"model\":\"$long\",\"id\":\"l1\",\"usage\":{\"input_tokens\":1}},\"type\":\"assistant\",\"timestamp\":\"$NOW\"}" > "$HP/long.jsonl"
echo "{\"message\":{\"model\":\"linked\",\"id\":\"k1\",\"usage\":{\"input_tokens\":1}},\"type\":\"assistant\",\"timestamp\":\"$NOW\"}" > "$ROOT/outside/target.jsonl"
ln -s "$ROOT/outside/target.jsonl" "$HP/link.jsonl"
ln -s "$ROOT/outside" "$HP/linkdir"
/usr/bin/python3 - "$HG" <<'P'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1] + "/endless.db")
db.execute("CREATE TABLE gen_metadata (idx integer, data blob)")
db.execute("CREATE VIEW steps AS WITH RECURSIVE r(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM r) SELECT x AS idx, x'0a' AS metadata FROM r")
db.commit(); db.close()
db = sqlite3.connect(sys.argv[1] + "/corrupt.db")
db.execute("CREATE TABLE gen_metadata (idx integer, data blob)")
db.execute("CREATE TABLE steps (idx integer, metadata blob)")
for blob in [b"\xff" * 50, b"\x0a\xff\xff\xff\xff\x0f", b"\x4a\x05\x08", b""]:
    db.execute("INSERT INTO steps VALUES (1, ?)", (blob,))
db.commit(); db.close()
P
start=$(date +%s)
"$BIN" --usage --home "$H" > "$H/out.json"
took=$(( $(date +%s) - start ))
/usr/bin/python3 - "$H/out.json" "$took" <<'P' || { echo "FAIL hostile files"; cat "$H/out.json"; exit 1; }
import json, sys
d = json.load(open(sys.argv[1])); took = int(sys.argv[2])
c = d["claude"]
assert set(c["models"]) == {"m"}, c["models"]            # no over-long name, nothing through a link
assert c["calls"] == 3 and c["tokens"] > 0, c             # saturated, not wrapped or crashed
assert d["gemini"]["tokens"] == 0 and d["gemini"]["calls"] == 0, d["gemini"]
assert took < 30, took                                    # the endless view was given up on
P
echo "ok   hostile files: no crash, no hang, no links, no over-long names"
echo "usage: all good"
