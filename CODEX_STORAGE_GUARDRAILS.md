# Codex Desktop storage guardrails

Read this before touching anything under `~/.codex`, the hybrid provider, or the
Codex/ChatGPT Desktop integration. It exists because on 2026-09-24 a cleanup tool
wiped `thread_history_1.sqlite` and the first automated recovery attempt made six
threads worse. Everything below was verified against Codex `rust-v0.153.4`
(commit `3d2ee51`). Re-verify against the running version before relying on it.

## 1. Storage model (what is canonical, what is derived)

| Path | Role | Rebuildable? |
|---|---|---|
| `~/.codex/sessions/**/*.jsonl`, `~/.codex/archived_sessions/*.jsonl` | Canonical thread history (rollouts) | **No.** Never edit, renumber, concatenate, or dedupe. |
| `~/.codex/state_5.sqlite` | Thread metadata: selected `rollout_path`, `model_provider`, name, pin, section, archived, `history_mode` | Partially (backfill from rollouts). Treat as authoritative for the *selected* rollout of a paginated thread. |
| `~/.codex/thread_history_1.sqlite` | Projection of rollouts into `thread_turns` / `thread_items` / `thread_realtime_items` / `thread_history_projection_state` | Yes, but slowly (~1 GB for ~560 threads). Do not delete it to "fix" one thread. |
| `~/.codex/rollout-migrations/<thread-id>.pending` | Journal saying "migration published, SQLite recovery not finished" | Presence forces `recover_published_migration` for that thread on next start. |
| `~/.codex/config.toml` | Provider/feature config, includes `# BEGIN/END codex-router-managed` and `# BEGIN/END routemux-hybrid-provider` blocks | Managed by `sync-routemux.sh`. |

Rollout filename grammar: `rollout-<ts>-<thread-id>[_<rollout-id>].jsonl`.
The suffix after `_` is the immutable rollout ID; without a suffix the rollout ID
equals the thread ID. Continuation / revert / fork rollouts carry
`history_base = { thread_id, end_ordinal_exclusive, end_byte_offset }` in their
first line, and their first ordinal is `end_ordinal_exclusive`, not 0.

Projection state is keyed by **rollout ID**, one row per physical file. Reading a
thread joins every segment of its lineage (`resolve_rollout_lineage` follows
`history_base.thread_id` to the root). One logical thread may therefore need
several projection rows.

## 2. Hard rules

- Quit ChatGPT Desktop (Cmd+Q, confirm with `pgrep -fl "ChatGPT.app/Contents/MacOS"`)
  before writing to either SQLite file. The VS Code Codex extension also runs an
  `app-server`; it only holds `queue_1.sqlite`, but check `lsof` anyway.
- Back up **before** each write, with SQLite's online backup, not `cp`:
  `sqlite3 ~/.codex/state_5.sqlite ".backup '<dir>/state_5.sqlite'"` (same for
  `thread_history_1.sqlite`), plus `config.toml` and `rollout-migrations/`.
  Backups live in `~/.codex/history-repair-backup-<ts>/`; a valid one from the
  2026-09-24 repair is `~/.codex/history-repair-backup-20260924-083039/`.
- Never rebuild all threads to fix a few. `codex migrate-rollouts --apply --thread <id>`
  is per-thread, and `recover_published_migration` **deletes** the thread's
  projection before re-projecting.
- Never create `.pending` markers for threads whose selected rollout has
  `history_base` set. That path projects under the logical thread ID with
  initial ordinal 0 and fails with `expected ordinal 0, got N`.
  Remove a marker only after the thread lists turns correctly.
- Never "fix" `codex doctor` inventory warnings by deleting files. The 2 active +
  6 archived "missing rows" and 6 "duplicate rollout thread ids" are the base and
  intermediate segments of continuation lineages, not orphan threads.
- Do not update Codex, change the Node runtime, or edit the router as part of a
  storage repair. One variable at a time.
- Do not edit `model_provider`, names, pins, sections, or timestamps in `state_5`
  as a side effect of a history repair. The 2026-09-24 repair changed only
  `threads.rollout_path` (46 rows pointing at the retired `~/.t3/provider-homes`).

## 3. Known traps

1. **`recover_published_migration` is standalone-only.** It works for the ~550
   threads whose selected rollout has `history_base = null` because there
   thread ID == rollout ID and the first ordinal is 0. It is wrong for
   continuation rollouts. The correct path is `materialize_to_sqlite(rollout_id,
   path)` per lineage segment, which `prepare_fork` and `revert_thread` already
   use. The helper that does exactly this lives in the backup dir under
   `recovery-tooling/` (Rust bin `history-reproject` + a 56-line patch adding
   `LocalThreadStore::reproject_thread_lineage`). Rebuild it from the exact tag:
   `git clone --depth 1 --branch rust-v<version> https://github.com/openai/codex`.
2. **`.pending` markers change startup behaviour.** Any marker makes
   `migrate_rollouts_on_startup` run `migrate_all_rollouts`. Leaving stale markers
   means every app launch retries and re-deletes the projection.
3. **Doctor "stale rows".** Rows whose `rollout_path` points at a file that moved
   (for example the old `~/.t3/provider-homes/...` layout). Fix by remapping the
   path to the existing file with the same thread ID, nothing else.
