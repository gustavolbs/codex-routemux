#!/usr/bin/env bash
set -euo pipefail

# RouteMux -> ChatGPT/Codex Desktop native picker sync.
# Assumes the one-time HYBRID provider migration is already applied:
#   gpt-*       -> ChatGPT subscription
#   routemux/*  -> RouteMux
#   model_provider = "custom"
#   signed-routing = OFF

ROUTER_BIN="${ROUTER_BIN:-codex-router}"
ROUTER_ROOT="${ROUTER_ROOT:-$HOME/.local/share/codex-router}"
CONTROL_BIN="${CONTROL_BIN:-$ROUTER_ROOT/bin/control}"
PROVIDER_ID="${PROVIDER_ID:-routemux}"
STATE_DIR="${CODEX_ROUTER_STATE_DIR:-$HOME/.codex/codex-router}"
CONFIG="$HOME/.codex/config.toml"
USER_MODELS="$STATE_DIR/user-models.json"
ROUTEMUX_KEY_FILE="$STATE_DIR/generic-provider-credentials/routemux.key"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/routemux-sync.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
DISCOVERY="$TMP/discovery.json"
PLAN="$TMP/plan.json"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v "$ROUTER_BIN" >/dev/null 2>&1 || die "codex-router not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
[[ -x "$CONTROL_BIN" ]] || die "missing $CONTROL_BIN"
[[ -f "$CONFIG" ]] || die "missing $CONFIG"

# The Desktop must be closed because it reads model_catalog_json at startup.
if pgrep -x ChatGPT >/dev/null 2>&1 || pgrep -x Codex >/dev/null 2>&1; then
  die "Quit ChatGPT completely with Cmd+Q, then run this script again."
fi

echo "== RouteMux hybrid sync =="
echo

# -----------------------------------------------------------------------------
# 1. Verify the permanent hybrid architecture.
# -----------------------------------------------------------------------------
python3 - "$CONFIG" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
root = re.split(r'(?m)^\s*\[', s, maxsplit=1)[0]
m = re.search(r'(?m)^\s*model_provider\s*=\s*["\']([^"\']+)["\']', root)
provider = m.group(1) if m else "openai"
if provider != "custom":
    raise SystemExit(f"Expected model_provider='custom', found {provider!r}.")
if "# BEGIN routemux-hybrid-provider" not in s:
    raise SystemExit("Hybrid provider block is missing from config.toml.")
print("Hybrid provider: OK")
PY

SESSION_JSON="$("$CONTROL_BIN" chatgpt-session status --json 2>/dev/null || true)"
python3 - "$SESSION_JSON" <<'PY'
import json, sys
try:
    x = json.loads(sys.argv[1])
except Exception:
    raise SystemExit("Could not read ChatGPT session-sharing status.")
if x.get("sharing") != "enabled" or x.get("session") != "usable":
    raise SystemExit(
        "ChatGPT session sharing is not ready. Run:\n"
        "  codex login\n"
        "  ~/.local/share/codex-router/bin/control chatgpt-session enable"
    )
print("ChatGPT subscription session: OK")
PY

echo

# -----------------------------------------------------------------------------
# 2. Verify RouteMux itself.
# -----------------------------------------------------------------------------
echo "Testing RouteMux provider..."
"$ROUTER_BIN" providers generic test "$PROVIDER_ID" --json >/dev/null
echo "RouteMux provider: OK"
echo

# -----------------------------------------------------------------------------
# 3. Discover the current RouteMux catalog.
# -----------------------------------------------------------------------------
echo "Refreshing RouteMux discovery..."
"$ROUTER_BIN" discover-models "$PROVIDER_ID" --refresh --json > "$DISCOVERY"

# Build desired/current/add/remove sets. Keep only reasoning-capable text/chat
# routes that Codex can safely expose in the picker.
python3 - "$DISCOVERY" "$USER_MODELS" "$PROVIDER_ID" "$PLAN" <<'PY'
import json, sys
from pathlib import Path

discovery_path, user_path, provider, plan_path = map(Path, sys.argv[1:])
provider_id = sys.argv[3]
obj = json.loads(discovery_path.read_text())

discovered = [str(x).strip() for x in (obj.get("discovered") or []) if str(x).strip()]
raw = obj.get("modelMetadata") or []
if isinstance(raw, dict):
    items = [{"upstreamId": k, **(v if isinstance(v, dict) else {})} for k, v in raw.items()]
elif isinstance(raw, list):
    items = [x for x in raw if isinstance(x, dict)]
else:
    items = []
by_id = {}
for x in items:
    rid = str(x.get("upstreamId") or x.get("id") or "").strip()
    if rid:
        by_id[rid] = x
if not discovered:
    discovered = sorted(by_id)

blocked_prefixes = ("anthropic/", "minimax/image-", "openai/gpt-image")
blocked_tokens = ("claude", "hailuo", "-image", "image-", "image01", "image02", "image03",
                  "vision-exp", "asr-", "speech-", "music-")

