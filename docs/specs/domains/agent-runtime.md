# Agent Runtime

## Intended behavior

Symphony supports a provider-neutral coding-agent runtime layer so a deployment
can run Codex, Claude Code, and Pi workers behind the same orchestrator,
workspace, prompt, tool, artifact, and observability contracts.

Codex remains the backward-compatible reference runtime. Claude Code is the
first non-Codex runtime provider being delivered (EMB-166 as re-scoped on
2026-06-10): it must be able to run unattended Symphony role workflows, load or
translate required role skills, execute required tools, normalize events and
failures, and collect artifacts/proof. Pi (and other future harness CLIs such
as Hermes) remain planned providers behind the same seam, but their adapters
and the mixed-runtime validation profile are deferred to future issues.

The runtime layer belongs in Symphony. Octo-specific workflow policy, Linear
state semantics, repository routing, role ownership, and handoff expectations
remain owned by Octo wrapper configuration unless a later ADR changes that
boundary.

## Domain concepts

**Runtime provider**: A concrete coding-agent backend such as `codex`,
`claude_code`, or `pi`.

**Runtime adapter**: The Symphony-owned integration boundary that translates
between provider-native protocol behavior and Symphony's provider-neutral
session, turn, event, tool, artifact, and lifecycle contract.

**Provider-native protocol**: The provider's real transport and message model.
Examples include Codex app-server, a first-party Claude Code adapter/shim, and
Pi JSONL RPC.

**Runtime config**: Workflow configuration that selects a provider and declares
command, arguments, environment, permission policy, tool bundle, artifact
policy, and provider capabilities.

**Runtime-native tool bridge**: The controlled mechanism that exposes required
tools to a provider session without leaking secrets or relying only on prompt
instructions.

**Skill materialization**: The process of making Symphony role workflow and
skill material available to the provider in the form it can actually use.

**Skill execution contract**: A provider-neutral, integration-supplied record
of the exact package root, locked runtime inputs, and external tool
executables registered for one configured skill. It grants no authority over
the enclosing orchestration checkout and is distinct from skill discovery or
body preloading.

**Selected product workspace**: The per-issue repository checkout that owns
writable product source and repository evidence for a role run. Registered
skill execution resources remain read-only orchestration inputs and never
become product-repository evidence.

**Normalized runtime event**: A provider-independent event emitted to the
orchestrator, status surfaces, and handoff logic. Examples include session
started, text delta, tool started, tool finished, tool failed, turn completed,
turn failed, input required, usage updated, and artifact available.

**Octo multi-runtime profile**: The conformance profile required for Octo to
claim that Codex, Claude Code, and Pi are usable as role runtimes, including at
least one real mixed-runtime execution. Deferred: this profile is not required
by the re-scoped EMB-166, which delivers the Claude Code slice only.

**Agent profile**: A canonical TOML-frontmatter Markdown file that combines an
agent's identity, kind, role, capabilities, complete per-provider five-tier
model/effort matrices, and reusable system workflow. Symphony loads the
collection named by `SYMPHONY_AGENT_PROFILES` and maps the durable
`Implementation Effort` label to one tier in the selected profile.

**Irrecoverable runtime failure**: A runtime failure whose next successful
step requires human, credential, configuration, host, tool, permission,
protocol, or implementation repair rather than another ordinary role retry.

**Runtime failure family**: A provider-neutral classification used by the
runner, orchestrator, tracker, and status surfaces to decide whether a failure
is retryable, recoverable, blocked, or escalated. Provider adapters translate
provider-native payloads into this shared family vocabulary before retry
policy is applied.

**Human-required runtime input**: A provider-native request whose next valid
step requires a human decision that no approved deterministic unattended policy
can supply. It is distinct from a generic `turn_input_required` event, which may
still be resolved by continuation or bounded no-progress recovery.

**Role-run ownership**: The single-host, local runtime authority that atomically
fences one Symphony role run for an issue/workspace/role scope. Its
`Runtime.ProcessOwnership` record contains stable issue, role, holder, run,
workspace, host, state, cleanup, quarantine, and timestamp fields plus bounded
process/session cleanup metadata and the optional bounded failure observation
`{fingerprint, count, reset_marker}`. The exact record path is passed to provider
processes as `SYMPHONY_ROLE_OWNERSHIP_PATH`; consumers read that path and do not
reconstruct it. This contract implements the state-driven direction recorded
by Octo ADR 0022 without adding a database, message bus, transition outbox, task
dossier, or expanded run log.

**Work admission**: The Orchestrator-owned `open` or `closed` state that
serializes deployment drain requests with normal and retry dispatch. It is
distinct from role-run ownership: admission decides whether any later role run
may start, while ownership fences one already admitted run.

**Execution generation**: The bounded, non-secret identifier for the complete
tracked wrapper/Symphony/Herdr inputs from which one role process is executing.
It is opaque to Symphony and is compared for exact equality when work
admission opens.

## Rules and invariants

- Codex remains the default and reference runtime.
- Existing Codex app-server workflow configuration must remain backward
  compatible.
- Runtime providers must use provider-native protocols; Pi must use native JSONL
  RPC rather than being forced through a Codex-shaped protocol.
- Claude Code support is owned as a first-party Symphony adapter informed by
  reviewed Claude app-server work, not by rebasing the fork onto another
  Symphony fork.
- Shared orchestration code should use provider-neutral names such as
  `runtime`, `worker_pid`, `session_id`, `provider_session_id`,
  `last_runtime_event`, and `runtime_totals`.
- Provider-specific process or session fields may exist for compatibility, but
  they must not become the shared orchestration model.
- Runtime adapters must not be enabled for unattended Octo roles until required
  skills load, required tools execute, tool failures normalize, and secrets are
  not exposed through prompts or logs.
- Runtime adapters must expose tools through controlled runtime-native
  mechanisms. Credentials and tracker tokens must not be pasted into prompts.
- Every role turn receives the per-turn bootstrap inputs its workflow declares
  as required, from one projection at the runtime session Interface taken
  before the session path for a role is selected. No role runs through a
  session path that bypasses that projection.
- `SYMPHONY_ISSUE_REPOSITORY` and `SYMPHONY_EXPECTED_BRANCH` are required
  bootstrap inputs of a role turn. A missing value is never silently dropped
  into an absent variable: the role projection fails at its own boundary,
  naming the variable and the issue it was projected for, and classifies as an
  irrecoverable missing-required-runtime-configuration failure. Roles fail
  closed rather than infer repository or branch metadata, so the runtime, not
  agent judgement, is the enforcement point for a boundary input it cannot
  supply.
- That requirement is scoped to the role-turn projection. Workspace-lifecycle
  hooks share the same environment shape but are not role turns, and workspace
  population through them stays implementation-defined (symphony-service
  spec 9.2-9.3), so they continue to project whatever the issue context
  carries.
- An irrecoverable runtime failure keeps its family through post-turn routing.
  A failing `after_run` hook records its own failure but must not replace an
  already-irrecoverable reason, which would re-open the run as retryable under
  a different family.
- A configured skill with executable resources is not available merely
  because its metadata or body is discoverable. The integrating workflow must
  supply its registered skill execution contract, and `AgentRuntime` must
  validate and carry that same provider-neutral contract to every configured
  top-level role and to Implementer orchestrators and workers.
- Skill execution contracts contain only canonical absolute package roots,
  locked runtime inputs, and required executable paths. Missing, unreadable,
  non-executable, malformed, duplicated with conflicting access, or denied
  paths fail closed before provider work starts.
- A skill execution contract must not grant the complete orchestration
  checkout, runtime state, provider authentication, production configuration,
  or another skill's unregistered resources. Provider adapters may add only
  the native discovery, read, execute, environment, or launch projection
  required by the validated entries; they must not widen the contract to a
  convenient parent root.
- Skill execution resources are read-only inputs. The selected product
  workspace remains the only writable repository root and the only source of
  Git `HEAD`, branch diff, changed-file, test, spec, and acceptance evidence.
- Projection and activation remain separate. Carrying a skill execution
  contract makes a configured skill genuinely invocable but must not preload
  its body or trigger it outside the workflow's contextual activation rules.
- Provider-authentication failures that occur after runtime startup/readiness
  checks, including Claude Code HTTP 401/403 results, normalized
  `{:auth_failed, ...}` adapter errors, and provider-auth-shaped `before_run`
  workspace hook failures from `Workspace.run_before_run_hook`, must remain
  provider-infrastructure failures across the adapter/workspace-hook, runner,
  and orchestrator retry interface. They must not be converted into generic
  agent failures, must not schedule or consume the ordinary issue retry loop,
  and must emit only redacted operator-visible blocked/status evidence on
  existing process-ownership and status surfaces. Non-auth
  workspace hook failures remain typed workspace-hook failures and are subject
  to the same fail-closed recoverable allowlist. This
  invariant is recorded for EMB-1123 and EMB-1128 and supports the wrapper
  readiness hardening in EMB-1121 while preserving ADR 0002: Claude Code
  continues to use operator-managed subscription OAuth, and no
  `ANTHROPIC_API_KEY` migration is introduced.
- Runtime retry policy must be driven by a provider-neutral runtime failure
  family, not by ad hoc process-exit text at each retry call site. Retryable
  classifications are this exact structural allowlist:
  `turn_timeout`, `network_error`, `service_unavailable`, `rate_limited`,
  `capacity_unavailable`, and `operator_interrupted` as atoms or two-tuples;
  two-tuples tagged `empty_turn_completed`, `turn_input_required`,
  `approval_required`, `implementer_hard_budget_exhausted`,
  `implementer_agent_stalled`, or `implementer_agent_unobservable`;
  `workspace_hook_timeout/3`; `workspace_hook_failed/4` with status `75`; and
  `post_turn_routing_failed/2` or `remote_command_failed/3` only when the nested
  reason is itself allowlisted. `implementer_status_reads_failed/2` is
  recoverable only when its `last_error` is itself allowlisted. The provider
  rate-limit, capacity, service, network, and turn-timeout shapes represent
  explicit transient contracts; the no-progress, approval/input, operator, and
  preserved-checkpoint supervision shapes retain their existing bounded
  recovery contracts. Substring matches never make arbitrary errors or
  timeouts retryable. Known
  deterministic irrecoverable families are:
  `provider_authentication_or_revocation`,
  `missing_required_runtime_configuration`, `missing_required_tool_or_cli`,
  `permission_denied`, `invalid_workspace_or_runtime_protocol`,
  `unsupported_app_server_contract`, `malformed_provider_event_schema`,
  `human_input_required`, `unclassified_runtime_failure`, and
  `repeated_identical_no_progress_failure`. Any failure outside the recoverable
  allowlist is `unclassified_runtime_failure` and irrecoverable by default.
