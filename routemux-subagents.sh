#!/usr/bin/env bash
set -euo pipefail

# RouteMux native subagents for ChatGPT/Codex Desktop on macOS.
#
# Keeps the native Codex multi-agent workflow (spawn_agent / send_message /
# followup_task / wait_agent) but marks RouteMux collaboration calls as
# plaintext at the client boundary. That prevents the router from needing the
# ChatGPT-native encrypted-payload relay, which is the hop that returns 429 when
# the ChatGPT subscription quota is exhausted.
#
# The runtime loader is propagated through NODE_OPTIONS because codex-router's
# start.mjs spawns router.mjs with process.execPath without forwarding
# process.execArgv. This keeps the fix active in the real router child process.
#
# No ChatGPT.app patch, no second CODEX_HOME, no alternate picker, no MCP-based
# replacement subagents, and no edits to the codex-router Git working tree.

ACTION="${1:-install}"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
STATE_DIR="${CODEX_ROUTER_STATE_DIR:-$CODEX_HOME/codex-router}"
MANIFEST="$STATE_DIR/install-manifest.json"
PATCH_DIR="$STATE_DIR/routemux-native-subagents"
PATCH_BIN="$PATCH_DIR/bin"
WRAPPER_NODE="$PATCH_BIN/node"
ACTUAL_NODE_FILE="$PATCH_DIR/actual-node"
REGISTER="$PATCH_DIR/register.mjs"
LOADER="$PATCH_DIR/loader.mjs"
ENSURE="$PATCH_DIR/ensure-service.sh"

ROUTER_LABEL="io.github.codex-router"
ROUTER_PLIST="$HOME/Library/LaunchAgents/$ROUTER_LABEL.plist"
GUARD_LABEL="io.github.routemux-native-subagents-guard"
GUARD_PLIST="$HOME/Library/LaunchAgents/$GUARD_LABEL.plist"
GUARD_LOG="$PATCH_DIR/guard.log"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer is for macOS only."
  command -v python3 >/dev/null 2>&1 || die "python3 not found."
  command -v launchctl >/dev/null 2>&1 || die "launchctl not found."
}

require_chatgpt_closed() {
  if pgrep -x ChatGPT >/dev/null 2>&1 || pgrep -x Codex >/dev/null 2>&1; then
    die "Quit ChatGPT completely with Cmd+Q, then run this command again."
  fi
}

plist_arg() {
  local index="$1"
  local plist="$2"
  [[ -f "$plist" ]] || return 1
  python3 - "$plist" "$index" <<'PY'
import plistlib, sys
p, i = sys.argv[1], int(sys.argv[2])
try:
    with open(p, "rb") as f:
        x = plistlib.load(f)
    print((x.get("ProgramArguments") or [])[i])
except Exception:
    raise SystemExit(1)
PY
}

source_root() {
  local root=""
  if [[ -f "$MANIFEST" ]]; then
    root="$(python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    x = json.load(open(sys.argv[1]))
    print(((x.get("current") or {}).get("sourceRoot") or "").strip())
except Exception:
    pass
PY
)"
  fi

  if [[ -z "$root" && -f "$ROUTER_PLIST" ]]; then
    local start
    start="$(plist_arg 1 "$ROUTER_PLIST" 2>/dev/null || true)"
    if [[ "$start" == */src/start.mjs ]]; then
      root="${start%/src/start.mjs}"
    fi
  fi

  if [[ -z "$root" && -f "$HOME/.local/share/codex-router/src/start.mjs" ]]; then
    root="$HOME/.local/share/codex-router"
  fi

  [[ -n "$root" && -f "$root/src/start.mjs" && -f "$root/src/namespace-relay.mjs" ]] \
    || return 1
  printf '%s\n' "$root"
}

