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

**Top-level role claim lease**: A Linear-visible structured marker that records
which Symphony role run currently owns a top-level issue/workspace/role
dispatch. The marker includes issue id, issue identifier, role, holder/run
identity, worker host, workspace path, session id when known, attempt,
started/refreshed/expiry timestamps, retry or recovery reason when applicable,
and a state such as `active`, `retrying`, `recoverable`, `blocked`,
`quarantined`, `released`, or `expired`.

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

**Process ownership record**: A local runtime metadata file that records the
Symphony-owned role run, workspace, worker host, app-server PID when available,
app-server process group when available, observed descendant PIDs,
session/run identity, inherited role-run environment marker, cleanup status, and
quarantine reason for the role runtime process tree. This is the OS/process
cleanup surface; the tracker claim lease remains the durable dispatch gate.

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
- Provider-authentication failures that occur after runtime startup/readiness
  checks, including Claude Code HTTP 401/403 results, normalized
  `{:auth_failed, ...}` adapter errors, and provider-auth-shaped `before_run`
  workspace hook failures from `Workspace.run_before_run_hook`, must remain
  provider-infrastructure failures across the adapter/workspace-hook, runner,
  and orchestrator retry interface. They must not be converted into generic
  agent failures, must not schedule or consume the ordinary issue retry loop,
  and must emit only redacted operator-visible blocked/status evidence on
  existing runtime surfaces such as the top-level claim lease. Non-auth
  workspace hook failures remain ordinary workspace-hook failures. This
  invariant is recorded for EMB-1123 and EMB-1128 and supports the wrapper
  readiness hardening in EMB-1121 while preserving ADR 0002: Claude Code
  continues to use operator-managed subscription OAuth, and no
  `ANTHROPIC_API_KEY` migration is introduced.
- Runtime retry policy must be driven by a provider-neutral runtime failure
  family, not by ad hoc process-exit text at each retry call site. Known
  deterministic irrecoverable families are:
  `provider_authentication_or_revocation`,
  `missing_required_runtime_configuration`, `missing_required_tool_or_cli`,
  `permission_denied`, `invalid_workspace_or_runtime_protocol`,
  `unsupported_app_server_contract`, `malformed_provider_event_schema`,
  `human_input_required`, and `repeated_identical_no_progress_failure`.
- Deterministic single-shot irrecoverable failures must escalate immediately
  instead of scheduling or consuming an ordinary role retry. The classification
  must be preserved across adapter, workspace hook, runner, orchestrator,
  tracker, log, status API, and dashboard surfaces.
- Persistent no-progress classification must use a bounded fingerprint that
  includes at least issue id, workspace path, role, runtime provider, failure
  family, normalized provider/runtime subtype when known, and redacted stable
  error summary. Persistent classification is satisfied as soon as the same
  fingerprint appears in three consecutive failed observations for the same
  issue/workspace/role without an intervening reset condition. Escalation fires
  immediately when the third matching observation is recorded, regardless of
  elapsed wall-clock time between matching observations; a two-minute rapid-loop
  expectation may be used as a feedback SLO, but not as an eligibility cap.
  Reset conditions include an intervening successful progress/completion event,
  a different failure fingerprint or excluded transient class, a new claim
  lease or intentionally reset retry epoch, a material issue/branch/workspace
  input change, or an operator-recorded repair action after the prior failure.
  Explicit transient, network, service unavailable, rate-limit, timeout,
  capacity, and operator-interrupted classes are excluded from this persistent
  irrecoverable path unless a later issue records a narrower family-specific
  policy.
- Every irrecoverable classification must clear or avoid ordinary retry
  scheduling, write or update the same-scope claim lease to a blocked or
  escalated state, include redacted `retry_reason` and `recovery_reason`
  evidence, apply or preserve the tracker issue's exact `Human Escalation`
  label when the selected tracker supports it, move the issue to the
  `Human Escalation` state when the selected workflow supports it, and write a
  concise operator-visible note describing the redacted failure family,
  affected provider/runtime when known, and required human action.
- Tracker mutation failures during irrecoverable escalation must not re-enter
  ordinary role retry. They must leave local runtime status and logs visibly
  blocked/escalated with enough redacted evidence for an operator to repair the
  tracker mutation or runtime environment manually.