- Deterministic single-shot irrecoverable failures must escalate immediately
  instead of scheduling or consuming an ordinary role retry. The classification
  must be preserved across adapter, workspace hook, runner, orchestrator,
  tracker, log, status API, and dashboard surfaces.
- Failed-run retry suppression must use a bounded fingerprint that
  includes at least issue id, workspace path, role, runtime provider, failure
  family, normalized provider/runtime subtype when known, and redacted stable
  error summary. Before the first failure-driven redispatch, the queued
  observation is compared with the independently re-read process-ownership
  observation and the current durable checkpoint. If the fingerprints and
  checkpoints are identical and no intervening reset evidence exists,
  redispatch is refused and surfaced as a typed blocker; a second failed
  execution is not required. Elapsed wall-clock time, process liveness, turns,
  and token use are activity,
  not checkpoint progress. This applies to every configured top-level role and
  to transient as well as deterministic retryable families.
  The reset marker has exactly two produced dimensions: a material
  issue/branch/workspace input fingerprint and the verified execution
  generation. A replacement role-run identifier, elapsed time, or prose-only
  claim of repair is not checkpoint progress.
- The same scoped `Runtime.ProcessOwnership` claim durably carries the bounded
  failure observation while a failed run is released or retried. A role-service
  restart reloads that observation before classifying the next equivalent
  failure. A later normal exit from any run that inherited that observation at
  the same reset marker must not clear it or enter the ordinary completion
  branch, regardless of reconstructed retry-attempt metadata; the prior typed
  failure remains durable and the run is surfaced blocked. A verified
  successful retry after the reset marker changes is a distinct run: it may
  enter normal completion and clear the prior observation at that one
  settlement seam.
  Continuation checks after a clean run carry no failure observation and never
  consult stale failure evidence. This is claim metadata, not a new storage or
  runtime authority.
- Poll dispatch computes the current reset marker and passes it into ownership
  acquisition before any replacement worker starts. A stale `active`,
  `retrying`, or `quarantined` record carrying a valid failure observation
  remains non-reacquirable while that marker is unchanged, even when its holder
  process is dead or the role service restarted. Acquisition may archive and
  replace it only when the incoming produced marker differs, preserving the
  observation for settlement. A stale in-flight record with no failure
  observation retains ordinary crash-recovery takeover. A present but malformed
  observation fails closed and is not treated as absent.
- A blocked ownership record carrying a valid failure observation follows the
  same marker rule. When an active issue presents changed material input,
  candidate selection treats the dispatch as a retry; the changed incoming
  marker may archive and replace the blocked record while preserving its
  observation. For rollout compatibility only, a genuinely legacy blocked
  record with no `failure_observation` field may be archived and replaced when
  acquisition receives a nonempty produced marker. Symphony does not fabricate
  or backfill a marker for that record, and a present malformed observation
  remains fail-closed. Symphony's own `Human Escalation` control label is
  excluded from the input fingerprint, so escalation cannot create its own
  reset evidence. The public ownership rule accepts a changed verified
  execution generation and rejects an unchanged generation; no role-service
  restart is required to make changed evidence safe.
- Fail-closed classification deliberately increases the Human Escalation blast
  radius for previously generic operational exits, including unknown
  workspace/setup, maximum-turn, cleanup/settlement, supervisor, exception, and
  future adapter failures. Those failures remain blocked until they gain an
  exact recoverable contract or their active issue/workspace input or verified
  execution generation materially changes; infrastructure-sounding tuple names
  and timeout prose are not exceptions.
- Worker death, worker launch failure, missing or mismatched worker result,
  timeout, `agent.max_turns` exhaustion, and post-turn routing failure are typed
  failed runs. They must never use the normal task-completion branch. A
  successful runtime turn must contain a non-empty provider result or response.
- A `herdr_agent_status_timeout` is a typed
  `invalid_workspace_or_runtime_protocol` failed run with subtype
  `herdr_agent_status_timeout`; it is never inferred to be transient merely
  because its name contains `timeout`.
- Every irrecoverable classification must clear or avoid ordinary retry
  scheduling, update the verified same-scope process ownership to a blocked
  state with redacted recovery evidence, apply or preserve the tracker issue's
  exact `Human Escalation` label when the selected tracker supports it, and move
  the issue to the `Human Escalation` state when the selected workflow supports
  it. It must not require or create a Linear comment.
- Tracker mutation failures during irrecoverable escalation must not re-enter
  ordinary role retry. They must leave local runtime status and logs visibly
  blocked/escalated with enough redacted evidence for an operator to repair the
  tracker mutation or runtime environment manually.
- Irrecoverable failure summaries, process-ownership records, logs, and status payloads
  operator-visible notes must never include bearer tokens, refresh tokens, API
  keys, raw environment values, raw provider payloads, full Linear bodies, or
  unbounded process output.
- Provider/runtime classifier fixtures must preserve the relevant shape of
  observed real provider and runtime errors when durable evidence exists, while
  replacing secret-bearing or user-sensitive fields with deterministic redacted
  values. Synthetic-only fixtures are acceptable for generic runtime classes or
  unavailable provider variants, but they must still exercise the adapter's real
  parsing boundary rather than bypassing it with already-normalized families.
- Before finalizing classifier fixtures, implementation must run a provider
  evidence discovery pass over available Octo-owned evidence: role run logs,
  runtime status logs, process-ownership records, tracker state/labels, and
  relevant incidents, local generated runtime state, and existing redacted
  incident notes. Existing authenticated local Codex and Claude CLI contexts may
  also be used for bounded, non-destructive probes that capture exit status and
  provider/runtime stderr/stdout/event shape. Discovery must not commit raw logs,
  secret-bearing payloads, provider credentials, full issue bodies, or
  unbounded process output; the PR or handoff records only source categories,
  redaction decisions, and fixture coverage.
- Provider server requests for input must be recognized inside the provider
  Adapter's active protocol loop; they must not be treated as opaque
  notifications or left pending until a transport timeout.
- An unattended Adapter may answer or reject a provider input request only when
  an approved deterministic non-interactive policy supplies that outcome. If
  no such policy applies, the Adapter must promptly send the provider-native
  decline or cancellation response needed to release the pending protocol
  request and return `human_input_required` as a single-shot irrecoverable
  failure. The shared lifecycle then clears ordinary retry, records blocked
  process ownership, and uses the existing Human Escalation state/label path.
- Generic `turn_input_required` and approval-required failures retain bounded
  no-progress classification. They must not be reclassified as
  `human_input_required` unless the Adapter has evidence that the unattended
  runtime cannot proceed without a human decision.
- Human-required input evidence is bounded and redacted. It may identify the
  provider, request source, mode, and a short purpose, but must not preserve raw
  forms, requested schemas, submitted values, credentials, secret fields, full
  provider payloads, or unbounded message text.
- Runtime adapters must collect or expose artifacts and proof in a normalized
  way so review, QA, landing, and operator status surfaces do not need to know
  which provider produced the evidence.
- Symphony must atomically acquire `Runtime.ProcessOwnership` before starting a
  top-level role run. Exactly one concurrent acquisition may win for the same
  issue/workspace/role scope. A nonmatching holder/run cannot update or release
  the record, malformed records fail closed, and stale takeover must claim and
  archive the exact observed record while holding the scope lock before
  replacement. After successful takeover, the runtime removes older stale
  archives for that ownership scope on a best-effort basis; any undeletable
  residue is inert runtime evidence and never re-enters dispatch authority.
  Records for different roles or workspaces may coexist.
- Before the first role hook or provider prompt, the runner must verify the
  exact acquired holder/run identity through a read-only ownership check and
  project that record's non-secret ownership environment unchanged. The
  referenced ownership file must already be readable. For the Implementer
  Codex orchestrator, the provider sandbox grants read access to that exact
  file only; it must not grant the parent registry directory or broaden the
  workspace permission.
- This V1 ownership implementation supports only the local host. Any selected
  nonblank remote worker host fails closed before dispatch.
- Legitimate continuation turns inside one role run use the existing runtime
  session and `agent.max_turns` loop; they are not a new top-level dispatch and
  must not be blocked by the duplicate-dispatch gate.
- Worker termination, stall restart, abnormal exit, operator restart, and
  orchestrator restart paths must either clean the owned app-server process
  tree or preserve/quarantine process ownership metadata so replacement
  top-level dispatch refuses until recovery policy allows it.
- If stall restart records live owned app-server evidence, the queued retry
  must surface quarantined process ownership in status/API payloads; it must
  not appear as an ordinary retry while cleanup remains unresolved.