actual_node() {
  local candidate=""

  if [[ -s "$ACTUAL_NODE_FILE" ]]; then
    candidate="$(cat "$ACTUAL_NODE_FILE")"
    if [[ -x "$candidate" && "$candidate" != "$WRAPPER_NODE" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  if [[ -f "$ROUTER_PLIST" ]]; then
    candidate="$(plist_arg 0 "$ROUTER_PLIST" 2>/dev/null || true)"
    if [[ -x "$candidate" && "$candidate" != "$WRAPPER_NODE" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  candidate="$(command -v node 2>/dev/null || true)"
  [[ -x "$candidate" && "$candidate" != "$WRAPPER_NODE" ]] || return 1
  printf '%s\n' "$candidate"
}

verify_hybrid_mode() {
  local config="$CODEX_HOME/config.toml"
  [[ -f "$config" ]] || die "Missing $config"

  python3 - "$config" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
root = re.split(r'(?m)^\s*\[', s, maxsplit=1)[0]
m = re.search(r'(?m)^\s*model_provider\s*=\s*["\']([^"\']+)["\']', root)
provider = m.group(1) if m else "openai"
if provider != "custom":
    raise SystemExit(
        f"Expected the hybrid model_provider='custom', found {provider!r}. "
        "Apply the hybrid RouteMux setup first."
    )
print("Hybrid provider: OK")
PY

  local root control status
  root="$(source_root)" || die "Could not locate the installed codex-router source root."
  control="$root/bin/control"
  [[ -x "$control" ]] || die "Missing codex-router control CLI: $control"
  status="$("$control" chatgpt-session status 2>/dev/null || true)"
  python3 - "$status" <<'PY'
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
print("ChatGPT session sharing: OK")
PY
}

write_runtime_files() {
  local node="$1"
  mkdir -p "$PATCH_BIN"
  chmod 700 "$PATCH_DIR" "$PATCH_BIN"
  printf '%s\n' "$node" > "$ACTUAL_NODE_FILE"
  chmod 600 "$ACTUAL_NODE_FILE"

  cat > "$REGISTER" <<'JS'
import { register } from "node:module";
register("./loader.mjs", import.meta.url);
JS
  chmod 600 "$REGISTER"

  cat > "$LOADER" <<'JS'
const TARGET_SUFFIX = "/src/namespace-relay.mjs";
const MARKER = "routemux-native-subagents-plaintext-v1";
const FUNCTION_START = "function rewriteNamespaceFunctionCallItem(";
const FUNCTION_END = "\n}\n\nexport function rewriteNamespaceFunctionCall";
const RETURN_ANCHOR = "  return rewritten === item ? undefined : rewritten;";
const INJECTION = `  // ${MARKER}
  // RouteMux-only: ask Codex to deliver collaboration messages as plaintext.
  // The Codex client recognizes encrypted_function_args: [] for
  // spawn_agent/send_message/followup_task as DirectPlaintextMessage.
  if (
    typeof sessionModel === "string" &&
    sessionModel.startsWith("routemux/") &&
    rewritten?.type === "function_call" &&
    rewritten?.namespace === "collaboration" &&
    ["spawn_agent", "send_message", "followup_task"].includes(rewritten.name)
  ) {
    rewritten = { ...rewritten, encrypted_function_args: [] };
  }
`;

let reported = false;
let warned = false;

export async function load(url, context, nextLoad) {
  const result = await nextLoad(url, context);
  if (!url.endsWith(TARGET_SUFFIX) || result.format !== "module" || result.source == null) {
    return result;
  }

  const original = typeof result.source === "string"
    ? result.source
    : Buffer.from(result.source).toString("utf8");

  if (original.includes(MARKER)) return result;

  const start = original.indexOf(FUNCTION_START);
  const end = start >= 0 ? original.indexOf(FUNCTION_END, start) : -1;
  if (start < 0 || end < 0) {
    if (!warned) {
      warned = true;
      process.stderr.write(
        "[routemux-subagents] codex-router changed; plaintext collaboration patch was not applied.\n",
      );
    }
    return result;
  }

  const functionEnd = end + 2;
  const before = original.slice(0, start);
  const target = original.slice(start, functionEnd);
  const after = original.slice(functionEnd);
  if (!target.includes(RETURN_ANCHOR)) {
    if (!warned) {
      warned = true;
      process.stderr.write(
        "[routemux-subagents] codex-router collaboration rewrite changed; patch skipped safely.\n",
      );
    }
    return result;
  }

  const patchedTarget = target.replace(RETURN_ANCHOR, `${INJECTION}${RETURN_ANCHOR}`);
  const source = before + patchedTarget + after;
  if (!reported) {
    reported = true;
    process.stderr.write(
      "[routemux-subagents] native RouteMux subagents: plaintext collaboration enabled.\n",
    );
  }
  return { ...result, source };
}
JS
  chmod 600 "$LOADER"

  cat > "$WRAPPER_NODE" <<'SH'
#!/bin/bash
set -euo pipefail
PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ACTUAL_NODE="$(cat "$PATCH_DIR/actual-node")"
REGISTER="$PATCH_DIR/register.mjs"
IMPORT_OPT="--import=$REGISTER"

# codex-router/start.mjs launches router.mjs and its other Node children with
# process.execPath, without forwarding process.execArgv. NODE_OPTIONS is
# inherited by those children, so the loader reaches the real router process.
case " ${NODE_OPTIONS:-} " in
  *" $IMPORT_OPT "*) ;;
  *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$IMPORT_OPT" ;;
esac

exec "$ACTUAL_NODE" "$@"
SH
  chmod 700 "$WRAPPER_NODE"

  cat > "$ENSURE" <<'SH'
#!/bin/bash
set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$(cd "$PATCH_DIR/.." && pwd)"
MANIFEST="$STATE_DIR/install-manifest.json"
WRAPPER="$PATCH_DIR/bin/node"
ACTUAL_NODE="$(cat "$PATCH_DIR/actual-node")"
ROUTER_PLIST="$HOME/Library/LaunchAgents/io.github.codex-router.plist"
LOG="$PATCH_DIR/guard.log"

if [[ "${1:-}" == "--watch" ]]; then
  sleep 3
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if pgrep -f 'codex-router.*update|src/update\.mjs|/bin/update' >/dev/null 2>&1; then
      sleep 5
    else
      break
    fi
  done
fi

current_node=""
if [[ -f "$ROUTER_PLIST" ]]; then
  current_node="$(python3 - "$ROUTER_PLIST" <<'PY' 2>/dev/null || true
import plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        x = plistlib.load(f)
    print((x.get("ProgramArguments") or [""])[0])
except Exception:
    pass
PY
)"
fi

[[ "$current_node" == "$WRAPPER" ]] && exit 0
[[ -x "$ACTUAL_NODE" ]] || exit 1
[[ -f "$MANIFEST" ]] || exit 1

SOURCE_ROOT="$(python3 - "$MANIFEST" <<'PY'
import json, sys
try:
    x = json.load(open(sys.argv[1]))
    print(((x.get("current") or {}).get("sourceRoot") or "").strip())
except Exception:
    pass
PY
)"
[[ -n "$SOURCE_ROOT" && -f "$SOURCE_ROOT/src/service-macos.mjs" ]] || exit 1

mkdir -p "$PATCH_DIR"
printf '[%s] restoring RouteMux native-subagent runtime after router service change\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"

CODEX_ROUTER_NODE_BIN="$WRAPPER" \
CODEX_ROUTER_STATE_DIR="$STATE_DIR" \
MODEL_ROUTER_STATE_DIR="$STATE_DIR" \
  "$ACTUAL_NODE" "$SOURCE_ROOT/src/service-macos.mjs" install >> "$LOG" 2>&1
SH
  chmod 700 "$ENSURE"
}

self_test() {
  local root="$1"
  log "Testing native collaboration rewrite against the installed codex-router..."

  "$WRAPPER_NODE" --input-type=module - "$root" <<'JS'
import { pathToFileURL } from "node:url";
const root = process.argv[2];
const m = await import(pathToFileURL(`${root}/src/namespace-relay.mjs`).href);

const tools = [{
  type: "namespace",
  name: "collaboration",
  tools: [
    { type: "function", name: "spawn_agent", parameters: { type: "object", properties: {
      message: { type: "string" }, task_name: { type: "string" }, model: { type: "string" }
    }, required: ["message", "task_name"] } },
    { type: "function", name: "send_message", parameters: { type: "object", properties: {
      target: { type: "string" }, message: { type: "string" }
    }, required: ["target", "message"] } },
    { type: "function", name: "followup_task", parameters: { type: "object", properties: {
      target: { type: "string" }, message: { type: "string" }
    }, required: ["target", "message"] } },
  ],
}];

const { namespaces } = m.flattenNamespaceTools(tools);
const lookups = m.buildNamespaceLookups(namespaces);
const args = {
  spawn_agent: { message: "x", task_name: "worker" },
  send_message: { target: "worker", message: "x" },
  followup_task: { target: "worker", message: "x" },
};

for (const name of ["spawn_agent", "send_message", "followup_task"]) {
  const event = {
    type: "response.output_item.done",
    item: {
      type: "function_call",
      name: `collaboration__${name}`,
      arguments: JSON.stringify(args[name]),
      call_id: `call-${name}`,
    },
  };
  const routed = m.rewriteNamespaceFunctionCall(event, lookups, "routemux/openai/gpt-6-luna");
  if (!routed || routed.item?.namespace !== "collaboration" || routed.item?.name !== name) {
    throw new Error(`${name}: native namespace restoration failed`);
  }
  if (!Array.isArray(routed.item.encrypted_function_args) || routed.item.encrypted_function_args.length !== 0) {
    throw new Error(`${name}: plaintext marker was not injected`);
  }

  const native = m.rewriteNamespaceFunctionCall(event, lookups, "gpt-6-luna");
  if (native?.item && Object.hasOwn(native.item, "encrypted_function_args")) {
    throw new Error(`${name}: native GPT call was modified`);
  }
}
console.log("self-test: OK");
JS

  log "Testing loader inheritance in a real child process..."

  "$WRAPPER_NODE" --input-type=module - "$root" <<'JS'
import { spawnSync } from "node:child_process";

const root = process.argv[2];
const code = [
  'import { pathToFileURL } from "node:url";',
  'const root = process.argv[2];',
  'const m = await import(pathToFileURL(root + "/src/namespace-relay.mjs").href);',
  'const tools = [{',
  '  type: "namespace",',
  '  name: "collaboration",',
  '  tools: [{',
  '    type: "function",',
  '    name: "spawn_agent",',
  '    parameters: {',
  '      type: "object",',
  '      properties: {',
  '        message: { type: "string" },',
  '        task_name: { type: "string" },',
  '        model: { type: "string" }',
  '      },',
  '      required: ["message", "task_name"]',
  '    }',
  '  }]',
  '}];',
  'const { namespaces } = m.flattenNamespaceTools(tools);',
  'const lookups = m.buildNamespaceLookups(namespaces);',
  'const event = {',
  '  type: "response.output_item.done",',
  '  item: {',
  '    type: "function_call",',
  '    name: "collaboration__spawn_agent",',
  '    arguments: JSON.stringify({ message: "PING", task_name: "worker" }),',
  '    call_id: "call-child-inheritance"',
  '  }',
  '};',
  'const routed = m.rewriteNamespaceFunctionCall(event, lookups, "routemux/openai/gpt-6-luna");',
  'if (!routed || routed.item?.namespace !== "collaboration" || routed.item?.name !== "spawn_agent") {',
  '  throw new Error("child process did not restore the native collaboration call");',
  '}',
  'if (!Array.isArray(routed.item.encrypted_function_args) || routed.item.encrypted_function_args.length !== 0) {',
  '  throw new Error("child process did not inherit the plaintext collaboration patch");',
  '}',
  'console.log("child-process self-test: OK");',
].join("\n");

const result = spawnSync(
  process.execPath,
  ["--input-type=module", "-", root],
  {
    input: code,
    encoding: "utf8",
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  },
);

if (result.status !== 0) {
  process.stderr.write(result.stderr || "");
  throw new Error("child-process self-test failed with exit " + result.status);
}
process.stdout.write(result.stdout);
JS
}}

