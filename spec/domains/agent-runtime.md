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

**Issue reasoning profile (Claude runtimes)**: The Octo wrapper maps the durable
`Implementation Effort` value to a per-role Claude model and `effort` selection
(analogous to the Codex reasoning profile). The mapping table is Octo wrapper
policy owned by `scaling-octo-engine` (`spec/domains/symphony-role-runtime.md`);
the Claude Code adapter's obligation is to make model, effort, and no-thinking
invocation selectable per session.

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
- User-input-required events and permission prompts must not leave unattended
  runs stalled indefinitely.
- Runtime adapters must collect or expose artifacts and proof in a normalized
  way so review, QA, landing, and operator status surfaces do not need to know
  which provider produced the evidence.
- The Claude Code adapter must support per-session model selection, `effort`
  configuration, and a verified no-thinking invocation so the Octo wrapper can
  map `Implementation Effort` levels onto Claude models. Unsupported
  combinations (for example Sonnet 4.6 with effort `xhigh`) must fail closed at
  config validation, not at runtime.

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

Provider-specific requirements:

- Codex uses the existing Codex app-server path and dynamic tools where
  supported.
- Claude Code uses a first-party adapter or shim with separated transport,
  server/session lifecycle, cancellation, permission handling, tool bridging,
  and local Claude CLI auth/startup validation.
- Pi uses native JSONL RPC, maps provider commands and streamed events,
  explicitly controls auto-retry and auto-compaction, uses an explicit worker
  extension bundle, and converts unattended UI/input requests into normalized
  input-required events.

Octo mixed-runtime validation (a real workflow assigning roles to different
runtimes in one run, for example implementer on Pi, reviewer on Claude Code,
QA on Codex, and landing on Codex) is deferred until a second non-Codex
adapter exists. The re-scoped EMB-166 requires only that a role configured for
Claude Code runs end to end while other roles stay on Codex.

## Edge cases

- Provider executable is missing or not authenticated.
- Provider starts but cannot bind to the selected workspace.
- Provider session starts but role skills fail to load or translate.
- Required tool bundle is unavailable or partially unavailable.
- Tool call arguments are invalid.
- Tool execution returns provider-native failure shape.
- Provider requests user input in an unattended role session.
- Provider cancellation succeeds after the orchestrator already classified the
  turn as failed.
- Provider reports usage or artifacts only after turn completion.
- Provider supports streaming but omits usage reporting.
- Provider supports session resume but not continuation turns in the same shape
  as Codex.
- Artifact/proof collection fails after the turn succeeds.

## Constraints

- Keep durable specification and ADR content under `spec/` and `spec/adr/`.
- Keep provider protocols native; do not force Pi or Claude Code to become
  Codex internally.
- Keep runtime adapter implementation separate from tracker workflow policy.
- Preserve Codex backward compatibility while adding the provider-neutral
  contract.
- Do not rely on ambient user-local Pi extensions, themes, global skills, or
  credentials for unattended runs.
- Do not leak provider credentials, Linear tokens, or other secrets through
  prompts, logs, transcripts, or artifacts.

## Non-goals

- Add GitHub tracker support.
- Replace Linear as Octo's source of truth.
- Move Octo orchestration policy into provider adapters.
- Rebase this fork onto an external Claude Code Symphony fork.
- Build a general-purpose plugin marketplace or UI for providers.
- Require every Symphony deployment to support the Octo multi-runtime profile;
  the profile is required only for deployments claiming Octo Codex/Claude
  Code/Pi support.

## Open questions about system behavior

None for EMB-166 intake. Implementation may discover provider-specific
compatibility details, but those should be resolved inside linked completion
slices without weakening the skills/tools release gate.

## Decision log or links to ADRs

- [ADR 0001: Provider-Neutral Agent Runtimes](../adr/0001-provider-neutral-agent-runtimes.md)
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

## References to source issues

- [EMB-166: Integrate Claude Code as an Octo Symphony role runtime](https://linear.app/emberai/issue/EMB-166/implement-multi-runtime-symphony-support-for-codex-claude-code-and-pi)
  (re-scoped 2026-06-10 from "Implement multi-runtime Symphony support for
  Codex, Claude Code, and Pi")