- When a running issue leaves active dispatch because it becomes terminal,
  non-active, unroutable, or reassigned, the runtime must verify the holder/run
  and record process completion or quarantine before releasing ownership. A
  run-owned Implementer Herdr turn that has just moved its issue into a
  downstream non-active state is the one bounded exception to immediate
  termination: its narrow ownership reference marks it for terminal handoff
  settlement, and the Orchestrator retains that already-running task so the
  turn can emit worker-correlation and post-turn-gate evidence before stopping
  its own session. That retention is bounded by INACTIVITY, not by elapsed time
  since the handoff: the Orchestrator anchors a no-activity grace on the turn's
  last observed runtime activity, sets the anchor on the first eligible
  non-active reconciliation, and resets it to the current monotonic time on
  every worker update that also records the last provider timestamp. Because
  delegation supervision emits a `turn_heartbeat` worker update on each
  observation cycle while the provider reads `working`, a turn that is still
  making progress refreshes its own anchor and is never force-cleaned for
  taking longer than some fixed wall clock; any such fixed bound would race a
  legitimately progressing turn. A genuinely live-but-stale provider turn stays
  owned by the delegation supervision stale-working threshold and hard turn
  budget, and PID liveness is never treated as progress. The no-activity grace
  must exceed one normal observation cycle plus the terminal evidence the turn
  still owes after supervision returns, and remains finite so it is still an
  escape hatch when terminal evidence collection itself hangs. Forced
  termination therefore occurs once the turn has been silent for the whole
  grace, at the next successful reconciliation. Returning to an active state
  clears all settlement tracking before any later handoff, and runtime activity
  refreshes an existing anchor without enrolling a non-settling turn. Terminal
  states, reassignment, missing issues, and runtimes without that explicit
  marker retain immediate termination. Expiry force-terminates through the
  existing typed, non-vacuous cleanup path.
- Normal worker completion must not mark process ownership as cleaned until the
  scoped app-server process tree is no longer live. If the app-server PID,
  observed process tree, process group, or inherited ownership-marker process
  is still live when the worker exits normally, the runtime must record
  quarantine metadata and make active-state continuation fail closed
  instead of allowing a replacement top-level dispatch.
- Local app-server launch adapters must pass a scoped, non-secret role-run
  ownership marker to provider processes so descendants that appear after the
  last PID snapshot and detach from the original process group can still be
  detected without matching broad command or package names. The marker must be
  scoped by issue id, issue identifier when available, role, holder/run
  identity, and workspace path.
- Process cleanup must be scoped by issue id, workspace, role, run/session
  identity, worker host, and app-server PID/process group when available. The
  runtime must not kill by broad package name or process name.
- V1 duplicate prevention is intentionally narrow: it covers top-level Symphony
  role runs and their Codex/Claude app-server process tree. It is not a general
  whole-repository command lock or broad command de-duplication system.
- The Claude Code adapter must support per-session model selection, `effort`
  configuration, and a verified no-thinking invocation so Symphony can map
  `Implementation Effort` levels onto Claude models. Unsupported combinations
  (for example Sonnet 4.6 with effort `xhigh`) must fail closed at config
  validation, not at runtime.
- `SYMPHONY_AGENT_PROFILES` must point to a valid agent-profile directory.
  Missing files, parse errors, unknown keys, filename/name mismatch, duplicate
  names, missing providers or tiers, non-moderate defaults, invalid capability
  combinations, unsupported efforts, and empty reusable instructions fail
  closed during startup validation. The runtime has no parallel built-in
  production matrix.
- The Orchestrator Module owns work admission. Its `close` and `open` calls,
  normal poll dispatch, and retry dispatch execute through the same GenServer
  mailbox. A successful close acknowledgement therefore occurs after any
  earlier selected dispatch has become visible in `running`, or before any
  later dispatch can start.
- Because these controls share one mailbox, the Orchestrator must not perform
  unbounded or shell-forking work inline on that mailbox. Work-admission
  `close`/`open` and the state snapshot must stay serviceable during role turns
  and terminal settlement: each returns its bounded result (a typed
  generation/marker outcome for admission, a possibly-stale but well-formed
  snapshot for state) rather than blocking behind terminal settlement or
  per-issue process scans. A call timeout — surfaced as `orchestrator_unavailable`
  for admission or `snapshot_timeout` for state — is a contract violation, not
  an acceptable degradation (EMB-1260). Bounded snapshot staleness is
  acceptable; a timeout is not.
- Closed admission blocks normal and retry dispatch but does not stop
  reconciliation or already-running work. Only a retry whose matching timer
  actually fires while closed becomes held; unexpired retry timers keep their
  original `due_at_ms` deadline. On a later open in the same process, held
  retries are re-armed for `max(due_at_ms - now, 0)` while still-pending timers
  are left untouched.
- Opening admission requires the target generation to equal the process
  execution generation and the current admission target. A missing or invalid
  execution generation cannot open admission.
- Before scheduling its first poll, the Orchestrator loads the shared durable
  marker at
  `SYMPHONY_ORCHESTRATION_ROOT/.runtime/symphony/work-admission.json`, unless
  the wrapper supplies the same path through the
  `SYMPHONY_WORK_ADMISSION_PATH` bootstrap value. When marker integration is
  configured, a missing, unreadable, malformed, or unsupported marker, or an
  `open` marker for a different execution generation, starts closed before
  the first poll. A missing marker defaults its target to the valid process
  execution generation so the verified bootstrap can explicitly open it.
  Standalone Symphony without marker integration preserves open behavior.
- On Orchestrator initialization, runner tasks surviving an earlier
  Orchestrator process continue under the shared TaskSupervisor; admission
  state does not terminate already-running work. `drained` is true only when
  both the Orchestrator running map and the shared TaskSupervisor child set are
  empty; TaskSupervisor inspection errors or exits report `drained: false`.
  The restarted Orchestrator does not reconstruct the earlier process's
  in-memory scheduler entries; surviving children remain drain observations,
  not adopted `running` entries.
- The marker is a small atomically replaced JSON record containing only schema
  version, `open`/`closed` status, and target generation. It is neither a
  transition outbox nor a run log, dossier, lock service, or new shared storage
  service. The Orchestrator exclusively writes it; the wrapper never creates,
  edits, or deletes it.

## Interfaces/contracts

Runtime config should support this provider-neutral shape:

```yaml
agent_runtime:
  provider: codex
  command: ["codex", "app-server"]
  env: {}
  permission_policy: {}
  tool_bundle: []
  artifact_policy: {}
  capabilities:
    streaming: true
    cancellation: true
    resume: true
    tool_execution: true
    usage_reporting: true
```

The integrating workflow may additionally pass zero or more resolved skill
execution contracts at session start:

```yaml
skill_execution_contracts:
  - skill: linear
    package_root: /absolute/orchestration/.agents/skills/linear
    runtime_inputs:
      - /absolute/orchestration/pyproject.toml
      - /absolute/orchestration/uv.lock
    tool_executables:
      - /absolute/tooling/uv
```

The field names above are the logical Interface, not a requirement that
workflow files use YAML. Octo derives these entries from its role-skill
manifest and passes the resolved records through Symphony's runtime session
boundary; Symphony does not own or reconstruct Octo's skill inventory.

`AgentRuntime` owns validation, normalization, and propagation of this
contract. Concrete provider adapters own only native projection:

- Codex receives the exact read/execute roots through its session or launcher
  permission surface while the product workspace remains writable.
- Claude Code receives exact skill discovery directories and command/runtime
  environment through supported native launch arguments. Its host permission
  posture remains governed by ADR 0002; this contract must not add a broad
  orchestration directory merely because the host user could otherwise read
  it.
- Implementer delegation passes the same validated records to both the
  orchestrator and every worker launcher. Non-delegating roles receive the
  same records through their ordinary adapter session.

Provider-native launch evidence must retain enough secret-free detail to prove
which registered resource identities were projected without logging raw
environment values or sensitive host paths.

Provider adapters must implement these logical operations:

- `start_session(workspace, issue, prompt, config, tools)`: start or resume a
  provider session in the per-issue workspace and make declared tools available.
- `run_turn(session, input, continuation)`: run the initial prompt turn or a
  continuation turn.
- `send_followup(session, input)`: send provider-native follow-up input when
  supported.
- `cancel(session, reason)`: request cancellation of the active turn or session.
- `stop_session(session)`: stop the provider process and release runtime
  resources.
- `normalize_event(provider_event)`: map provider-native events into Symphony
  runtime events.
- `collect_artifacts(session)`: collect provider transcripts, proof files,
  exports, logs, or other declared artifacts.

The normalized event vocabulary must cover at least:

- `session_started`
- `startup_failed`
- `text_delta`
- `tool_started`
- `tool_finished`
- `tool_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`
- `usage_updated`
- `artifact_available`
- `notification`
- `malformed`

The minimum Octo tool bundle must include controlled equivalents for:

- Linear GraphQL access.
- Workpad read/update operations.
- Artifact/proof capture.
- Repository status.
- PR status.

Top-level dispatch must perform these steps before spawning a worker:

- read candidate issue state without querying tracker comments;
- reject a selected nonblank remote worker host;
- atomically acquire local process ownership for the exact
  issue/workspace/role/holder/run scope;
- refuse dispatch while a conflicting or malformed same-scope record exists,
  including when the recorded parent app-server PID has exited but an observed
  descendant PID, owned process group, or process with the inherited exact
  ownership path remains live; and
- verify the same holder/run for every retry, recovery, cleanup, quarantine,
  status update, and release.

Runtime status and API/dashboard projections should expose enough read-only
metadata to diagnose duplicate-prevention decisions: session age versus
accumulated issue-pass age, ownership state, retry or replacement reason, run/session
identity, worker host, workspace path, app-server PID when available, and
process cleanup/quarantine status.

### Work admission

The wrapper supplies the current execution generation through the
`SYMPHONY_EXECUTION_GENERATION` bootstrap value. Symphony accepts only a
non-empty generation of at most 128 ASCII letters, digits, `.`, `_`, `:`, or
`-`; invalid process values report as `unknown`, and invalid control requests
are rejected.

The loopback HTTP Adapter exposes:

- `POST /api/v1/work-admission/close` with
  `{"generation":"<target>"}`. Success returns
  `{"status":"closed","target_generation":"<target>","drained":<boolean>}`
  only after the Orchestrator has serialized the close against dispatch and
  atomically persisted the marker.
- `POST /api/v1/work-admission/open` with the same request shape. Success
  requires request generation, current admission target, and the valid running
  process execution generation to match exactly, atomically persists `open`
  before changing the in-memory state, and returns the same bounded shape with
  `status: "open"`. A mismatch returns HTTP 409 and remains closed.