def compatible(rid):
    m = by_id.get(rid)
    if not m or m.get("supportsReasoning") is not True:
        return False
    inputs = {str(x).strip().lower() for x in (m.get("inputModalities") or []) if str(x).strip()}
    outputs = {str(x).strip().lower() for x in (m.get("outputModalities") or []) if str(x).strip()}
    low = rid.lower()
    return (
        bool(inputs) and inputs.issubset({"text", "image"}) and
        bool(outputs) and outputs.issubset({"text"}) and
        not any(low.startswith(p) for p in blocked_prefixes) and
        not any(t in low for t in blocked_tokens)
    )

desired = {rid for rid in discovered if compatible(rid)}
if not desired:
    raise SystemExit("No Codex-compatible RouteMux models were discovered.")

if user_path.exists():
    user = json.loads(user_path.read_text())
else:
    user = {"models": []}
current = {
    str(m.get("upstreamModel") or "").strip()
    for m in user.get("models", [])
    if m.get("provider") == provider_id and str(m.get("upstreamModel") or "").strip()
}

plan = {
    "desired": sorted(desired),
    "current": sorted(current),
    "add": sorted(desired - current),
    "remove": sorted(current - desired),
}
Path(sys.argv[4]).write_text(json.dumps(plan, indent=2) + "\n")
print(f"Compatible now : {len(desired)}")
print(f"Already curated: {len(current)}")
print(f"Add            : {len(plan['add'])}")
print(f"Remove         : {len(plan['remove'])}")
if plan["add"]:
    print("\nNew:")
    for x in plan["add"]: print(f"  + {x}")
if plan["remove"]:
    print("\nStale/incompatible:")
    for x in plan["remove"]: print(f"  - {x}")
PY

echo

# -----------------------------------------------------------------------------
# 4. Reconcile removals and additions.
# -----------------------------------------------------------------------------
REMOVE_CSV_VALUE="$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1]))["remove"]))' "$PLAN")"
ADD_COUNT="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["add"]))' "$PLAN")"

if [[ -n "$REMOVE_CSV_VALUE" || "$ADD_COUNT" -gt 0 ]]; then
  if [[ -f "$USER_MODELS" ]]; then
    BACKUP="$STATE_DIR/user-models.before-sync-$(date +%Y%m%d-%H%M%S).json"
    cp "$USER_MODELS" "$BACKUP"
    chmod 600 "$BACKUP"
    echo "Backup: $BACKUP"
  fi
fi

if [[ -n "$REMOVE_CSV_VALUE" ]]; then
  "$ROUTER_BIN" curate-models "$PROVIDER_ID" --remove "$REMOVE_CSV_VALUE" --apply
fi

probe_efforts() {
  local model="$1"
  [[ -s "$ROUTEMUX_KEY_FILE" ]] || { echo "low,medium,high,xhigh,max,ultra"; return; }
  ROUTEMUX_KEY="$(cat "$ROUTEMUX_KEY_FILE")" MODEL="$model" python3 - <<'PY'
import json, os, urllib.request, urllib.error
key=os.environ["ROUTEMUX_KEY"]
model=os.environ["MODEL"]
efforts=["low","medium","high","xhigh","max","ultra"]
accepted=[]
saw_400=False
for effort in efforts:
    body=json.dumps({"model":model,"input":"hi","reasoning":{"effort":effort},"max_output_tokens":8}).encode()
    req=urllib.request.Request(
        "https://api.routemux.com/v1/responses", data=body,
        headers={"Authorization":f"Bearer {key}","Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req, timeout=12) as r:
            if r.status == 200: accepted.append(effort)
    except urllib.error.HTTPError as e:
        if e.code == 400: saw_400=True
        else:
            print("low,medium,high,xhigh,max,ultra")
            raise SystemExit
    except Exception:
        print("low,medium,high,xhigh,max,ultra")
        raise SystemExit
if accepted:
    print(",".join(accepted))
elif saw_400:
    print("-")
else:
    print("low,medium,high,xhigh,max,ultra")
PY
}

if [[ "$ADD_COUNT" -gt 0 ]]; then
  echo
  echo "Adding new models..."
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    efforts="$(probe_efforts "$model")"
    if [[ "$efforts" == "-" ]]; then
      echo "  x $model — upstream rejected all reasoning efforts; skipped"
      continue
    fi
    echo "  + $model — efforts=$efforts"
    "$ROUTER_BIN" curate-models "$PROVIDER_ID" \
      --models "$model" \
      --efforts "$efforts" \
      --apply
  done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["add"]))' "$PLAN")
fi

echo

# -----------------------------------------------------------------------------
# 5. Refresh the single merged picker. Do NOT enable signed-routing.
# -----------------------------------------------------------------------------
"$CONTROL_BIN" failover off >/dev/null
"$ROUTER_ROOT/bin/refresh-catalog"
"$CONTROL_BIN" service restart >/dev/null

echo
"$ROUTER_BIN" status || true

echo
echo "DONE"
echo "  Native gpt-*  -> ChatGPT subscription"
echo "  routemux/*    -> RouteMux"
echo "  provider      -> custom"
echo "  signed-routing stays OFF"
echo
echo "Now reopen the official ChatGPT Desktop."
