#!/usr/bin/env bash
# Deterministic post-change checks for ~/.codex storage. See CODEX_STORAGE_GUARDRAILS.md §5.
set -euo pipefail
H="${CODEX_HOME:-$HOME/.codex}"
fail=0
say() { printf '%-34s %s\n' "$1" "$2"; }
if pgrep -fl "ChatGPT.app/Contents/MacOS/ChatGPT" >/dev/null; then say "ChatGPT Desktop" "RUNNING (close it before writing)"; else say "ChatGPT Desktop" "not running"; fi
for db in state_5.sqlite thread_history_1.sqlite; do
  r=$(sqlite3 "$H/$db" 'pragma integrity_check;')
  say "$db integrity" "$r"; [ "$r" = ok ] || fail=1
done
for t in thread_turns thread_items thread_realtime_items thread_history_projection_state; do
  n=$(sqlite3 "$H/thread_history_1.sqlite" "select count(*) from sqlite_master where type='table' and name='$t'")
  [ "$n" = 1 ] || { say "table $t" "MISSING"; fail=1; }
done
say "projection/turns/items" "$(sqlite3 "$H/thread_history_1.sqlite" "select (select count(*) from thread_history_projection_state)||' / '||(select count(*) from thread_turns)||' / '||(select count(*) from thread_items)")"
p=$(ls "$H/rollout-migrations" 2>/dev/null | wc -l | tr -d ' '); say "pending markers" "$p"; [ "$p" = 0 ] || fail=1
s=$(sqlite3 "$H/state_5.sqlite" "select count(*) from threads where rollout_path not like '$H/sessions/%' and rollout_path not like '$H/archived_sessions/%'"); say "stale state rows" "$s"; [ "$s" = 0 ] || fail=1
say "threads by provider" "$(sqlite3 -separator '=' "$H/state_5.sqlite" "select model_provider, count(*) from threads group by 1" | paste -sd ' ' -)"
say "rollouts active/archived" "$(find "$H/sessions" -name '*.jsonl' | wc -l | tr -d ' ') / $(ls "$H/archived_sessions"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
say "model_provider" "$(grep -m1 -E "^model_provider\s*=" "$H/config.toml")"
[ $fail = 0 ] && echo "OK" || { echo "FAIL"; exit 1; }
