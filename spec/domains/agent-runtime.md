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

**Issue reasoning profile**: Symphony maps the durable `Implementation Effort`
label to a provider-specific reasoning profile for the actual role name and
current tier. The runtime loads a universal provider-keyed role matrix from the
optional TOML file named by `SYMPHONY_REASONING_PROFILES`; when that variable
is absent, the built-in defaults encode the operator-approved Codex and Claude
Code matrices.

**Top-level role claim lease**: A Linear-visible structured marker that records
which Symphony role run currently owns a top-level issue/workspace/role
dispatch. The marker includes issue id, issue identifier, role, holder/run
identity, worker host, workspace path, session id when known, attempt,
started/refreshed/expiry timestamps, retry or recovery reason when applicable,
and a state such as `active`, `retrying`, `recoverable`, `blocked`,
`quarantined`, `released`, or `expired`.

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
- User-input-required events and permission prompts must not leave unattended
  runs stalled indefinitely.
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
- `SYMPHONY_REASONING_PROFILES`, when set, must point to a valid TOML profile
  matrix. Parse errors, unknown provider keys, unknown role keys, unknown tier
  keys, missing provider defaults, incomplete tier tables, unsupported effort
  values, unsupported provider model-effort pairs, and unsupported no-thinking
  rows fail closed during startup validation. The runtime must not silently fall
  back to built-in defaults when the file exists but is invalid.

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
  supported.
- Claude Code uses a first-party adapter or shim with separated transport,
  server/session lifecycle, cancellation, permission handling, tool bridging,
  and local Claude CLI auth/startup validation.
- Pi uses native JSONL RPC, maps provider commands and streamed events,
  explicitly controls auto-retry and auto-compaction, uses an explicit worker
  extension bundle, and converts unattended UI/input requests into normalized
  input-required events.

### Reasoning Profile TOML Contract

The optional `SYMPHONY_REASONING_PROFILES` file uses this provider-keyed,
role-first TOML shape:

```toml
[providers.codex]
default_tier = "high"
default = "high"
implementer = { extreme = "high", high = "high", moderate = "medium", low = "low", minimal = "none" }
reviewer = { extreme = "xhigh", high = "xhigh", moderate = "high", low = "medium", minimal = "low" }
qa = { extreme = "xhigh", high = "xhigh", moderate = "high", low = "medium", minimal = "low" }

[providers.claude_code]
default_tier = "moderate"
default = "opus/high"
implementer = { extreme = "opus/xhigh", high = "opus/high", moderate = "sonnet/high", low = "sonnet/medium", minimal = "sonnet/none" }
reviewer = { extreme = "fable/xhigh", high = "fable/high", moderate = "opus/high", low = "sonnet/high", minimal = "sonnet/medium" }
qa = { extreme = "fable/xhigh", high = "fable/high", moderate = "opus/high", low = "sonnet/high", minimal = "sonnet/medium" }
```

Only `codex` and `claude_code` providers are currently supported. Each provider
must declare `default_tier` and `default`. The shared tier vocabulary is
`extreme`, `high`, `moderate`, `low`, and `minimal`; the shared effort
vocabulary is `none`, `low`, `medium`, `high`, `xhigh`, and `max`.

The profile contract has four rules:

1. A cell is a string in the form `"effort"` or `"model/effort"`. A model-less
   cell uses the harness base model from the runtime frontmatter/config.
2. A provider role key maps either to one scalar cell, meaning tier-invariant,
   or to a complete five-tier inline table. Partial tier tables are invalid.
3. Each provider must declare `default`, used as the fallback for unlisted
   actual role names, and `default_tier`, used as the fail-closed tier for
   missing or malformed labels when that provider defaults invalid labels.
4. Unknown role keys, unknown tier keys, unsupported model-effort combinations,
   and Claude `none` cells whose model cannot be validated for disabling
   thinking are startup errors. The profile schema has no inheritance,
   aliasing, provider-specific row shape, `fixed` section, `tiers` section,
   `worker` row, or `no_thinking` key.

Codex resolves by actual role name with `default` fallback. Dynamic Codex roles
(`implementer`, `reviewer`, and `qa`) rewrite `model_reasoning_effort` from the
selected cell's effort. When the selected cell also declares a model, they
rewrite the command's `model="..."` config. Model-less Codex cells leave the
frontmatter command model unchanged. Codex supports native efforts `none`,
`low`, `medium`, `high`, and `xhigh`; Codex `max` is invalid at startup.
Invalid or ambiguous Codex `implementation-effort:` labels fail closed.