- Irrecoverable failure summaries, claim leases, logs, status payloads, and
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
  runtime status logs, claim leases, tracker Operator Notes or handoffs for
  relevant incidents, local generated runtime state, and existing redacted
  incident notes. Existing authenticated local Codex and Claude CLI contexts may
  also be used for bounded, non-destructive probes that capture exit status and
  provider/runtime stderr/stdout/event shape. Discovery must not commit raw logs,
  secret-bearing payloads, provider credentials, full issue bodies, or
  unbounded process output; the PR or handoff records only source categories,
  redaction decisions, and fixture coverage.
- Provider server requests for input must be recognized inside the provider
  Adapter's active protocol loop; they must not be treated as opaque
  notifications or left pending until a transport timeout or claim-lease
  expiry.
- An unattended Adapter may answer or reject a provider input request only when
  an approved deterministic non-interactive policy supplies that outcome. If
  no such policy applies, the Adapter must promptly send the provider-native
  decline or cancellation response needed to release the pending protocol
  request and return `human_input_required` as a single-shot irrecoverable
  failure. The shared lifecycle then clears ordinary retry, records a blocked
  or escalated claim lease, and uses the existing Human Escalation path.
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
- Symphony must not start a second top-level role run for the same
  issue/workspace/role while any same-scope non-expired claim lease is active,
  retrying, recoverable, blocked, or quarantined for another holder, or while
  any same-scope local process ownership record shows a live or quarantined
  app-server process tree. Claim leases and process ownership records for
  different roles or workspaces may coexist, but they must not overwrite or
  hide an active same-scope owner.
- Legitimate continuation turns inside one role run use the existing runtime
  session and `agent.max_turns` loop; they are not a new top-level dispatch and
  must not be blocked by the duplicate-dispatch gate.
- Claim lease refreshes must update structured marker state without producing
  unbounded heartbeat comments or role-authored Symphony Handoff comments.
- Worker termination, stall restart, abnormal exit, operator restart, and
  orchestrator restart paths must either clean the owned app-server process
  tree or preserve/quarantine process ownership metadata so replacement
  top-level dispatch refuses until recovery policy allows it.
- If stall restart records live owned app-server evidence, the queued retry
  must surface a quarantined claim lease or equivalent blocked cleanup state
  plus the scoped process ownership metadata in status/API payloads; it must
  not appear as an ordinary retry while cleanup remains unresolved.
- When a running issue leaves active dispatch because it becomes terminal,
  non-active, unroutable, or reassigned, the runtime must record process
  completion or quarantine first and then update the same-scope Linear-visible
  claim lease to `released`.
- Normal worker completion must not mark process ownership as cleaned until the
  scoped app-server process tree is no longer live. If the app-server PID,
  observed process tree, process group, or inherited ownership-marker process
  is still live when the worker exits normally, the runtime must record
  quarantine metadata and make the active-state continuation lease fail closed
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

- read candidate issue state, including all structured claim lease markers from
  tracker comments across paginated comment results;
- refuse dispatch when any same-scope marker is non-expired and owned by
  another holder in an active/retry/recoverable/blocked/quarantined state;
- refuse dispatch when local process ownership for the issue/workspace/role is
  live or quarantined, including when the recorded parent app-server PID has
  exited but an observed descendant PID, owned process group, or process with a
  matching inherited role-run ownership marker remains live;
- write or update the claim lease for the selected holder/run and refetch the
  issue to verify ownership before spawning the worker; and
- refresh the same marker from runtime updates rather than creating heartbeat
  comment streams.

Runtime status and API/dashboard projections should expose enough read-only
metadata to diagnose duplicate-prevention decisions: session age versus
accumulated issue-pass age, claim state, retry or replacement reason, run/session
identity, worker host, workspace path, app-server PID when available, and
process cleanup/quarantine status.

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
starts a new isolated named Herdr session containing the selected provider's
orchestrator and workers. Runtime-owned launchers outside the selected
repository apply exact model, effort, and reusable profile instructions. Codex
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

The orchestrator receives the worker launcher path through
`OCTO_HERDR_WORKER_LAUNCHER`. Missing or incompatible Herdr, unsafe socket
paths, rejected launchers, and adapter-side model/effort substitution fail
closed. Every mutating Herdr command is scoped to the run-owned named session
and private configuration root; cleanup verifies that the operator's default
server snapshot is unchanged.