- `GET /api/v1/state` includes
  `work_admission:
  {"status":"open"|"closed","target_generation":"<generation>","drained":<boolean>}`
  and
  `execution_generation: "<bounded-generation>"`. It does not expose the
  marker path, parse failures, request payloads, or other runtime values.

Both mutation routes reject non-loopback callers even if endpoint host
configuration is later widened.

Marker schema:

```json
{
  "version": 1,
  "status": "closed",
  "target_generation": "wrapper-generation"
}
```

The local Orchestrator Interface also exposes equivalent
`close_work_admission(server, generation)` and
`open_work_admission(server, generation)` calls. The HTTP controller is an
Adapter over those calls and does not own admission state or dispatch policy.

Provider-specific requirements:

- Codex uses the existing Codex app-server path and dynamic tools where
  supported. A `mcpServer/elicitation/request` is a typed app-server request.
  When `codex.approval_policy.reject.mcp_elicitations` explicitly supplies the
  unattended outcome, the Adapter responds with `action: decline` and
  continues. Otherwise it responds with `action: decline`, emits bounded
  input-required evidence, and returns `human_input_required`. A malformed
  request returns `malformed_provider_event_schema` rather than waiting.
- Claude Code uses a first-party adapter or shim with separated transport,
  server/session lifecycle, cancellation, permission handling, tool bridging,
  and local Claude CLI auth/startup validation. Claude-native human-required
  input follows the same shared failure semantics without pretending to
  implement the Codex request or response shape.
- Pi uses native JSONL RPC, maps provider commands and streamed events,
  explicitly controls auto-retry and auto-compaction, uses an explicit worker
  extension bundle, and converts unattended UI/input requests into normalized
  input-required events. A Pi request proven to require unavailable human input
  follows the same shared failure semantics through its own Adapter.

### Agent Profile Contract

`SYMPHONY_AGENT_PROFILES` names a directory of canonical `*.agent.md` files.
Each document begins and ends its strict TOML frontmatter with `+++`; the
remaining non-empty Markdown body is the reusable agent system workflow. The
frontmatter contains exactly schema version, name, kind, role, capabilities,
and provider matrices. Filename and `name` must match and names are unique.

Only `codex` and `claude_code` are supported. Every provider table declares
`default_tier = "moderate"` and complete `extreme`, `high`, `moderate`, `low`,
and `minimal` cells. Every cell contains explicit `model` and
`reasoning_effort` strings. There are no model-less cells, scalar role rows,
inheritance rules, aliases, or built-in production fallbacks.

Capabilities contain exactly `can_delegate`, `max_delegation_depth`,
`owns_issue_lifecycle`, `owns_final_validation`, and `owns_handoff`. A
non-delegating profile has depth zero; a delegating profile has positive bounded
depth. Implementer uses distinct `implementer-orchestrator` and
`implementer-worker` profiles. Other runtime roles resolve their named profile,
and unknown roles resolve `default`.

`ImplementationEffort` owns only label parsing and role-to-profile selection.
The catalog owns identity, capabilities, reusable instructions, and the model
matrix. Invalid or ambiguous Codex labels fail closed. Claude keeps its
documented invalid-label fallback, now to the universally moderate default.

For Implementer, Symphony resolves one exact orchestrator/worker contract and
starts a new isolated named Herdr 0.7.5/protocol 17 session containing one
deterministically prestarted `implementer_worker` and the orchestrator, with
their independently resolved participant provider bindings. The compatibility
worker launcher remains available for an orchestrator profile that explicitly
needs it, but the production lifecycle does not depend on model-elective worker
startup. Runtime-owned launchers outside
the selected repository apply exact model, effort, and reusable profile instructions. Codex
receives the Markdown body as `developer_instructions`; Claude receives it with
`--append-system-prompt`. The role `WORKFLOW.md` continues to own issue
lifecycle. Each orchestrator-authored worker assignment contains only its
bounded deliverable, relevant context, mutation scope, constraints, expected
validation, and required result; it does not restate stable worker behavior.
Short Herdr session identities remain readable; identities that would exceed
the default cross-platform Unix-socket budget compact deterministically to an
issue-derived prefix plus a digest while remaining unique per production run.
The orchestrator receives the same non-secret issue, repository, and expected-
branch environment derived for workspace hooks, projected through the runtime
session Interface rather than reconstructed by the transport Adapter.
The Codex permission profile keeps the workspace root writable and explicitly
reopens that root's `.git` metadata for issue-branch and commit operations; the
isolated Herdr runtime root remains read-only except for its allowed socket.

