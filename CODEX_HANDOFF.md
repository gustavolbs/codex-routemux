# CODEX HANDOFF — codex-routemux + ai-personas

Date: 2026-09-23

## Goal

Fix and harden the local integration between:

- `gustavolbs/codex-routemux`
- `gustavolbs/ai-personas`
- OpenAI ChatGPT/Codex Desktop on macOS
- RouteMux external models
- Native Codex multi-agent/subagent workflow

The desired UX is strict:

- Use the official ChatGPT/Codex Desktop app only.
- Keep the native model picker.
- Keep the same `~/.codex`, projects, threads, MCPs, skills, and ChatGPT login.
- Native `gpt-*` models use ChatGPT subscription quota.
- `routemux/*` models use RouteMux quota.
- When ChatGPT subscription quota is exhausted, RouteMux models must still work.
- Native Codex subagents must continue to work with RouteMux models.
- Do NOT replace native subagents with external `codex exec` threads/MCP workers unless there is no other option.
- Preserve native `spawn_agent`, parent/child relationship, context inheritance/forking, `wait_agent`, `send_message`, `followup_task`, and the native subagent UI.

---

## Current repositories

### codex-routemux

Repository:

`https://github.com/gustavolbs/codex-routemux`

Purpose:

- maintain RouteMux model discovery/sync;
- preserve hybrid provider routing;
- patch native Codex subagent collaboration so RouteMux children do not depend on ChatGPT quota relay.

Important files:

- `routemux-subagents.sh`
- `sync-routemux.sh`

Current intended routing:

```text
gpt-*       -> ChatGPT subscription/session
routemux/*  -> RouteMux
```

Important state:

```text
model_provider = custom
signed-routing = OFF
failover = OFF
chatgpt-session sharing = enabled
```

A recent local check returned:

```json
{
  "sharing": "enabled",
  "session": "usable",
  "present": true
}
```

A recent catalog refresh returned:

```text
models: 36
routed_models: 23
native_models: 13
login_free: false
routed_catalog_active: true
openai_authenticated: true
selected_model: routemux/openai/gpt-6-luna
```

Native models seen included:

```text
gpt-6-astra
gpt-6-sol
gpt-6-luna
gpt-reserve
gpt-5.6-sol
gpt-5.6-sol-1m
gpt-5.6-terra
gpt-5.6-luna
gpt-daybreak-blue-latest
gpt-daybreak-red-latest
gpt-5.5
gpt-5.4
```

RouteMux models are namespaced as:

```text
routemux/<provider>/<model>
```

Example:

```text
routemux/openai/gpt-6-luna
```

---

## Why the hybrid provider exists

The Desktop can globally block the composer when ChatGPT quota is exhausted even when an external provider still has quota.

The working architecture uses a custom provider façade so the Desktop does not bind the whole thread to ChatGPT quota, while `codex-router` routes by model:

```text
ChatGPT/Codex Desktop
        |
        v
model_provider = custom
        |
        v
codex-router
   |            |
   |            +--> routemux/* -> RouteMux
   |
   +--> gpt-* -> shared ChatGPT session/subscription
```

Do NOT re-enable `signed-routing` as the normal provider mode, because that was associated with the quota/composer blocking behavior we were trying to avoid.

---

## Subagent bug

Original failure:

```text
exceeded retry limit, last status: 429 Too Many Requests
```

This happened when native Codex subagents were spawned while ChatGPT quota was exhausted.

The suspected/identified flow was:

```text
RouteMux parent
   |
   v
spawn_agent
   |
   v
encrypted collaboration payload
   |
   v
native ChatGPT relay/decryption
   |
   v
429 due exhausted ChatGPT quota
```

The intended fix is to preserve native subagents but make routed collaboration use Codex's plaintext handoff path.

Codex recognizes:

```text
encrypted_function_args: []
```

as a direct/plaintext message path for collaboration calls.

The patch targets native collaboration calls such as:

```text
spawn_agent
send_message
followup_task
```

for routed `routemux/*` sessions.

The desired flow:

```text
RouteMux parent
   |
   v
native spawn_agent
   |
   v
DirectPlaintextMessage
   |
   v
native Codex child agent
   |
   v
RouteMux
```

No external MCP worker, no separate thread outside Codex's native parent/child lifecycle.

---

## Important bug already found in the subagent patch

The first patch looked correct in a wrapper self-test but did not affect the real router process.

Reason:

- `codex-router` starts `start.mjs`;
- `start.mjs` spawns the real `router.mjs` via `process.execPath`;
- `process.execArgv` was not forwarded;
- therefore a `node --import register.mjs ...` wrapper loaded the patch only in the supervisor, not in the actual router child.

The fix was changed to use:

```text
NODE_OPTIONS=--import=<register.mjs>
```

because `NODE_OPTIONS` is inherited by child Node processes.

A child-process self-test was added to verify that the loader reaches the actual spawned Node child.

There were two installer bugs already fixed afterward:

1. wrong use of `chatgpt-session status --json`
   - working command is:
   ```bash
   "$ROUTER/bin/control" chatgpt-session status
   ```

2. nested template literal syntax error in the child-process self-test
   - fixed by avoiding nested template literals.

Inspect the current `main` branch before changing anything.

---

## Persona repositories and lifecycle behavior

Repository:

`https://github.com/gustavolbs/ai-personas`

Current suite version should be at least:

```text
3.1.4
```

The personas are:

- Laila
- Roberto
- Clara
- Ana
- Ashley
- Dave
- Guto

