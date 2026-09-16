# TUR-1006 implementation plan (branch-local working notes)

Contract: `docs/specs/domains/agent-runtime.md` (EMB-1244 Stage 2 supervision
section, "Progress is distinct from status"). Architecture: simple/localized,
Module `ImplementerDelegation.Supervision`, Adapter `HerdrTransport`.

## Live evidence (this session, Herdr 0.8.2, claude_code orchestrator)

- `agent read --source recent-unwrapped --lines 40` while `working` →
  `{"error":{"code":"agent_not_idle",...}}` (reproduced).
- `agent read --source recent-unwrapped` with no `--lines`, and
  `--source visible` / `--source detection`, return ~2.3 KB while working.
- Two reads 6 s apart differ only in UI churn: spinner glyph, elapsed timer
  `(2m 45s · ↓ 11.1k tokens)`, tool-call elapsed `(5s)`, the
  `(ctrl+b to run in background)` hint, and the tip line.
- `agent get` `revision`/`state_change_seq` did not change during real work.
- Provider transcript `$CLAUDE_CONFIG_DIR/projects/<slug>/<session>.jsonl`
  grows with every tool call (598 KB at 17:06Z).

## Planned shape (no new framework/store)

1. Transport seam: optional callback `progress_cursor/3` (session, agent,
   context) returning `{:ok, cursor} | {:error, reason}`; `HerdrTransport`
   implements it for the claude_code orchestrator by stat-ing the provider
   transcript under the run-owned `CLAUDE_CONFIG_DIR` (size + mtime), falling
   back to a `lines`-free `visible` read with UI-churn lines stripped. Codex
   keeps the existing `recent_unwrapped` 40-line hash path unchanged.
2. `Supervision.annotate_progress/2` prefers the transport progress cursor
   when exported; read errors stay `:unavailable`; unchanged cursor still
   drives bounded recovery and `:stale_working`.
3. `stale_working_ms` becomes a validated `agent_runtime` config field
   (default 900_000), threaded through `AgentRunner` like `turn_timeout_ms`.
4. Spec: agent-runtime.md documents real-work vs UI-churn vs read-failure
   progress semantics and the config field.

## RED tests (public `run_turn` seam)

- (a) agent_not_idle read + advancing real-work evidence → completes, no
  recovery probe (added, expected RED until 1–2 land).
- (b) UI-churn-only pane change + unchanged real-work evidence → bounded
  recovery then `:stale_working` after the bound (to add).
