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
- 17:35Z: turn ending under the deployed 15-min detector. Worker still
  `working` on `tur1006-green-1` (title "progress_cursor in supervision").
  Resume protocol: `git pull`, re-issue the SAME token `tur1006-green-1` with
  remaining scope, poll with single `herdr agent get implementer_worker` calls.

## Session 4 notes (2026-09-16 17:36Z–17:51Z)

- Worker result `tur1006-green-1 status=completed` integrated and committed at
  4911275 (transport `progress_cursor/3`, supervision prefers it, RED (a)/(b)
  + refused-read-no-work test). Targeted 5-suite run: 106 tests / 1 failure;
  the failure is pre-existing on baseline (`implementer_delegation_test.exs:221`
  expects the Codex permission map without this host's
  `/home/admin/scaling-octo-engine/.runtime/codex/implementer/skills`; it is
  host-environment dependent, not this change). Supervision + herdr_transport
  suites alone: 75 tests / 0 failures.
- Deployed-code RED evidence (branch tests vs c05566e module code): 28 tests /
  3 failures — (a) `left: {:ok, %{agent_status: "done"}}` vs
  `right: {:error, {:implementer_agent_stalled, ... progress_cursor: :unavailable,
  shutdown_reason: :stale_working}}`; (b) `implementer_hard_budget_exhausted`
  with churning pane hash `{148, 89980895}`; (c) `:unavailable` vs
  `{:provider_transcript, 7}`.
- Worker discovery accepted: real-work items = tool_use, tool_result, non-blank
  text in user/assistant records (string content counts as one text item);
  system/retry/usage-only/isApiErrorMessage/blank/malformed score 0.
- Remaining (orchestrator-owned): AC4 `agent_runtime.stale_working_ms` config
  field (schema + AgentRunner `Keyword.put_new` like `turn_timeout_ms`, default
  900_000, config test), agent-runtime.md spec section (real work vs UI churn
  vs read failure; field), service spec config list, `make all`, PR, handoff.

## Session 5 notes (2026-09-16 17:54Z–)

- Slice 2 (`tur1006-green-2`, delegated): orchestrator-level idle clock.
  `orchestrator.ex` `reconcile_stalled_running_issues` measures
  `codex.stall_timeout_ms` (300 s) against `CurrentRun.activity_ms`, which only
  advances on `forward_update` of non-accounting runtime messages. Delegation
  emits `:turn_heartbeat` on every supervision observation while the
  orchestrator is `working` (supervision `on_heartbeat`), and while a delegated
  worker is `working` only when its `activity_revision`
  (`{revision, state_change_seq}`) changes — which the live evidence shows does
  NOT advance during real worker work. Fix shape, bounded to
  `implementer_delegation.ex` + `herdr_transport.ex`: the working-worker
  settlement fingerprint includes the worker's real-work progress cursor
  (`transport.progress_cursor/3` for the claude_code worker; `:not_applicable`
  keeps the Codex `activity_revision` fingerprint), so a silent orchestrator
  with an actively working claude_code worker keeps emitting `:turn_heartbeat`
  and the run activity clock advances; Codex path behavior-identical.
  RED at the public `run_turn` seam: orchestrator idle immediately, worker
  `working` with advancing transcript real-work items and constant
  `activity_revision` → heartbeats must arrive; no-work worker → none.
- 18:03Z checkpoint: AC4 config field landed at da58f8b (RED 3/3 failures →
  GREEN 9 tests/0 failures incl. settlement-config suite); spec section at
  dccff0b. Worker `tur1006-green-2` still `working` (editing
  implementer_delegation.ex + new implementer_worker_settlement_activity_test.exs,
  uncommitted, in the shared working tree — do NOT discard). Turn ended under
  the 10-min operating rule. Resume: `git pull`, poll `herdr agent get
  implementer_worker`, integrate the `kind=result` for `tur1006-green-2`,
  then `make all`, PR, handoff to Agent Review.

## Session 6 notes (2026-09-16 18:14Z–18:26Z)

- `make -C elixir all` on head 2ba3901 (detached, `/tmp/tur1006-make-all-2.log`):
  setup/build/fmt-check/lint passed; `mix test --cover` 890 tests / 4 failures /
  2 skipped (371.7 s), coverage 84.43 %, so `coverage` exited 2 and dialyzer
  did not run. None of the four failures touches branch-changed files:
  1. `skill_execution_contract_test.exs:173` and 3. `implementer_delegation_test.exs:221`
     expect Codex read paths without this run's `CODEX_HOME/skills`
     (`/home/admin/scaling-octo-engine/.runtime/codex/implementer/skills`,
     appended by untouched `codex/skill_permissions.ex`); both pass with
     `env -u CODEX_HOME` (2 tests / 0 failures).
  2. `role_bootstrap_environment_test.exs:237` expects an empty
     `SYMPHONY_ISSUE_REPOSITORY`; this run exports `EmberAGI/symphony`; passes with
     `env -u SYMPHONY_ISSUE_REPOSITORY` (1 test / 0 failures).
  4. `orchestrator_current_run_activity_test.exs:507` on_exit `File.touch` race in
     a tmp dir already removed; passes alone (1 test / 0 failures); branch does not
     touch orchestrator files.
- Turn ended under the deployed 15-min detector; PR opened and routed to Agent Review.

## Session 7 notes (2026-09-16 18:29Z–18:38Z, Agent Fixes)

- Reviewer blocked only on incomplete exact-head `make all` evidence
  (4 host failures, dialyzer not run). Operator steering 18:31Z/18:35Z: the
  clean-environment gate is PR CI; do not rerun the full suite or dialyzer on
  the shared 4 GB host (a host `mix dialyzer` started 18:32Z was SIGTERMed by
  the operator at 18:33Z as a capacity decision, not a dialyzer result).
- Exact-head full gate (clean GitHub runner): workflow `make-all` run
  `35134364398`, head `0dc7f526ca4b4230ee9fb4daddbc9c372ff460cc`,
  `completed` / `success`. Steps: `make -C elixir all` (setup, build,
  fmt-check, lint, `mix test --cover`: 890 tests / 0 failures / 2 skipped,
  coverage 84.51 %, `mix dialyzer --format short`: done, passed successfully)
  and `mix specs.check`, all `success`.
  https://github.com/EmberAGI/symphony/actions/runs/35134364398
- Host controlled-env rerun of the four session-6 failing files, one file at
  a time with `env -u CODEX_HOME -u SYMPHONY_ISSUE_REPOSITORY mix test <file>`
  at head 0dc7f52: `skill_execution_contract_test.exs` exit 0 (6 tests /
  0 failures); `implementer_delegation_test.exs` exit 0 (14 / 0);
  `role_bootstrap_environment_test.exs` exit 0 (5 / 0);
  `orchestrator_current_run_activity_test.exs` exit 0 (9 / 0). Combined run
  of the same four files: exit 0, 34 tests / 0 failures.
- Classification: the four session-6 host failures are environment-injected
  (role-run `CODEX_HOME` skills root appended to Codex read paths; exported
  `SYMPHONY_ISSUE_REPOSITORY`; tmp-dir teardown race under host memory
  pressure), not branch defects; none touches branch-changed files.
- AC1–AC4 implementation, tests, and spec evidence unchanged from session 6.