Recent problem:

- native collaboration calls were accepted;
- UI showed messages like "Mensagem enviada para Clara/Dave/Guto";
- but the Desktop sometimes showed `0` active subagents;
- the parent persona (for example Laila) continued reading the repository itself;
- it was unclear whether children had actually completed, failed, or disappeared.

This exposed an orchestration bug:

```text
successful spawn != completed child
empty active-agent list != success
```

The persona suite was hardened so every delegating persona must:

- retain child/thread id;
- track pending/running/completed/failed/cancelled;
- keep doing only independent work while children run;
- call/wait for required children before synthesis;
- collect terminal child result;
- never interpret `0 active` as proof of completion;
- avoid duplicate retry while original child state is unknown;
- on confirmed 429, reduce concurrency and retry at most once when justified;
- explicitly report fallback instead of pretending the intended persona contributed.

There is a regression eval:

```text
evals/subagent-lifecycle.md
```

The lifecycle rule was moved into the always-loaded `SKILL.md` kernel of all personas, not only optional references.

---

## Skill installation paths

Current Codex source treats:

```text
~/.agents/skills
```

as the current user-level skill location.

It still reads:

```text
$CODEX_HOME/skills
```

for backward compatibility, but that path is deprecated for user skills.

For these personas, the intended canonical location is:

```text
~/.agents/skills/<persona>
```

The installer should remove duplicate persona copies from:

```text
~/.codex/skills/<persona>
```

while leaving Codex system skills intact.

The installer should verify that installed skills match the repository and contain the delegated-child lifecycle section.

---

## What to inspect locally

Please inspect the actual machine state instead of trusting this handoff blindly.

### 1. codex-routemux

```bash
cd ~/WORK/codex-routemux
git status
git log -5 --oneline
sed -n '1,260p' routemux-subagents.sh
sed -n '1,260p' sync-routemux.sh
```

### 2. ai-personas

```bash
cd ~/WORK/ai-personas
git status
git log -5 --oneline
cat VERSION
cat PERSONAS.json
```

Inspect at least:

```text
skills/laila/SKILL.md
skills/dave/SKILL.md
skills/guto/SKILL.md
skills/clara/SKILL.md
skills/ana/SKILL.md
skills/ashley/SKILL.md
skills/roberto/SKILL.md
evals/subagent-lifecycle.md
scripts/install-all.sh
scripts/verify-installed.sh
```

### 3. installed skills

```bash
find ~/.agents/skills -maxdepth 2 -name SKILL.md | sort
find ~/.codex/skills -maxdepth 2 -name SKILL.md | sort
```

Make sure our seven personas are canonical in `~/.agents/skills`.

### 4. codex-router state

```bash
ROUTER="$HOME/.local/share/codex-router"

"$ROUTER/bin/control" chatgpt-session status
"$ROUTER/bin/refresh-catalog"
```

Inspect the service/runtime and verify the subagent patch is loaded by the real router child, not just the supervisor.

---

## Acceptance tests

Do not run a large financial audit first.

Use a tiny test to minimize token cost.

Prompt:

```text
Laila, faça um teste mínimo de subagent.

Delegue para Dave a tarefa de inspecionar apenas o package.json deste repositório e responder:
1. qual é o package manager usado;
2. quais são os scripts dev e test, se existirem.

Você pode fazer trabalho independente enquanto ele executa, mas:
- use exatamente 1 subagent;
- guarde o child/thread id;
- não faça a análise do package.json no lugar dele;
- espere o subagent terminar usando o lifecycle nativo;
- só responda depois de receber o resultado terminal de Dave;
- informe no final se Dave completou, falhou ou exigiu fallback;
- não use fallback a menos que o child realmente falhe.
```

Expected behavior:

```text
Laila
  |
  +--> native spawn_agent(Dave)
           |
           +--> child appears as native subagent
           +--> child reads package.json
           +--> child returns result
  |
  +--> Laila waits for child
  +--> Laila uses Dave result
  +--> Laila reports Dave completed
```

Failure conditions:

- immediate `429 Too Many Requests`;
- no native child actually created;
- parent analyzes package.json itself despite child being required;
- parent treats "message sent" as completion;
- UI shows `0 active` and parent assumes success without a terminal child result;
- child is silently replaced by fallback;
- duplicate retry occurs while first child state is unknown.

---

## Engineering constraints

- Do not modify or re-sign ChatGPT.app.
- Do not introduce a second picker.
- Do not create a second CODEX_HOME.
- Do not break existing MCPs, skills, ChatGPT login, projects, history, or model picker.
- Do not switch to external `codex exec` workers unless native subagent preservation is proven impossible.
- Keep changes minimal and reversible.
- Prefer runtime/source verification over assumptions.
- Do not call a fix "done" until the integrated flow is observed end-to-end.
- Keep `codex-routemux` and `ai-personas` responsibilities separate:
  - transport/runtime compatibility belongs in `codex-routemux`;
  - persona orchestration/lifecycle belongs in `ai-personas`.

---

## Deliverable expected from local Codex

1. Reproduce the current failure.
2. Identify whether the failure is:
   - transport/runtime,
   - model routing,
   - subagent lifecycle,
   - stale skill installation,
   - or UI/reporting only.
3. Apply the smallest fix in the correct repository.
4. Add/adjust regression checks.
5. Run the tiny native-subagent acceptance test.
6. Report:
   - what was broken;
   - exact files changed;
   - exact validation performed;
   - whether native subagent lifecycle works end-to-end;
   - any remaining limitation.
