# Agent instructions

- Before changing anything under `~/.codex`, the hybrid provider, `config.toml`, or
  the ChatGPT/Codex Desktop integration, read `CODEX_STORAGE_GUARDRAILS.md` and
  follow its backup and verification checklist. Run `./codex-storage-check.sh`
  after any storage change.
- `CODEX_HANDOFF.md` describes the subagent/RouteMux routing work and its constraints.
- Keep `codex-routemux` limited to transport/runtime concerns; persona lifecycle
  belongs in `gustavolbs/ai-personas`.