4. **Sidebar shows only the active provider's threads.** `thread/list` with
   `modelProviders: null` (what the Desktop sends) defaults to
   `[config.model_provider_id]`. With `model_provider = "custom"` the sidebar
   hides the 217 `openai` and 206 `routemux` threads. For local hosts the filter is
   applied to the JSONL session-meta provider (filesystem-first listing), so
   rewriting `state_5.threads.model_provider` does **not** bring them back, and the
   JSONL heads must not be edited. Project/section listings use `modelProviders: []`
   and the state DB only, so threads inside a project stay visible regardless of
   provider. Resolved 2026-09-24 by moving the root provider back to `openai`
   (§4); the `custom` threads created 2026-09-20..24 are the ones hidden now.
5. **No account, no weekly limit widget.** With `requires_openai_auth = false`
   the app-server answers `account/read` with `{ account: null,
   requiresOpenaiAuth: false }`, so the Desktop treats the user as logged out and
   hides plan/limit UI. `account/rateLimits/read` still works because it reads the
   ChatGPT auth from `auth.json` directly. Verified 2026-09-24: weekly window
   (10080 min) at 100 %, which is exactly the state that blocks the composer under
   the `openai` provider. Resolved 2026-09-24 by the §4 layout; the composer block
   while the weekly window is exhausted is accepted.

6. **Archive/unarchive traffic right after launch is usually the user.** Observed
   2026-09-24 11:40:34–11:41:48 UTC: the renderer issued 38 `thread/unarchive`
   requests (one every ~2 s) for threads from 09-21/09-22; the user was clicking.
   The app-server moved the files from `archived_sessions/` to `sessions/` and
   flipped `threads.archived`; no other column changed. Expect active/archived
   counts to shift after a launch and do not read that as corruption or as a
   side effect of a storage repair. Compare `state_5` against the last backup
   (`archived`, `rollout_path`) before concluding anything.

7. **False alarm on 2026-09-24: 98 threads vanished after the user archived and
   deleted them on purpose.** Lesson for automation: a drop in `state_5` rows plus
   missing JSONL is not proof of a bug. Before treating it as data loss, ask the
   user what they did in the Desktop in that window, and compare against the
   newest backup. Full snapshot of the state before that check:
   `~/.codex/history-repair-backup-20260924-091225-full`.

## 4. Provider architecture (current layout, verified 2026-09-24)

```
ChatGPT/Codex Desktop  (ChatGPT login; root provider = built-in `openai`)
  openai_base_url = http://127.0.0.1:4202/v1   (# BEGIN/END codex-router-managed)
  model_catalog_json = merged native + routemux/* catalog
        |
     codex-router  ->  gpt-*       -> ChatGPT subscription (native backend)
                   ->  routemux/*  -> RouteMux
  [model_providers.custom] "RouteMux Hybrid" stays defined but is not the root provider.
```

- Root provider `openai` is what makes the Desktop show the ChatGPT account, the
  5h/weekly limit widget and the GPT threads (sidebar lists only the root
  provider's threads, see trap 4). Verified with the Desktop's bundled codex
  0.155.0-alpha.16 via app-server: `account/read` returns the ChatGPT account,
  `thread/list` returns `openai` threads, `model/list` shows 23 `routemux/*` +
  native models, and a `routemux/openai/gpt-6-luna` turn completed through the
  router (`router.log` `provider=routemux status=200`) while the ChatGPT weekly
  window was at 100 %.
- Cost of this layout: the Desktop blocks the composer while the ChatGPT weekly
  window is exhausted, even for RouteMux models. That is accepted. The
  login-free alternative (`model_provider = "custom"`, used 2026-09-20..24) avoids
  the block but hides the account, the limit and every non-`custom` thread.
- `sync-routemux.sh` asserts this layout (`ROUTEMUX_EXPECT_PROVIDER` defaults to
  `openai`; set it to `custom` only for the login-free layout). It refuses to run
  while ChatGPT is open. Keep both checks.
- Do not re-enable `signed-routing`: it selects provider `codex-router-signed`,
  which hides the `openai` threads again.
- Config backups of the switch: `~/.codex/config.toml.bak-before-root-openai-*`.

## 5. Verification checklist (run after any storage change)

`./codex-storage-check.sh` runs the deterministic part. Expected:

- `PRAGMA integrity_check` = `ok` on both DBs.
- Tables `thread_turns`, `thread_items`, `thread_realtime_items`,
  `thread_history_projection_state` exist.
- 0 files in `~/.codex/rollout-migrations/`.
- 0 stale rows (`rollout_path` outside `~/.codex/sessions` / `archived_sessions`).
- Projection row `next_rollout_byte_offset` equals the file size of every
  rollout you touched.
- `codex doctor --all --no-color`: state DB and thread history DB `integrity ok`,
  `stale rows 0`. The duplicate/missing inventory warning and the npm PATH
  mismatch are pre-existing and acceptable.

Then the non-deterministic part, without starting a model turn:

- `codex app-server` over stdio: `initialize` → `initialized` → `thread/read` and
  `thread/turns/list` (asc and desc) for each repaired thread and one control
  thread. Real turns with `userMessage` items must come back, not an empty page.
- Open the Desktop and load one repaired thread with
  `open "codex://threads/<thread-id>"`. Check
  `~/Library/Logs/com.openai.codex/<date>/` for `expected ordinal`,
  `no such table`, or `failed to list thread history`.

## 6. Rollback

Restore the most recent `history-repair-backup-*` with `.backup`-produced files
(copy them back while the Desktop is closed, delete `-wal`/`-shm` siblings first).
Never fall back to a 4 KB `thread_history_1.sqlite`; that is the wiped state.
