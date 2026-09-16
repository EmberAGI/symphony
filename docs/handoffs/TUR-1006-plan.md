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

## Session 3 notes (2026-09-16 17:23Z–17:31Z)

- Deployed-code RED run (`mix test test/symphony_elixir/implementer_supervision_test.exs`,
  exit 1, 26 tests / 1 failure): the new test fails as
  `{:error, {:herdr_agent_read_failed, {:herdr_cli_error, "agent_not_idle", ...}}}`
  because the fixture refuses the post-turn response read too. The fixture
  must refuse only while `working` so the deployed code shows the target false
  `:stale_working`/recovery-probe failure (assigned to the worker).
- Operator constraint (17:28Z): real work = new `tool_use`/`tool_result`
  items in the provider transcript; size, mtime, heartbeats, retries and
  spinner churn never advance the cursor.
- Worker assignment `tur1006-green-1` sent 17:31Z to `implementer_worker`:
  transport `progress_cursor/3` optional callback (claude_code only, counts
  real-work items; `{:error, :not_applicable}` for Codex), supervision uses it
  before the pane-hash fallback, fixture fix, RED (b) + no-work tests.
- Orchestrator still owns: `stale_working_ms` config field (AC4), spec
  section in `docs/specs/domains/agent-runtime.md`, full gate, PR.