After readiness validation, the Adapter creates one workspace rooted at the
selected product checkout and resolves its returned root pane rather than
predicting topology identifiers. It starts each participant through strict
`agent start <name> --kind <kind> --pane <id> --timeout <ms> -- <native args>`;
Herdr validates the live name, provider kind, target pane, and interactive
readiness before returning. Herdr resolves the kind at the pane shell with
exec-style `PATH` lookup: pane shells reset to a login `PATH` (session `--env`
does not survive into panes), only `pane run` exports persist there, and Herdr
may prepend one kind-specific unattended-mode flag to the typed agent
arguments (`--dangerously-skip-permissions` for `claude`, `--yolo` for
`codex`; observed on macOS and absent on Linux with Herdr 0.7.5). Before every
`agent start` — orchestrator
and worker alike — the launching side therefore prepares the target pane with a
`pane run` export placing the session `orchestrator-bin` first on the pane
`PATH`, then performs an acknowledged preflight in the same pane: a
non-interactive `sh -c 'command -v <kind>'` (immune to interactive shell
function shadowing, mirroring Herdr's exec resolution) must resolve to exactly
the session provider wrapper, byte for byte, or the launch fails closed before
`agent start` is issued. Before the orchestrator starts, a second preflight
resolves bare-name `herdr` through a login Bash with the run-owned environment
and requires the exact session `orchestrator-bin/herdr`; one read-only
`agent list` probe through that same path attests the recorder. `pane run` is
permitted solely for this launch preparation and preflight; prompts and raw
input never travel through it.

The native arguments are materialized in an executable launch-projection file
under the isolated session runtime root, named by a per-launch token (a stable
digest plus a fresh launch nonce), so concurrent launches can never share or
cross-satisfy launch state. The pane-shell command receives only the fixed
`--symphony-launch-projection` sentinel and the short, quote-trivial projection
path; reusable profile instructions and other potentially large or quote-rich
provider arguments never cross the pane shell as typed argv. The runtime-owned
provider wrapper fails closed for any invocation other than the exact sentinel
plus one projection path (after optionally stripping exactly the known
Herdr-injected unattended flag, whose exact observed value is recorded when
present as a token-local diagnostic marker in the launch acknowledgement
directory — evidence only, not authentication): there is no default-provider
fall-through. It validates the
projection with canonical resolution — symlinks rejected, canonicalized path
contained under the session `launch-projections` directory, regular file,
caller-owned, mode 0500 — writes a per-launch `wrapper.ack` containing the
launch token, and only then execs the projection. The projection writes its own
`projection.ack` with the same token before exec-ing the provider, so Codex
receives `developer_instructions` and Claude receives `--append-system-prompt`
unchanged from their provider contracts. Each provider wrapper also exports a
role-specific, run-owned `BASH_ENV` file that re-prepends the orchestrator or
restricted-worker Herdr projection. Non-interactive Bash outside POSIX mode
sources that file after its login profiles, so a Bash profile that replaces
`PATH` cannot route inter-agent commands to a user-installed Herdr outside the
recorder. This mechanism does not claim PATH repair for POSIX-mode Bash,
interactive Bash, or non-Bash shells; the turn-local worker-state observation
below makes a delegation through any such residual bypass fail typed instead
of being reported as no delegation.
The files live only beneath the isolated runtime root; provider `HOME` and
provider-auth environment values remain unchanged. The transport mirrors the
projection validation before launching and requires both acknowledgements,
with exact token content, within a five-second startup-acknowledgement window
inside the shared budget. Launch failures are distinct typed stages, never
collapsed:
pane preparation, wrapper resolution, wrapper acknowledgement, projection
acknowledgement (including malformed or cross-launch content), and provider
start. The acknowledgements are intra-runtime liveness evidence that the
launch chain actually executed — not an authentication mechanism. The
generated worker launcher applies the same pane preparation, preflight,
sentinel launch, and token-bound acknowledgement contract, minting a fresh
launch token (and token-named projection copy) on every invocation so
concurrent worker launches cannot share or clear each other's launch state;
its shell exit codes are stage-specific diagnostics surfaced to the
orchestrator's pane, while typed launch outcomes remain the transport's
Elixir results.
Orchestrator and worker startup share a 120-second cold-start budget. Before
Claude profile instructions are written to the projection, CRLF and CR
normalize to LF, LF becomes the Unicode line separator U+2028, and each tab
becomes four spaces. This preserves multiline semantics without terminal
control characters. Any remaining Unicode control-category (`Cc`) character
fails with a typed invalid-agent-argument error. There is no secondary
readiness poll.

The orchestrator receives the worker launcher path through
`OCTO_HERDR_WORKER_LAUNCHER`. Missing or incompatible Herdr, unsafe socket
paths, rejected launchers, and adapter-side model/effort substitution fail
closed. The launcher accepts exactly the worker's strict live name and a pane
ID returned by Herdr, then invokes run-owned `agent start` with the
Adapter-selected provider kind, fixed native profile arguments, and bounded
startup timeout; it never directly execs the provider or accepts caller-supplied
model, effort, provider, or command arguments. The matching provider projection
places the restricted worker Herdr proxy and worker environment in the launched
process while the orchestrator retains its full run-owned Herdr projection.
For local Claude Code delegation, `AgentRuntime` projects only the shared
Claude local-provider-auth environment allowlist into the isolated session
environment. The same allowlist authority is used by the ordinary Claude
app-server Adapter. The values reach both the Implementer orchestrator and
worker through process environment only; they must not appear in Herdr command
arguments, transcripts, logs, artifacts, or typed errors. Codex delegation
does not receive Claude provider-auth environment.
Every mutating Herdr command is scoped to the run-owned named session and
private configuration root; cleanup verifies that the operator's default server
snapshot is unchanged.

Herdr owns terminal input, bracketed-paste handling, provider keyboard protocol,
prompt acknowledgement, and lifecycle waiting behind its native live-agent
Interface. Herdr 0.7.5's agent status vocabulary is exactly `idle`, `working`,
`blocked`, `done`, and `unknown`, and every Symphony status read types all five
as first-class outcomes. `working` starts a turn; `idle` and `done` complete
one. `blocked` (a recognized approval/question UI) settles a prompt or wait but
is never success: it is the typed blocked outcome, surfaced within one bounded
observation interval. `unknown` never proves completion or turn start; it is
surfaced immediately as the typed unknown outcome, and the Stage 2
supervision machine below owns transient-versus-persistent unknown
resolution through its bounded indeterminate-read retries. A status
string outside the five-state enum is a typed protocol/version error, never
coerced to `unknown`; command failures remain a distinct error class.

Symphony submits initial turns, assignments, worker results, and consultation responses
through the same verified `agent prompt` operation. Prompt submissions settle
on the upstream default settle set (`idle`, `done`, `blocked`) plus `working`
so a started turn and a turn that finishes before observation are both
represented without revision heuristics; the settle set is never re-narrowed
below the upstream default and never includes `unknown`. Bounded lifecycle
observation with `agent wait` requests exactly the upstream default settle set
(`idle`, `done`, `blocked`), stated explicitly on the wire and rejected typed
if a caller asks for anything narrower or wider. The submission wait must
exceed Herdr 0.7.5's 5000 ms prompt-effect window so an unchanged
`state_change_seq` is classified as the typed `agent_prompt_stalled` result
rather than an ordinary timeout; the transport deliberately raises any smaller
caller budget to a 5001 ms floor. That effective budget is derived once for
`begin_turn/5`; prompt submission, compatibility recovery, and lifecycle
observation never restart it. On the first typed stall, the transport sends
exactly one logical Enter through Herdr's agent-scoped `agent send-keys`
Interface, then gives Herdr up to 60 seconds, capped by the remaining caller
deadline, to expose the authoritative state/revision transition. `working`
proves turn start; `idle` or `done` proves a fast completion only with a newer
Herdr revision; `blocked`, `unknown`, closed agents, command failures,
protocol mismatches, and deadline exhaustion remain distinct typed outcomes.
Same-revision settled status never proves delivery. Provider transcript output
is diagnostic evidence only and never substitutes for this observation.

The generated orchestrator/worker prompt projections apply the same causal
Herdr 0.7.5 compatibility recovery to assignments and results: one native
5001 ms prompt-effect wait, one internal agent-scoped Enter, one 60-second
server-bounded `working|blocked` observation, and at most one final `agent get`
for a fast-settled newer revision. They never submit a blank or replayed
prompt. Caller-supplied semantic `agent send-keys` and all pane-key input stay
denied; the Enter is available only inside Adapter-owned recovery. Remove this
compatibility path when the pinned stable Herdr release contains upstream
commit `bb29eedb7209a0d5e91052458ce76bc7e4259d18`.

The orchestrator's machine-readable assignment message is
`OCTO_MSG/1 kind=assignment assignment=<token>` followed by bounded
assignment-specific fields. A worker result is
`OCTO_MSG/1 kind=result assignment=<token> status=completed|failed`.
The run-owned transport projection records only those messages as ephemeral
per-session evidence beneath the existing isolated runtime root. The records
are not runtime authority, are never Linear comments, and are removed with the
runtime root. Every invocation of either role's Herdr projection first records
a bounded attestation. The launch probe proves startup reachability only; it is
never accepted as evidence that a later turn did not delegate. A run owns
exactly two live Herdr agents: the orchestrator it started and the one
canonical prestarted worker its recording covers. The generated orchestrator
projection therefore denies direct worker lifecycle creation (`agent start`
for any agent other than the canonical worker) and any `agent prompt` to a
noncanonical worker agent, and records each refusal as turn-local evidence, so
an orchestrator that ignores a denial cannot convert it into positive
no-delegation evidence. Immediately before prompting the orchestrator, the
transport snapshots the worker's Herdr-owned revision, the exact set of
existing worker-event files, and the live agent inventory read through the
transport-owned real Herdr binary; the inventory is read again at turn
completion. The expected inventory at both ends is exactly the run-owned
orchestrator and the canonical prestarted worker. Every listed agent must
carry a usable stable identity — a non-empty name and pane — or the turn fails
typed as `agent_identity_incomplete`; an unexpected or missing name at either
end fails typed as `worker_agent_inventory_unexpected`, and an agent replaced
under a canonical name between the two reads fails typed as
`worker_agent_inventory_changed`. Identity is that name and pane only: the
provider session is not a property of an agent's existence, since Herdr does
not report one until the agent has been prompted, so a first turn that gives
an agent its provider session is not a changed inventory. Because that read
never passes through a generated projection, an agent that bypasses its shim
and drives the real binary directly is still observed. Turn completion
considers only files absent from that opening set. No turn-local assignment
plus an unchanged worker revision is positive, falsifiable no-delegation
evidence; no turn-local assignment plus a changed worker revision fails typed
as `worker_event_recorder_unattested`. Exact file identities, rather than
shared-prefix counts or sequence high-water marks, define the turn cursor.
At turn completion, the Transport Interface reports bounded
assignment entries containing `assignment_id`, lifecycle `status`, and a
result with the observed `assignment_id`; the Implementer runtime accepts only
an exact correlation. Launch failure, worker death, an idle/done worker without
a result, a still-working worker after the orchestrator settles, a mismatched
token, and `status=failed` remain distinct typed failed-run outcomes.
After validation, every successful Implementer turn emits one durable
correlation-evidence log event with the issue id, issue identifier, provider
session id, and isolated Herdr session name. A correlated delegation includes
the bounded assignment evidence and `outcome=correlated`; a turn whose
materialized recording proves no delegation occurred emits positive
`outcome=no_delegation` evidence instead of ambiguous silence. An unobservable
recording or a delegated result that cannot be correlated remains a typed
failure and cannot emit either successful outcome.
An Implementer commonly performs its own `In Progress -> Agent Review`
transition before its provider turn has returned. State reconciliation must
not destroy the run-owned session on the first observation of that downstream
state: doing so would bypass the turn-completion cursor read while allowing
generic process cleanup to report success. The Implementer's ownership
reference therefore opts that in-flight turn into the activity-anchored handoff
settlement grace above, whose anchor is refreshed by the same supervision
`turn_heartbeat` updates described below. Natural completion still owns
correlation validation, post-turn gates, and session stop; the Orchestrator
owns only the no-activity expiry and forced cleanup.

After submission, turn lifecycle observation is a bounded, idempotent
supervision state machine (EMB-1244 Stage 2), not a single budget-length
server wait. The transport reads the typed agent status (`agent get`) on a
bounded cadence: a 30-second observation interval, a 5-second per-read
timeout, and 0 ms jitter (deterministic cadence; no randomization surface). A
`blocked` status must therefore surface within one observation interval plus
one read timeout. All five Herdr 0.7.5 statuses (`idle`, `working`,
`blocked`, `done`, `unknown`) are first-class typed observations; an
out-of-enum status is a typed protocol error, never coerced to `unknown` and
never retried.

Progress is distinct from status: `working` can persist without progress, so
the supervisor consumes an observable progress cursor (recent agent output)
alongside each working read. Wall-clock time is never the sole stuck signal.
The supervision transitions are: an observed `working` with progress
continues; `blocked` is preserved and surfaced as a typed blocked outcome —
the runtime never auto-answers a permission or question prompt absent an
authorized policy, and bypass-permissions launches do not exempt blocked
handling; `unknown` statuses and status-read failures (including per-read
command timeouts) get bounded retries (default four consecutive
indeterminate reads) before a typed escalation carrying independent pane
evidence, except that a status read failing with the typed
incompatible-runtime protocol error halts immediately with a checkpoint —
a deterministic protocol failure is never retried as indeterminate; stale working (no cursor movement past the stale threshold,
default fifteen minutes) gets bounded recovery through the server-owned
terminal wait (at most two attempts) before a typed stalled escalation; the
hard turn budget triggers checkpoint-and-preserve, then shutdown. A read
that observes `idle`/`done` with an unchanged agent revision inside the
prompt-transition settle window (default 5000 ms, matching Herdr's
prompt-effect window) is transitional, not completion; this is read-only
revision observation, not 0.7.4 revision-acknowledgement choreography.

Work preservation is scoped to the technically observable. Before any halt
that can precede a destructive shutdown — including a prompt submission that
itself settles blocked — the supervisor records a
best-effort checkpoint in the turn's typed outcome: pane tail, Herdr session
name and runtime root, workspace identity, agent name/pane, agent resume
reference when observed, last typed status, progress cursor, recovery
history, and shutdown reason. A checkpoint failure is itself typed and
blocks destructive shutdown absent an explicit emergency policy: the runner
must not stop the delegated session on a typed preservation failure and must
leave the owned-session reference recoverable. A successful checkpoint
permits bounded shutdown. The runner and monitored-task boundary both consume
the same idempotent owned-session cleanup capability so success, failure,
cancellation, timeout, and abrupt task exit converge on bounded teardown.
The Implementer runner must publish that cleanup capability to the registered
top-level orchestrator and receive its acknowledgement before sending the first
provider prompt. A missing acknowledgement is a typed failed run and the
runner cleans the session instead of proceeding. Registered orchestrator
shutdown stops only its exact tracked task/session entries, consumes the
acknowledged capability, verifies `live_after=0`, and settles the matching
process-ownership record. Terminal settlement self-produces its process
evidence (EMB-1259): it captures the owned PID set — the exact record's
recorded process tree plus a live ownership-environment scan — BEFORE
teardown destroys the records that identify it, verifies liveness against
that captured snapshot AFTER teardown with one batched process-table read,
and writes the explicit evidence (owned PID set, live-after count,
cleanup-verified marker, capture timestamp) into the terminal
process-ownership record on every terminal path: success, failure,
cancellation, and timeout. Settlement never re-derives its evidence by
re-reading mutable global state after teardown, and a failed post-teardown
re-read can never manufacture a cleanup failure for a physically clean run.
Settlement evidence that truly cannot be captured — a process-table read
that fails, returns unparseable output, or crashes the capture — or that
cannot be written settles as a typed cleanup failure recorded unverified,
never as a verified-clean settlement and never left silently active. A
capture whose machinery worked and observed no owned process still settles
clean: empty evidence is only trustworthy when it was actually observed.
Owned-process liveness — for settlement evidence and for the dispatch-admission
gates alike — is matched by recorded PID, and a process-table read that failed
is never evidence that an owned process died: an unusable read reports the
recorded PIDs live, so a degraded host blocks dispatch rather than starting a
second run over a live one. Deferred: PID-reuse identity is not resolved. An
unrelated process that inherits a recorded PID after the owned process exits
reads as a false survivor, because distinguishing it requires recording each
owned process's start time in the ownership record — a record-schema change
left to a follow-up issue. Until then a false survivor settles conservatively,
quarantining the record for an operator and withholding dispatch, never
producing a verified-clean settlement. The same terminal
cleanup boundary runs after normal or abnormal task exit and after forced
stall, timeout, state, routing, or shutdown cancellation for every role. If an
issue-owned hook or provider descendant survives task/session stop, cleanup
rechecks each PID's complete ownership environment before signaling it,
permits one bounded TERM grace period, and sends KILL only to exact-marker
survivors. A different issue, role, run, or unmarked process is never eligible,
and ownership release waits until the exact-marker live set is empty. Cleanup
failure replaces normal completion with a typed runtime failure and is logged
before retry or terminal classification; the typed failure is reserved for
genuine inability — owned processes that actually survive the bounded
TERM/KILL sequence, or settlement evidence that truly cannot be captured or
written — never for evidence unavailability the teardown ordering itself
caused.
Terminal settlement must not run on the Orchestrator's serial request path
(EMB-1260). The expensive teardown, liveness, and ownership-record writes
execute off that path so the Orchestrator keeps serving state snapshots and
work-admission control while a settlement is in flight; the settling issue
stays claimed so it cannot be re-dispatched, and classification, retry
scheduling, and notification finalize when the settlement result returns.
Every terminal settlement completes or fails TYPED within a bounded time. The
bound is a production configuration value —
`agent_runtime.terminal_settlement_timeout_ms`, a positive integer defaulting
to `60000` — generous by default; on expiry the runtime settles the
record typed through one cheap write that uses the held ownership identity and
performs no process scans — the record LEAVES the active state (quarantined
with a typed settlement-timeout reason, its captured pre-teardown evidence
preserved as unverified) rather than remaining silently active because
teardown hung. A timed-out settlement is a typed failure whose scheduled
retry carries the typed failure observation, so an identical repeat is seen by
the existing no-progress fingerprint machinery instead of looping as fresh
work. The expiry write must never fabricate a timeout failure over a record
that already reached a terminal typed write. Before it writes, the runtime
reads the current state of the record it owns; a record that already left
active — cleaned, released, or quarantined — is settled and is handed to the
ordinary retry lease with a late-completion reason instead of being overwritten.
`quarantined` counts as settled unconditionally: the question is whether a
terminal typed write already landed, not whether the runtime is physically
clean, and a quarantine carrying evidence marked unavailable is a true
statement about what the settlement could observe, which a fabricated timeout
claim would replace with a possibly false one. The synchronous GenServer-shutdown cancellation path may settle inline
because the process is already terminating.
Teardown and liveness evaluation is batched and bounded. Recorded process-tree
liveness is decided against a single process-table snapshot per evaluation, not
a per-PID probe fan-out over the recorded tree; the bounded TERM/KILL await
re-checks only the still-live candidate set rather than re-scanning every host
process's ownership environment each iteration; and an active-refresh record
rebuild prunes recorded PIDs already dead in that same snapshot so stale trees
stop accumulating. Pruning never alters the pre-teardown settlement evidence.
Pruning is an optimisation over a SUCCESSFUL observation and must never run on
an unusable one: the rebuild reads the process table through the typed reader,
and a read that fails retains every recorded PID unpruned alongside the
always-retained app-server anchor. A failed process-table read is never
evidence of an empty table, so it can never be allowed to empty the recorded
PID set and discard the evidence a later settlement depends on.
The KILL pass of terminal teardown is narrowed to the TERM candidate list, and
this is an ACCEPTED GAP, not an oversight. The TERM pass discovers candidates
from one checked table read and env-matches them; the KILL pass then re-checks
the ownership environment of only those pids. An owned process that becomes
discoverable only AFTER the TERM snapshot — one forked late by a surviving
descendant, or one whose ownership environment was not yet readable when the
snapshot was taken — is therefore never reached by this settlement's KILL. The
narrowing is deliberate: it bounds teardown to a single host-wide scan instead
of re-scanning every process's environment on each pass, which is what keeps
settlement bounded. The residue is not dropped — it is left to the ownership
record's own liveness evidence, which reports the process as still live, and to
later reconciliation of orphaned claims, which sweeps records whose owned
processes outlived their settlement. A settlement that still observes live
owned processes fails typed rather than reporting a verified-clean teardown, so
the gap can never be laundered into a forged clean settlement.
Ownership env-matching is host-dependent and this widens the same gap on
non-Linux hosts. The exact-marker check reads a process's environment from
`/proc/<pid>/environ`; where that path does not exist the read fails, the
matcher is false for every PID, and the entire env-scoped sweep is inert. On
such a host terminal teardown signals nothing and the KILL narrowing is
trivially total, so ownership containment there rests entirely on the record's
liveness evidence and reconciliation. Behavioral claims about the ownership
sweep are therefore only meaningful on a host that exposes `/proc`; a test that
asserts owned-PID set CONTENT off Linux asserts a tautology and proves nothing.
If the acquired ownership record is missing, malformed, or does not match the
run capability before hook dispatch, the attempt returns the typed
`process_ownership_publication_failed` result directly. Neither `before_run`,
`after_run`, nor the provider prompt may execute because no owned role session
started.
Successful cleanup removes the private runtime root, including ephemeral worker
message evidence, and emits a bounded existing-log/status summary keyed by
issue, run-owned Herdr session, exact owned PID evidence when available, and
`live_after=0`. Cleanup failure replaces normal completion with a typed failed
run and cannot authorize redispatch. Supervised typed outcomes feed the shared runtime
failure families: a blocked agent — whether surfaced by supervision or as the
bare typed blocked outcome of a prompt or wait — classifies as
`human_input_required`, a
work-preservation checkpoint failure (direct or embedded in a supervised
outcome) and an out-of-enum protocol status classify as
`invalid_workspace_or_runtime_protocol` — all irrecoverable, never ordinary
retry — while hard-budget, stale, unknown, and closed outcomes with preserved
checkpoints keep ordinary bounded retry semantics. A status-read wrapper
inherits retry eligibility only from its exact `last_error`; therefore a
wrapped `herdr_agent_status_timeout` is the same irrecoverable protocol failure
as the bare timeout. Failure summaries never include pane transcript content.
This supervision layer is
observation only: it
emits typed outcomes and never grows lifecycle arbitration, teardown, or
quarantine verdict semantics, which EMB-1217 owns over what this layer
emits.

Completed terminal output is consumed from native `agent read` text; Symphony
does not expect a JSON response envelope from that command.

Native prompt-stall compatibility recovery never makes the failure ordinarily
retryable. A failed Enter is a typed transport failure; unchanged lifecycle
evidence expires as a bounded status-timeout result; and a prompt or wait whose
named live agent has closed remains a typed closed-agent failure. Protocol
mismatch remains a machine-readable incompatible-runtime failure. Symphony
does not retain the 0.7.4 `pane run` prompt-submission,
manual confirmation, revision-acknowledgement choreography, top-level wait,
provider-specific multiline handling, translation, dual-version, or
other legacy compatibility machinery. The temporary Herdr 0.7.5 one-Enter
path above is the sole exception until the pinned stable release contains the
named upstream fix. `pane run` survives only as the launch PATH preparation
and preflight primitive described above, and read-only observation of the
reported agent `revision` (for example the prompt-transition settle guard) is
not acknowledgement choreography and remains permitted.

Inter-agent messaging uses the same `agent prompt` command for Codex and Claude.
The runtime-owned orchestrator and restricted worker projections add the same
verified-submission wait and one-Enter prompt-stall compatibility recovery
before forwarding to the native Herdr Interface. The restricted worker
projection permits only agent
list/get/read, prompt, and wait operations; it denies caller-supplied agent
start, raw pane input, logical key injection, topology mutation, server
control, and descendant delegation.

Managed isolated sessions write private Herdr update configuration with both
version and remote manifest background checks disabled. This prevents a
30-minute update check from changing or perturbing the pinned 0.7.5/protocol-17
runtime contract during a role session.

The Codex launcher uses unattended workspace-write/no-approval mode, disables
`multi_agent`, disables alternate-screen rendering, and supplies the selected
workspace through the whole `projects={...}` trust map. The Claude launcher
uses unattended bypass-permissions mode and disables the provider-native
`Agent` tool. A restricted worker Herdr proxy is
defense in depth rather than a complete process sandbox; one-generation
delegation remains a profile invariant backed by evals.

Herdr protocol test evidence is recorded, not authored (EMB-1244 Stage 1).
Every protocol read in the deterministic suite replays a response recorded from
the real herdr 0.7.5 binary, committed with raw provenance: argv, stdout,
stderr, exit status, timestamp, binary version and SHA-256, and the declared
redaction/parameterization method. Placeholder substitution is permitted only
for run-varying identity/path fields, never for statuses, error codes, or other
semantic fields; a fidelity check fails the suite on any out-of-enum status
claim, unrecorded error code, missing provenance, or non-recorded fixture. The
only executable test double behavior is launch/timing physics that cannot be a
recording (server run loop, provider execution for `agent start`, the 5000 ms
prompt-effect window), and that behavior is differentially validated against
the real binary by an opt-in CD-tier fake-vs-real harness that runs identical
operations against both and fails on divergence. Recording is a CD-tier
operation; committed fixtures are CI inputs.

Symphony observes Herdr identity/status and emits its existing normalized
top-level runtime events. Runtime contract tests prove that resolved profiles
become exact orchestrator and worker launcher arguments, reusable system
instructions reach each provider, the isolated session is cleaned up without
replacing or stopping the default server, and incompatible or substituted
profiles fail closed. The same contract tests prove strict named/kind startup,
atomic prompt, bounded server-owned wait, typed prompt-stall and closed-agent
failures, least-privilege worker control, and the absence of raw pane input or
manual confirmation across both provider projections. Bounded live
evaluation—not narration—provides session/start/message/result/integration/
cleanup evidence for Codex and Claude.

Octo mixed-runtime validation (a real workflow assigning roles to different
runtimes in one run, for example implementer on Pi, reviewer on Claude Code,
QA on Codex, and landing on Codex) is deferred until a second non-Codex
adapter exists. The re-scoped EMB-166 requires only that a role configured for
Claude Code runs end to end while other roles stay on Codex.

### Claude Code shim invocation (implemented)

The first-party Claude Code adapter drives the local `claude` CLI in
non-interactive print mode and normalizes its streaming JSON output into the
Symphony runtime events above. The runtime is selected with the
provider-neutral `agent_runtime.provider` value (`codex` by default,
`claude_code` to use the shim); a `claude_code` config block declares the
command, model, effort, no-thinking flag, and permission mode.

Verified Claude Code 2.x invocation (confirmed against `claude --help` and a
real run, not guessed):

- `claude --print --output-format stream-json --verbose` runs fully
  non-interactively and emits one JSON object per line: a
  `{"type":"system","subtype":"init"}` session-start line, `assistant` /
  `user` turn lines (text, tool use, and tool results), `rate_limit_event`
  usage notifications, and a terminal `{"type":"result","subtype":...}` line.
- `--permission-mode bypassPermissions` runs with no interactive permission
  approval and no extra sandbox layer (ADR 0002).
- `--model <alias|id>` selects the model and
  `--effort <low|medium|high|xhigh|max>` selects the reasoning effort.
- The verified no-thinking invocation is the environment variable
  `MAX_THINKING_TOKENS=0` (the Claude Code CLI equivalent of the API-level
  `thinking: {type: "disabled"}` invocation). Fable 5 cannot disable thinking,
  so requesting no-thinking with a Fable config model fails closed at config
  validation; a catalog row that resolves a Fable model while the config
  declares no-thinking is only known at launch and fails closed there as a
  visible adapter launch error rather than silently dropping either the
  selected model or the declared no-thinking invocation.

Verified model x effort support matrix (transcribed from the `claude` CLI
v2.1.172 effort-gating allow-lists). `low`, `medium`, and `high` are supported
on every model; `xhigh` and `max` are gated to specific models:

- `xhigh`: Fable 5, Opus 4.8, Opus 4.7, Sonnet 5.
- `max`: Fable 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 5, Sonnet 4.6.

Config validation resolves bare aliases (`fable`/`opus`/`sonnet`/`haiku`) to the
current latest model and strips provider routing prefixes (for example
`us.anthropic.`) before checking the matrix. A restricted-effort request whose
model is unset, an alias/id resolving to an unsupported family, or otherwise not
verifiable against this matrix fails closed at config validation rather than at
runtime. For example `model: sonnet, effort: xhigh` is rejected at config
validation.

Runtime adapters launch the exact model and effort selected by the resolved
profile. Fable unavailability is a provider failure, not permission for an
adapter-side Opus substitution; changing the selected model requires a durable
profile update.

The adapter maps Claude terminal results onto normalized events:
`result` with `is_error: true` and an auth HTTP status (401/403) fails closed
as an operator-visible `auth_failed` `turn_failed`; `subtype:
"error_max_turns"` maps to `turn_input_required`; other `is_error: true`
results map to `turn_failed`; a successful result maps to `turn_completed` with
normalized token usage (`input_tokens`/`output_tokens`/`total_tokens`). A
failed tool result inside the stream flags the completed turn as having a tool
failure for review/QA. The adapter never prints or forwards credential-bearing
fields (OAuth tokens, API keys) in events, logs, or transcripts.

Claude Code normalized usage and progress events MUST feed the shared role
status surfaces used by `/api/v1/state`, status logs, and the dashboard. When a
Claude turn emits normalized `usage` or result usage maps, the orchestrator
MUST fold `input_tokens`, `output_tokens`, and `total_tokens` into the same
runtime totals that Codex turns use. Streamed Claude assistant text, tool
result, rate-limit, and result events SHOULD update the human-readable
`last_message` beyond the initial session-start marker whenever provider
events contain usable progress data.

Implementation MUST carry deterministic Claude Code shim contract/smoke checks
that exercise, with a fake `claude` binary replaying recorded stream-json, the
verified invocation flags and no-thinking env, the normalized event vocabulary,
fail-closed auth classification, max-turns input-required classification, tool
failure surfacing, secret redaction, workspace-cwd guarding, and runtime
selection defaulting to Codex, and status aggregation of Claude usage/progress
into the role status snapshot. These checks belong with the Symphony Elixir
test suite and run under `make all`. The full skills/tools release gate
(ADR 0001) remains a separate slice and is not satisfied by these shim checks
alone.

### Skills/tools release gate contract (EMB-1029)

The non-negotiable gate (ADR 0001) for Claude Code unattended Octo role
enablement is proved by three deterministic test modules in the Symphony
Elixir test suite, all driven by a fake `claude` binary replaying recorded
stream-json without a live Claude subscription:

- `elixir/test/symphony_elixir/claude_code_app_server_test.exs` — shim-level
  contract checks: verified invocation flags (`--print`, `--output-format
  stream-json`, `--verbose`, `--permission-mode bypassPermissions`),
  exact-profile launch on the default path (the resolved catalog model and
  effort appear verbatim in the invocation with no substitution metadata),
  normalized event vocabulary (`session_started`, `text_delta`,
  `notification`, `tool_finished`, `tool_failed`, `turn_completed`,
  `turn_failed`, `turn_input_required`), fail-closed auth classification
  (401/403 `is_error` → `auth_failed`), max-turns input-required
  classification (`error_max_turns` → `turn_input_required`), tool failure
  surfacing, secret redaction (`oauth_token`, `api_key`, and other
  `@redacted_keys` stripped to `[REDACTED]` in payload and raw line),
  workspace-cwd guarding, and runtime selection defaulting to Codex.

- `elixir/test/symphony_elixir/claude_code_launch_config_test.exs` —
  launch-configuration checks split out of the shim module: catalog
  implementation-effort row selection (fixed-role rows and the moderate
  default for malformed labels), the exact-profile launch invariant
  (a resolved Fable row launches Fable with its selected effort; no
  adapter-side substitution), the fail-closed launch error when a resolved
  Fable row conflicts with config-declared no-thinking, no-thinking env
  propagation (`MAX_THINKING_TOKENS=0` present for non-Fable launches when
  configured, absent otherwise), and local provider auth env inheritance
  without tracing secret values. Shared fake-`claude` plumbing lives in
  `elixir/test/support/claude_shim_fixture.exs`.

- `elixir/test/symphony_elixir/claude_code_gate_test.exs` — gate-level checks
  proving all four ADR 0001 gate dimensions:

  1. **Workflow materialization**: `elixir/WORKFLOW.md` contains the required
     Liquid/Solid issue template placeholders and `PromptBuilder` renders the
     role prompt template with issue variables. Octo-owned skill discovery,
     invocation, role exposure, provider projection, and evaluation are
     accepted in `EmberAGI/scaling-octo-engine`, not from Symphony-local source
     packages or manifests.

  2. **Octo tool bundle** — all five required surfaces proven via the actual
     Claude Code runtime tool path, not the Codex DynamicTool path:

     Under Claude Code with `--permission-mode bypassPermissions`, Octo roles
     execute required tools via runtime-native mechanisms: the Claude Code Bash
     tool (granted by bypassPermissions) calls the role's skill CLIs directly.
     Each surface is proven by driving the fake `claude` binary with recorded
     stream-json carrying `tool_use`/`tool_result` event pairs (success and
     failure) for a representative Bash invocation of that surface's CLI, then
     asserting the shim normalizes `tool_finished` (success) and `tool_failed`
     (failure) correctly:

     - **(1) Linear GraphQL access**: Bash tool_use calling `linear-macro
       graphql` — success → `tool_finished`; failure → `tool_failed`.
     - **(2) Workpad operations**: Bash tool_use calling `linear-macro workpad
       read/update` — success → `tool_finished`; failure → `tool_failed`.
     - **(3) Artifact/proof capture**: Bash tool_use performing a file write —
       success → `tool_finished`; failure (permission denied) → `tool_failed`.
     - **(4) Repository status**: Bash tool_use calling `git status --short` —
       success → `tool_finished`; failure (not a git repo) → `tool_failed`.
     - **(5) PR status**: Bash tool_use calling `gh pr view --json state,title`
       — success → `tool_finished`; failure (no PR found) → `tool_failed`.

     One additional static assertion confirms the shim invocation carries
     `--permission-mode bypassPermissions` in the trace, proving the mechanism
     that grants the Bash tool to the Claude Code runtime. The Codex
     `DynamicTool` module is not wired into the Claude Code runtime path and
     is not used as evidence here.

  3. **Secret non-leakage**: the tracker API key configured in `WORKFLOW.md`
     does not appear in the prompt rendered by `PromptBuilder`; `oauth_token`
     and `api_key` fields in Claude stream events are stripped to `[REDACTED]`
     in both the event payload and raw line; no emitted runtime event carries
     the configured tracker token.

  4. **Tool failure normalization**: a stream with mixed successful and failed
     tool calls produces `tool_finished` for successes and `tool_failed` for
     failures; `turn_completed` (not `turn_failed`) is emitted with
     `tool_failed: true`; usage is still reported; a turn with no tool failures
     produces only `tool_finished` events and `tool_failed: false` on
     `turn_completed`.

The runtime and repository contract test modules run under `make all` (via `mix test`) and require no
live Claude subscription, Linear API key, or external service. The gate result
is repeatable in CI. Claude Code MUST NOT be enabled for unattended Octo roles
until those test modules pass under `make all`.

## Edge cases

- Provider executable is missing or not authenticated.
- Provider starts but cannot bind to the selected workspace.
- Provider session starts but the Octo-projected role skills fail to load or translate.
- A configured executable skill is discoverable but has no registered skill
  execution contract.
- A registered package, runtime input, or executable is missing, unreadable,
  denied, non-executable, symlinked outside its approved boundary, or present
  only on the orchestration host while the selected worker is remote.
- A contract entry names the orchestration checkout itself, runtime state,
  provider authentication, production configuration, or an unregistered
  sibling resource.
- Required tool bundle is unavailable or partially unavailable.
- Tool call arguments are invalid.
- Tool execution returns provider-native failure shape.
- Provider requests user input in an unattended role session.
- Codex emits a form-mode, OpenAI-form-mode, or URL-mode MCP elicitation while
  an explicit reject policy applies.
- Codex emits an MCP elicitation without an applicable deterministic policy,
  including a request whose message or schema contains secret-bearing fields.
- A server input request has an id but missing, malformed, or unsupported
  params; the Adapter must reply or fail promptly without accepting fabricated
  input.
- Provider cancellation succeeds after the orchestrator already classified the
  turn as failed.
- Provider reports usage or artifacts only after turn completion.
- Provider supports streaming but omits usage reporting.
- Provider supports session resume but not continuation turns in the same shape
  as Codex.
- Artifact/proof collection fails after the turn succeeds.
- A provider returns an authentication or revocation payload after startup
  readiness checks have already passed.
- A runtime hook or adapter reports a missing required configuration value,
  missing CLI/tool, permission denial, invalid workspace protocol, unsupported
  app-server contract, or malformed provider event schema.
- The same redacted failure fingerprint recurs at the same durable checkpoint
  after its one bounded retry, including a transient/network/rate-limit class.
- Applying the `Human Escalation` label or moving the tracker issue fails after
  the runtime has already classified a failure as irrecoverable; no runtime
  comment is required or authoritative.
- A provider-native payload contains secret-bearing fields adjacent to useful
  classification evidence.
- A deployment closes admission after a poll selected work but before that
  dispatch was published. The close acknowledgement waits behind that poll, so
  the run is visible before drain proceeds.
- A retry timer fires while admission is closed. The retry remains held and
  cannot start a worker.
- A process restarts with a closed marker, an unreadable marker path, malformed
  JSON, an unsupported marker schema, or an open marker targeting another
  generation. It starts closed before the first poll.
- A close persisted a future deployment generation, but an old process receives
  `open` for that future generation. Exact generation comparison rejects it.

## Constraints

- Keep durable specification and ADR content under `docs/specs/` and `docs/adr/`.
- Keep provider protocols native; do not force Pi or Claude Code to become
  Codex internally.
- Keep runtime adapter implementation separate from tracker workflow policy.
- Keep Octo skill inventory and activation policy outside Symphony. Symphony
  accepts validated execution records through the provider-neutral runtime
  seam and must not scan or infer a wrapper manifest.
- Preserve Codex backward compatibility while adding the provider-neutral
  contract.
- Do not rely on ambient user-local Pi extensions, themes, global skills, or
  credentials for unattended runs.
- Do not leak provider credentials, Linear tokens, or other secrets through
  prompts, logs, transcripts, or artifacts.
- The Claude Code adapter authenticates via operator-managed Claude
  subscription OAuth on the role host, not a repository- or
  prompt-provisioned API key. Credential material stays outside the
  repository, and an expired or missing credential fails closed with an
  operator-visible error instead of hanging or silently degrading.
- Unattended Claude Code role runs execute in bypass-permissions mode with no
  additional sandbox layer (operator decision, 2026-06-10). Runs must be
  fully non-interactive; the adapter must never block a role turn waiting on
  an interactive permission approval.

## Non-goals

- Add GitHub tracker support.
- Replace Linear as Octo's source of truth.
- Move Octo orchestration policy into provider adapters.
- Rebase this fork onto an external Claude Code Symphony fork.
- Build a general-purpose plugin marketplace or UI for providers.
- Build an interactive operator-answer channel inside an unattended provider
  process, or persist provider elicitation forms in Linear.
- Require every Symphony deployment to support the Octo multi-runtime profile;
  the profile is required only for deployments claiming Octo Codex/Claude
  Code/Pi support.
- For EMB-1127, build a new retry scheduler, persistent failure store,
  log-mining subsystem, dashboard redesign, live-provider QA gate, or generic
  provider error ontology beyond the listed irrecoverable runtime failure
  families. Provider-evidence discovery is a bounded implementation evidence
  step, not a new runtime feature.
- For EMB-1199, copy Octo skill packages into Symphony, make Symphony the
  editable skill authority, preload every configured skill body, or grant an
  orchestration checkout as a general-purpose provider workspace.
- For EMB-1251, add a transition outbox, new run log, task dossier, provider
  rotation, distributed lock, compatibility lifecycle, or separate network
  service.

## Open questions about system behavior

None for EMB-166 intake. Implementation may discover provider-specific
compatibility details, but those should be resolved inside linked completion
slices without weakening the skills/tools release gate.

## Decision log or links to ADRs

- [ADR 0001: Provider-Neutral Agent Runtimes](../../adr/0001-provider-neutral-agent-runtimes.md)
- EMB-166 (superseded 2026-06-10): The minimum implementation scope was a
  working multi-runtime system with Codex, Claude Code, and Pi all usable
  before close.
- EMB-166 re-scope (2026-06-10): The operator narrowed EMB-166 to the Claude
  Code slice — a first-party `claude-app-server` shim behind the existing
  Codex app-server protocol plus per-role runtime command/config selection.
  Pi, Hermes, the normalized cross-provider fixture suite, and mixed-runtime
  validation are deferred to future issues. ADR 0001 remains the long-term
  adapter architecture decision; this is sequencing, not a reversal.
- EMB-166 re-scope (2026-06-10): The Claude Code runtime must support the
  `Implementation Effort` reasoning-profile mapping (Fable 5 reviews Extreme
  and High; Opus 4.8 and Sonnet 4.6 cover the lower tiers with effort
  overrides). The mapping table lives in the Octo wrapper spec and the EMB-166
  issue body; this spec owns the adapter's model/effort/no-thinking
  configurability requirement.
- EMB-166: Skills and tools are a non-negotiable release gate for each enabled
  runtime.
- EMB-166 re-grill (2026-06-10): Fail-closed default reasoning profile for the
  Claude Code runtime is the `Moderate` row (reviewer Claude Opus 4.8 effort
  `high`; implementer/QA Claude Sonnet 4.6 effort `high`). Runtime auth is
  Claude subscription OAuth; unattended runs use bypass-permissions with no
  sandbox and must stay non-interactive. Recorded in the EMB-166 issue body
  acceptance criteria, the Constraints section above, and
  [ADR 0002](../../adr/0002-claude-code-unattended-auth-and-permission-posture.md),
  which owns the auth and permission-posture rationale and reversal policy.
- EMB-1127 intake: Generalized provider-auth escalation into a
  provider-neutral irrecoverable runtime failure policy. The classifier is the
  shared retry/escalation seam; provider adapters are concrete adapters into
  that seam, and orchestrator/tracker/status code consume the normalized
  family rather than parsing provider-specific raw payloads.
- EMB-1178 intake: Distinguished deterministically human-required input from
  generic input-required/no-progress events. Provider Adapters release their
  native pending request promptly, while the irrecoverable-failure,
  process-ownership, and Human Escalation path owns the shared lifecycle response.
  This extends ADR 0001's Adapter decision and does not require a new ADR.
- EMB-1199 intake: A provider-neutral skill execution contract is the runtime
  seam between Octo-owned manifest registration and provider-native launch
  permissions. Symphony validates and propagates the resolved contract;
  Octo continues to own skill source, role exposure, activation, provider
  evals, and wrapper pin promotion. ADR 0001 is amended rather than adding a
  new ADR because this is a completion of its existing skills/tools release
  gate.
- EMB-1251: Work admission is an Orchestrator Interface because dispatch
  serialization is the invariant home. The Octo wrapper owns complete
  generation construction, closing all role processes, bounded drain,
  materialization/restart verification, and opening the verified target.
  This specification is the authority for the new Symphony admission
  interface. Octo ADR 0016 retains its existing wrapper ownership and is not
  expanded into a complete-generation-cutover decision here. The marker is an
  implementation detail of that interface, not a new cross-system authority or
  service, so no new Symphony ADR is required.

## References to source issues

- [EMB-166: Integrate Claude Code as an Octo Symphony role runtime](https://linear.app/emberai/issue/EMB-166/implement-multi-runtime-symphony-support-for-codex-claude-code-and-pi)
  (re-scoped 2026-06-10 from "Implement multi-runtime Symphony support for
  Codex, Claude Code, and Pi")
- [EMB-1127: Generalize irrecoverable runtime failure escalation](https://linear.app/emberai/issue/EMB-1127/generalize-irrecoverable-runtime-failure-escalation)
- [EMB-1178: Handle unattended Codex MCP elicitation without lease stalls](https://linear.app/emberai/issue/EMB-1178/handle-unattended-codex-mcp-elicitation-without-lease-stalls)
- [EMB-1199: Expose registered skill runtime paths to every managed role](https://linear.app/emberai/issue/EMB-1199/expose-registered-skill-runtime-paths-to-every-managed-role)
- [EMB-1251: Fence Symphony work admission during atomic Octo cutovers](https://linear.app/emberai/issue/EMB-1251/fence-symphony-work-admission-during-atomic-octo-cutovers)