install_guard() {
  mkdir -p "$HOME/Library/LaunchAgents"
  python3 - "$GUARD_PLIST" "$GUARD_LABEL" "$ENSURE" "$ROUTER_PLIST" "$MANIFEST" "$GUARD_LOG" "$HOME" <<'PY'
import plistlib, sys
out, label, ensure, router_plist, manifest, log, home = sys.argv[1:]
obj = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", ensure, "--watch"],
    "RunAtLoad": True,
    "WatchPaths": [router_plist, manifest],
    "StartInterval": 300,
    "ThrottleInterval": 10,
    "StandardOutPath": log,
    "StandardErrorPath": log,
    "EnvironmentVariables": {"HOME": home},
}
with open(out, "wb") as f:
    plistlib.dump(obj, f)
PY
  chmod 600 "$GUARD_PLIST"

  launchctl bootout "gui/$(id -u)/$GUARD_LABEL" >/dev/null 2>&1 || true
  launchctl enable "gui/$(id -u)/$GUARD_LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$GUARD_PLIST"
}

remove_guard() {
  launchctl bootout "gui/$(id -u)/$GUARD_LABEL" >/dev/null 2>&1 || true
  rm -f "$GUARD_PLIST"
}

ensure_router_service() {
  "$ENSURE" --now

  local current
  current="$(plist_arg 0 "$ROUTER_PLIST" 2>/dev/null || true)"
  [[ "$current" == "$WRAPPER_NODE" ]] \
    || die "The codex-router LaunchAgent did not switch to the compatibility runtime."
}

