# Recorded herdr protocol fixtures

`0.7.5/` contains protocol responses recorded from the real herdr 0.7.5 binary
(EMB-1244 Stage 1). Every fixture is a pure recording of one real command
outcome with raw provenance: argv, stdout, stderr, exit status, timestamp,
`herdr --version` output, and the SHA-256 of the recorded binary.

Mutation policy (enforced by `herdr_fixture_fidelity_test.exs`):

- The only permitted mutations are the declared redaction (local username →
  `operator` in provider terminal text) and placeholder parameterization of
  run-varying identity/path fields: `{{AGENT_NAME}}`, `{{AGENT_KIND}}`,
  `{{SOCKET_PATH}}`, `{{WORKSPACE_CWD}}`, `{{PANE_ID}}`.
- No status, error code, version, or any other semantic field may be edited or
  substituted. Fabricated or derived protocol JSON must not be committed.
- Statuses or errors that the real binary would not produce on demand
  (`unknown` as a live-agent envelope, out-of-enum strings, protocol/version
  mismatches) are exercised through the public transport interface using
  test-local replay mutations of a recorded envelope
  (`HerdrReplayFixture.write_replay_mutation!/4`); those variants exist only
  in a test run's replay directory and are never committed.

Recording method (2026-07-23, macOS, herdr 0.7.5, real Claude Code TUI agents
in isolated `--session`/private `XDG_CONFIG_HOME` sessions; the operator's
default server was never touched):

- `idle`/`working`/`done` envelopes from live `agent start`/`prompt`/`wait`
  against a real `claude --model haiku` agent.
- `blocked` from a real plan-mode approval dialog.
- `agent_prompt_stalled` and the sub-5000 ms `timeout` counterpart from a
  claude onboarding selection screen that ignores typed characters.
- `unknown` witnessed by the recorded `pane split` envelope (agentless shell
  pane); no live-agent envelope with `unknown` could be elicited.
- Error envelopes from real missing-agent targets.

The `agent-send-keys-enter` fixture was recorded separately on 2026-07-26 on
Linux from the installed Herdr 0.7.5 binary
`3dc83288073e4c2d3c679a30e7be97bcca9141c6fd17dbbb9219142e95c59253`.
The command targeted a real Codex agent in the isolated `emb1312sendkeys`
session under a private `XDG_CONFIG_HOME`; that session was stopped and its
default Herdr server was never touched. Its success envelope is preserved
verbatim and its exact command argv remains in the fixture.

Committed fixtures are CI inputs. Re-recording is a CD-tier operation: run the
same commands against the pinned real binary and re-wrap with full provenance.
The replay-backed test double (`test/support/herdr_replay_fixture.exs`) keeps
only non-recordable process and terminal timing behavior: the file-based
server run loop, status-stall timing, provider process execution for
`agent start`, the 5000 ms prompt-effect stall schedule, and the delayed
revision transition caused only by a separate agent-scoped Enter. Every
response emitted by those paths is a committed recording. Provider execution
and the stall/timeout boundary are differentially validated against the real binary by
`herdr_differential_test.exs` (runtime opt-in via
`SYMPHONY_RUN_HERDR_DIFFERENTIAL=1`); the run loop and stall knob are
test-only process scaffolding that emit no protocol responses. The double's
direct provider execution is interim: it must inherit EMB-1245's canonical
wrapper/projection launch behavior when that lands.
