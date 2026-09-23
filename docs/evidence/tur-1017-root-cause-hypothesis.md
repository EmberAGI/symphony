# TUR-1017 Root-Cause Hypothesis

Date: 2026-09-20

The reported Agent Fixes failures are expected to be evidence-contract drift at
the test/runtime seam, not a defect in the typed failure families. A live worker
must remain `worker_assignments_unobservable` when the turn-scoped recorder
attestation is absent, while a direct-work fixture must explicitly model the
valid no-worker path. Startup admission tests must isolate tracker events so a
memory-tracker candidate cannot be mistaken for unrelated startup output.

Unmodified reproduction in this checkout:

- `mix test test/symphony_elixir/work_admission_test.exs` passes: 12 tests,
  0 failures.
- `mix test test/symphony_elixir/implementer_delegation_test.exs` fails at
  `owns one isolated Herdr session and projects Codex agent profiles exactly`
  on the existing exact-argv fixture assertion; it does not reproduce the
  reported recorder-attestation failure.
- The branch contains neither the referenced `ae783232` commit nor a reflog
  entry for it, so the prior Agent Fixes state is not present in this clone.

The repair must first identify the exact public transport seam and preserve
`worker_assignments_unobservable`, `post_turn_gate_rejected`, and
`empty_turn_completed` semantics. No completion inference from pane text,
gate relaxation, provider routing change, or production activation is
authorized.