restore_router_service() {
  local root node
  root="$(source_root)" || die "Could not locate codex-router source root."
  node="$(actual_node)" || die "Could not locate the original Node executable."

  CODEX_ROUTER_NODE_BIN="$node" \
  CODEX_ROUTER_STATE_DIR="$STATE_DIR" \
  MODEL_ROUTER_STATE_DIR="$STATE_DIR" \
    "$node" "$root/src/service-macos.mjs" install >/dev/null
}

status() {
  require_macos
  local root current="" node="" guard="missing"
  root="$(source_root 2>/dev/null || true)"
  [[ -f "$ROUTER_PLIST" ]] && current="$(plist_arg 0 "$ROUTER_PLIST" 2>/dev/null || true)"
  [[ -s "$ACTUAL_NODE_FILE" ]] && node="$(cat "$ACTUAL_NODE_FILE")"
  [[ -f "$GUARD_PLIST" ]] && guard="installed"

  printf 'source root : %s\n' "${root:-not found}"
  printf 'router node : %s\n' "${current:-not found}"
  printf 'real node   : %s\n' "${node:-not recorded}"
  printf 'guard       : %s\n' "$guard"

  if [[ -n "$root" && -x "$WRAPPER_NODE" && "$current" == "$WRAPPER_NODE" ]]; then
    self_test "$root"
    printf 'status      : READY\n'
  else
    printf 'status      : NOT INSTALLED\n'
    return 1
  fi
}