Claude Code resolves the same label to the provider role at session start.
Model cells set the per-session model, while model-less cells use the
frontmatter `claude_code.model`. Claude passes `--effort <value>` for
`low`, `medium`, `high`, `xhigh`, and `max`. A Claude `none` cell translates to
the verified no-thinking invocation: `--effort low` plus
`MAX_THINKING_TOKENS=0`. Because that translation is model-sensitive, `none`
must be paired with a model that startup validation can prove supports
disabling thinking. Claude defaults missing, malformed, unsupported, or
ambiguous effort labels to the provider `default_tier`, which is `moderate` in
the built-in matrix.

The built-in matrices are:

- Codex: `default_tier` `high`; `default` `high`; implementer
  `high/high/medium/low/none`; reviewer and QA
  `xhigh/xhigh/high/medium/low`.
- Claude Code: `default_tier` `moderate`; `default` `opus/high`; implementer
  `opus-xhigh/opus-high/sonnet-high/sonnet-medium/sonnet-none`; reviewer and QA
  `fable-xhigh/fable-high/opus-high/sonnet-high/sonnet-medium`.

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
  so requesting no-thinking with a Fable model fails closed at config
  validation.

Verified model x effort support matrix (transcribed from the `claude` CLI
v2.1.172 effort-gating allow-lists). `low`, `medium`, and `high` are supported
on every model; `xhigh` and `max` are gated to specific models:

- `xhigh`: Fable 5, Opus 4.8, Opus 4.7.
- `max`: Fable 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 4.6.

Config validation resolves bare aliases (`fable`/`opus`/`sonnet`/`haiku`) to the
current latest model and strips provider routing prefixes (for example
`us.anthropic.`) before checking the matrix. A restricted-effort request whose
model is unset, an alias/id resolving to an unsupported family, or otherwise not
verifiable against this matrix fails closed at config validation rather than at
runtime. For example `model: sonnet, effort: xhigh` is rejected at config
validation.

Runtime Fable availability fallback: when a role profile selects Fable and the
operator has marked Fable unavailable, the adapter preserves the preferred
Fable profile in runtime metadata but launches Opus 4.8 at `high` effort. This
fallback is not a reasoning-profile matrix rewrite; it is a temporary execution
substitution so the wrapper can keep expressing the preferred profile and
remove the fallback when Fable access returns.

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
enablement is proved by two deterministic test modules in the Symphony Elixir
test suite, both driven by a fake `claude` binary replaying recorded stream-json
without a live Claude subscription:

- `elixir/test/symphony_elixir/claude_code_app_server_test.exs` — shim-level
  contract checks: verified invocation flags (`--print`, `--output-format
  stream-json`, `--verbose`, `--permission-mode bypassPermissions`), no-thinking
  env (`MAX_THINKING_TOKENS=0`), normalized event vocabulary
  (`session_started`, `text_delta`, `notification`, `tool_finished`,
  `tool_failed`, `turn_completed`, `turn_failed`, `turn_input_required`),
  fail-closed auth classification (401/403 `is_error` → `auth_failed`),
  max-turns input-required classification (`error_max_turns` →
  `turn_input_required`), tool failure surfacing, secret redaction
  (`oauth_token`, `api_key`, and other `@redacted_keys` stripped to
  `[REDACTED]` in payload and raw line), workspace-cwd guarding, and runtime
  selection defaulting to Codex.

- `elixir/test/symphony_elixir/claude_code_gate_test.exs` — gate-level checks
  proving all four ADR 0001 gate dimensions:

  1. **Skill materialization**: `.codex/role-skills/implementer.json` and
     `.codex/role-skills/qa.json` manifests resolve all declared skill
     directories and SKILL.md files; `elixir/WORKFLOW.md` contains the required
     Liquid/Solid issue template placeholders; `PromptBuilder` renders the role
     prompt template with issue variables; manifests carry `octo_authority_boundaries`.

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

Both test modules run under `make all` (via `mix test`) and require no live
Claude subscription, Linear API key, or external service. The gate result is
repeatable in CI. Claude Code MUST NOT be enabled for unattended Octo roles
until both test modules pass under `make all`.

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
- EMB-166 re-grill (2026-06-10): Fail-closed default reasoning profile for the
  Claude Code runtime is the `Moderate` row (reviewer Claude Opus 4.8 effort
  `high`; implementer/QA Claude Sonnet 4.6 effort `high`). Runtime auth is
  Claude subscription OAuth; unattended runs use bypass-permissions with no
  sandbox and must stay non-interactive. Recorded in the EMB-166 issue body
  acceptance criteria, the Constraints section above, and
  [ADR 0002](../adr/0002-claude-code-unattended-auth-and-permission-posture.md),
  which owns the auth and permission-posture rationale and reversal policy.

## References to source issues

- [EMB-166: Integrate Claude Code as an Octo Symphony role runtime](https://linear.app/emberai/issue/EMB-166/implement-multi-runtime-symphony-support-for-codex-claude-code-and-pi)
  (re-scoped 2026-06-10 from "Implement multi-runtime Symphony support for
  Codex, Claude Code, and Pi")
