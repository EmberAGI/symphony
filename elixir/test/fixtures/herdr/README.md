# Recorded herdr protocol fixtures

`0.8.2/` is the current protocol-20 corpus. It contains responses recorded
from the exact Linux x86_64 v0.8.2 release asset, including readiness, all five
agent states, prompt/wait/deadline outcomes, blocked prompt/start errors,
provider identity, and run-owned server/workspace operations. Every protocol
fixture is one real command outcome with raw provenance: argv, stdout, stderr,
exit status, timestamp, `herdr --version`, and the binary SHA-256.

`0.7.5/` remains only as the historical parser-regression corpus from
EMB-1244. The current replay Adapter never selects that directory.

`0.8.2/release-authority.json` pins the exact stable generation promoted by
TUR-844: annotated tag `v0.8.2`, release commit
`9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c`, protocol 20, official skill and
license hashes, and every supported release asset digest. Changed v0.8.2
protocol evidence is recorded with the official Linux x86_64 asset
`976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4`.

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

Current recording method (2026-09-04, Linux x86_64, exact Herdr v0.8.2 release
asset, isolated `--session`/private `XDG_CONFIG_HOME`; the operator's default
server was never touched):

- A controlled foreground Codex/Claude terminal fixture supplies detectable
  ready, working, idle, done, and blocked screens and reports exact provider
  session identity through Herdr's native pane-report Interface. It contains
  no Symphony validation or transport policy.
- The same foreground fixture captures terminal input bytes to prove Herdr's
  bracketed-paste plus delayed-Enter ownership without synthesizing a CLI
  response.
- A non-reactive foreground process records `agent_prompt_stalled`, the
  sub-5000 ms `timeout`, and wait-deadline behavior.
- `unknown` is witnessed by the real `pane split` envelope for an agentless
  shell pane; missing-agent and pane-busy errors are direct real CLI outcomes.

The obsolete separate `agent send-keys ... enter` recording is removed for
v0.8.2. `prompt-delivery-bytes.json` records the bytes read by a controlled
foreground provider after two real `agent prompt` calls: each is one
bracketed-paste payload followed by one encoded LF Enter. Real v0.8.2
`agent_blocked` and `agent_not_ready` recordings prove the new fail-closed
boundaries without an extra input path.

The exact `provider-identity-{codex,claude}-{start,prompt,wait}.json`
recordings deliberately do not parameterize provider kind, provider-session
source, or provider-session value. Generic replay fixtures may parameterize
provider kind for deterministic variants, but they are not provider-identity
proof.

Committed fixtures are CI inputs. Re-recording is a CD-tier operation: run the
same commands against the pinned real binary and re-wrap with full provenance.
The replay-backed test double (`test/support/herdr_replay_fixture.exs`) keeps
only non-recordable process and terminal timing behavior: the file-based
server run loop, status-stall timing, provider process execution for
`agent start` and the 5000 ms prompt-effect stall schedule. Every
response emitted by those paths is a committed recording. Provider execution
and the stall/timeout boundary are differentially validated against the real binary by
`herdr_differential_test.exs` (runtime opt-in via
`SYMPHONY_RUN_HERDR_DIFFERENTIAL=1`); the run loop and stall knob are
test-only process scaffolding that emit no protocol responses. The double's
direct provider execution is interim: it must inherit EMB-1245's canonical
wrapper/projection launch behavior when that lands.

The replay server-stop scaffolding acknowledges only after its running marker
is removed. This follows the availability fence in `src/session.rs:260-296`
at upstream release commit `9eb521456ac0d19d3ab3d9d7cea3cca10baa8a4c`:
`stop_socket_with_timeout` waits until the API and client sockets are no longer
reachable before returning success. The marker represents server availability,
not a new protocol recording or an upstream guarantee about OS process reaping.

Real-runtime test helpers register the public run-owned cleanup capability
immediately after session creation. ExUnit callbacks run outside the creator
task, so they use `AgentRuntime.cleanup_owned_session/1` with the captured
`owned_session_ref/1`, while normal in-test shutdown still uses `stop_session/1`.
Cleanup precedes removal of fixture files and remains safe after explicit stop.
A bounded child ExUnit proof intentionally fails before stop and independently
checks fixture-process exit, artifact removal, and unrelated-process survival.