install() {
  require_macos
  require_chatgpt_closed
  verify_hybrid_mode

  local root node
  root="$(source_root)" || die "Could not locate the installed codex-router source root."
  node="$(actual_node)" || die "Could not locate the Node executable used by codex-router."

  log "codex-router: $root"
  log "Node:         $node"

  write_runtime_files "$node"
  self_test "$root"
  install_guard
  ensure_router_service

  log
  log "Installed: RouteMux native subagents compatibility runtime"
  log
  log "What stays native:"
  log "  - ChatGPT/Codex Desktop"
  log "  - spawn_agent / wait_agent / send_message / followup_task"
  log "  - parent/child threads and context forks"
  log "  - MCPs, skills, projects and the native agent UI"
  log
  log "Routing:"
  log "  gpt-*       -> ChatGPT subscription"
  log "  routemux/*  -> RouteMux"
  log "  RouteMux collaboration handoff -> plaintext (no ChatGPT decrypt relay)"
  log
  log "Now reopen ChatGPT normally. No extra app or monitoring UI is required."
}

uninstall() {
  require_macos
  require_chatgpt_closed
  remove_guard
  if [[ -s "$ACTUAL_NODE_FILE" ]]; then
    restore_router_service
  fi
  rm -rf "$PATCH_DIR"
  log "Removed RouteMux native-subagent compatibility runtime."
  log "Your hybrid provider config, RouteMux models, MCPs and skills were not changed."
}

case "$ACTION" in
  install|apply|ensure) install ;;
  status) status ;;
  uninstall|remove|rollback) uninstall ;;
  *)
    cat >&2 <<'USAGE'
Usage:
  ./routemux-subagents.sh install
  ./routemux-subagents.sh status
  ./routemux-subagents.sh uninstall
USAGE
    exit 2
    ;;
esac