Herdr owns terminal input and provider keyboard-protocol semantics behind its
atomic `pane run` Interface. Symphony submits every orchestrator assignment,
worker result, and consultation response through that Interface. Symphony
transport Adapters and runtime launchers must not branch on the target provider
to decompose a turn into `send-text`, synthesized key sequences, or other PTY
writes.

Initial turn submission uses a provider-neutral acknowledgement state machine.
The Adapter records the ready agent revision, submits the prompt with `pane
run`, and observes status plus revision. `working` proves an active turn; an
idle/done state with an advanced revision proves a fast completed turn. If the
agent remains idle with the original revision after the bounded settlement
window, the Adapter sends exactly one empty `pane run` to confirm the prompt
already present at the harness input, then resumes bounded observation. An
unchanged stale idle state never completes the turn, and confirmation is never
repeated.

Inter-agent message submission uses the same public Herdr Interface through one
runtime-owned CLI Adapter shared by the worker-restricted and orchestrator
projections. The projections may inspect Herdr's target identity, status, and
revision; they must not inspect or synthesize terminal protocol. With the
pinned Herdr 0.7.4 contract, healthy working-target single-line steering passes
through unchanged. A Claude-target multiline paste receives exactly one empty
`pane run` confirmation so the paste becomes a queued message. A Claude target
that remains idle, done, or blocked at its original revision after the bounded
settlement also receives exactly one confirmation. Advanced revisions,
started turns, and non-Claude targets are not confirmed again. This is a thin
provider compatibility Adapter over Herdr's public Interface, not a second
terminal-input implementation.

The Codex launcher uses unattended workspace-write/no-approval mode, disables
`multi_agent`, disables alternate-screen rendering, and supplies the selected
workspace through the whole `projects={...}` trust map. The Claude launcher
uses unattended bypass-permissions mode and disables the provider-native
`Agent` tool. The orchestrator is not ready for its first prompt until Herdr
observes its identity in an idle/done state. A restricted worker Herdr proxy is
defense in depth rather than a complete process sandbox; one-generation
delegation remains a profile invariant backed by evals.

Symphony observes Herdr identity/status and emits its existing normalized
top-level runtime events. Runtime contract tests prove that resolved profiles
become exact orchestrator and worker launcher arguments, reusable system
instructions reach each provider, the isolated session is cleaned up without
replacing or stopping the default server, and incompatible or substituted
profiles fail closed. The same contract tests prove every allowed direction of
delegation preserves `pane run`, never reconstructs provider terminal input
inside Symphony, and permits at most one empty confirmation after an unchanged
idle revision. Generated-wrapper tests additionally execute both role
projections against the same message-submission Adapter and prove multiline,
unchanged-idle, healthy working-steering, advanced-revision, non-Claude, and
command-failure cases without raw input commands. Bounded live evaluation—not narration—provides
session/start/message/result/integration/cleanup evidence for Codex and Claude.

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
- The same redacted no-progress failure fingerprint repeats in three
  consecutive failed observations, including rapid loops within two minutes and
  delayed repeats caused by retry backoff, while reset conditions and
  transient/network/rate-limit failure classes are absent.
- Applying the `Human Escalation` label, moving the tracker issue, or writing
  the operator note fails after the runtime has already classified a failure as
  irrecoverable.
- A provider-native payload contains secret-bearing fields adjacent to useful
  classification evidence.

## Constraints

- Keep durable specification and ADR content under `docs/specs/` and `docs/adr/`.
- Keep provider protocols native; do not force Pi or Claude Code to become
  Codex internally.
- Keep runtime adapter implementation separate from tracker workflow policy.
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
  native pending request promptly, while the existing irrecoverable-failure,
  claim-lease, and Human Escalation path owns the shared lifecycle response.
  This extends ADR 0001's Adapter decision and does not require a new ADR.

## References to source issues

- [EMB-166: Integrate Claude Code as an Octo Symphony role runtime](https://linear.app/emberai/issue/EMB-166/implement-multi-runtime-symphony-support-for-codex-claude-code-and-pi)
  (re-scoped 2026-06-10 from "Implement multi-runtime Symphony support for
  Codex, Claude Code, and Pi")
- [EMB-1127: Generalize irrecoverable runtime failure escalation](https://linear.app/emberai/issue/EMB-1127/generalize-irrecoverable-runtime-failure-escalation)
- [EMB-1178: Handle unattended Codex MCP elicitation without lease stalls](https://linear.app/emberai/issue/EMB-1178/handle-unattended-codex-mcp-elicitation-without-lease-stalls)
