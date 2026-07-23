# Repository Quality Assurance

Status: Draft v1

Purpose: Define the minimum repository QA contract for durable behavior
changes and the ownership seam between Symphony runtime code and Octo-owned
role skill sources.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`,
`RECOMMENDED`, `MAY`, and `OPTIONAL` in this document are to be interpreted as
described in RFC 2119.

## Intended Behavior

Repository changes must carry enough local evidence for reviewers and role
agents to verify durable behavior without rediscovering the acceptance bar from
individual Linear issues.

This domain is the repo-level minimum acceptance suite for implementation work.
When a branch adds, changes, removes, or materially changes durable behavior,
the branch must update this file or record a defensible no-change rationale in
the Codex Workpad and final Symphony Handoff.

Agent QA workflows may use browser-facing evidence gathering when it materially
improves issue verification, but that capability must stay local, optional,
QA-only, and free of external hosted-browser or provider-key dependencies.

## Durable Sources

Repository QA uses these branch-local durable sources as canonical context:

- `docs/specs/`
- `docs/adr/`

`CONTEXT.md` MAY be used as domain vocabulary and contextual naming guidance
when present. `docs/specs/` and `docs/adr/` remain the durable QA authority.
`CONTEXT.md` and `docs/adr/` MUST NOT be treated as canonical sources for Octo
QA decisions.

When a QA, review, or handoff instruction requires handoff-artifact spec
context, agents SHOULD read
`docs/specs/domains/symphony-handoff-artifacts.md`. That file is a Symphony-local
consumer reference to Octo's source-of-truth handoff-artifacts contract, not a
forked normative copy. The Octo workflow surface remains responsible for
successful QA-to-Human-Review packet details.

## Domain Concepts

**Agent QA**: The Symphony role responsible for verifying that an implementation
meets the owning issue's acceptance criteria before the work is treated as
ready for human/operator review.

**Browser Use**: A QA-owned browser-facing validation capability. In this
domain, the name means local browser inspection or automation that can collect
useful evidence without external provider keys. It includes Browser Use CLI
commands such as `browser-use open`, `browser-use state`, `browser-use click
<index>`, `browser-use type "text"`, `browser-use input <index> "text"`, and
`browser-use screenshot`, or local stdio MCP launched with
`uvx --from 'browser-use[cli]' browser-use --mcp`, when those paths run against
a local browser session without cloud services. CLI interactions use numeric
element indices from `browser-use state`; `input <index> "text"` is the
click-and-type field-filling path, while `type "text"` is for an already
focused field. It does not mean Browser Use Cloud, a hosted browser service, or
an autonomous LLM browser agent that requires an OpenAI, Anthropic, Google, or
similar provider key.

**QA artifact**: Evidence generated during QA, such as screenshots, page-state
summaries, form-flow notes, command output, logs, or short recordings.

## Octo Role Skill Ownership

`EmberAGI/scaling-octo-engine` is the provider-neutral source of truth for Octo
role skill packages and manifests. It owns skill discovery, registration,
contextual activation, role exposure, provider-view generation, and evaluation
behavior. Symphony owns runtime Adapters and workflow prompt loading, including
the provider-native launch and permission projection of integration-supplied,
validated skill execution contracts. That runtime projection does not make
Symphony a second editable skill authority.

## Browser Use Rules And Invariants

- Browser Use may be used only by Agent QA guidance and QA acceptance
  workflows. Other Symphony roles must not gain it as a general-purpose
  capability through this contract. Octo owns any corresponding skill exposure.
- Browser Use must remain optional and issue-appropriate. Agent QA should use
  it when browser-facing validation, screenshots, page-state inspection,
  form-flow verification, or manual acceptance evidence materially improves QA.
- Browser Use must not require `BROWSER_USE_API_KEY`, Browser Use Cloud,
  hosted browser infrastructure, or any new operator-provisioned API secret.
- Browser Use guidance must not require OpenAI, Anthropic, Google, or other LLM
  provider keys for QA evidence capture.
- If an installed Browser Use agent mode or library path requires an LLM
  provider key, Agent QA must not use that mode. Agent QA must choose a local
  deterministic fallback, record a not-applicable rationale, or route to Human
  Escalation when the owning issue cannot be verified without the blocked
  capability.
- QA artifacts must follow the tracker artifact policy for the workflow. For
  Linear-backed Octo workflows, durable QA artifacts must be uploaded or
  attached to Linear, and agents must not rely on an untracked non-Linear
  artifact store as the durable evidence location.
- Browser automation must respect the operational readiness posture of the role
  environment. If no usable browser is available, headless execution is
  blocked, dependencies are absent, sandbox policy prevents launch, or a
  desired feature needs a forbidden key, Agent QA must use the documented
  fallback path instead of silently weakening validation.

## Browser Use Interfaces And Contracts

Agent QA browser-facing validation should record:

- why browser automation was relevant or why it was not applicable;
- the local tool path used, such as Browser Use CLI, local Browser Use stdio
  MCP, existing Playwright/browser tooling, or manual inspection;
- the pages, states, or flows inspected;
- the QA artifacts generated and where they were attached in Linear;
- any fallback chosen and the reason for that fallback.

When Agent QA successfully moves a Linear-backed issue to Human Review, that
record must stay compact in the `## Symphony Handoff` comment. The handoff uses
a tiny review summary in `Role note`; detailed browser checks, command
evidence, artifact IDs, environment provenance, and limitations belong in
compact handoff `Work done` or approved Linear attachment metadata.
Browser-facing checks should be mapped to the issue acceptance criteria or
repo-level minimum acceptance results they support.

If Agent QA creates no external browser artifact, the compact evidence trail
must state that no browser artifact was useful or possible and give the
rationale, such as no browser-facing acceptance surface, no usable local
browser, blocked headless execution, sandbox launch restrictions, missing local
Browser Use CLI/MCP tooling, or a desired Browser Use path that required a
forbidden key or hosted service.

Allowed local no-key paths include:

- Browser Use CLI commands against a local browser session, including
  `browser-use open`, `browser-use state`, `browser-use click <index>`,
  `browser-use type "text"`, `browser-use input <index> "text"`, and
  `browser-use screenshot`;
- local Browser Use stdio MCP launched with
  `uvx --from 'browser-use[cli]' browser-use --mcp` when it does not request a
  hosted browser service, `BROWSER_USE_API_KEY`, or an LLM provider key;
- existing repository Playwright or browser test tooling;
- deterministic local browser CLI automation when a browser binary is already
  available in the role environment;
- ordinary manual inspection with concise evidence notes when automation is not
  available or not worth the operational cost.

Fallback outcomes include:

- manual inspection with Linear-attached evidence;
- existing non-Browser-Use test tooling, such as Playwright, when it covers the
  acceptance path;
- explicit not-applicable rationale for non-browser issues or environments with
  no usable browser;
- Human Escalation when browser-facing acceptance is required and all no-key
  local paths are blocked.

## Shared Role Skill Sources

Symphony MUST NOT own or expose Octo role skill packages. The repository MUST
NOT commit the `.codex/skills/` source inventory or `.codex/role-skills/`
manifests, and active Symphony workflows, runtime specifications, validators,
and tests MUST NOT resolve either path. Repository-local `.codex` material used
for unrelated Codex authentication or workspace setup is outside this source
inventory rule.

Changes to cross-provider skill discovery, registration, activation, role
exposure, provider-view generation, or evaluation MUST be implemented and
accepted in `EmberAGI/scaling-octo-engine`. Symphony-native projection of a
validated skill execution contract into provider launch and permission surfaces
is governed by [Agent Runtime](./agent-runtime.md) and ADR 0001.

| Change Surface | Required Invariants | Minimum Local Validation | Escalation Route |
| --- | --- | --- | --- |
| Herdr live-agent delegation lifecycle | Herdr 0.7.5/protocol 17 remains the deep module that owns atomic terminal input, provider keyboard protocol, prompt acknowledgement, and lifecycle waiting. Symphony creates the workspace pane from returned IDs, uses strict named/kind `agent start`, submits all participant messages through verified native `agent prompt`, and observes bounded completion through server-owned `agent wait`. The prompt wait exceeds Herdr 0.7.5's 5000 ms prompt-effect window so an unchanged `state_change_seq` produces `agent_prompt_stalled`; on that typed result, the Adapter re-drives submission with at most two follow-up submit inputs before preserving the failure. The runtime-owned worker launcher accepts only the returned pane ID and strict worker name; the Adapter supplies the fixed provider kind, native profile arguments, worker environment, and bounded timeout rather than directly executing a provider or accepting caller substitutions. Closed agents, timeouts, and protocol mismatch remain typed failures. Both provider projections share the same recovery path. The worker projection permits only agent list/get/read/prompt/wait and denies descendant start, raw pane input, key injection, topology, and server control. No 0.7.4 pane-run, manual-confirmation, revision, sleep/poll, top-level wait, dual-version, translation, or compatibility path remains. | Deterministic public-Interface tests covering compatible and incompatible runtime readiness, returned workspace/pane IDs, strict Codex and Claude named/kind startup (including the fixed worker launcher contract), verified prompt submission with working and fast-completed outcomes, stall-then-recover and retries-exhausted outcomes, bounded native waits, typed prompt-stall and closed-agent failures, least-privilege worker control, exact provider launch projections, cleanup, and deletion assertions against obsolete commands and helpers. Run broader `make all` validation because this boundary affects shared delegation. | `Agent Fixes` for raw/decomposed input, direct provider worker launch, caller-substitutable worker profiles, client-side wait choreography, provider-specific prompt logic, widened worker authority, untyped native failures, incomplete deletion, or missing provider direction coverage. `Human Escalation` only when the pinned Herdr contract and live provider behavior irreconcilably conflict. |
| Agent QA browser capability, Browser Use CLI/MCP guidance, or browser evidence workflow | Browser Use remains optional, issue-appropriate, and QA-only. Guidance must not introduce Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, OpenAI/Anthropic/Google provider keys, or new operator-provisioned secrets. QA artifacts for Linear-backed workflows must be attached to Linear; successful Agent QA handoffs to Human Review remain compact, use a tiny `Role note` review summary, and put browser evidence or browser-not-applicable rationale in compact handoff `Work done` or approved Linear attachment metadata. Fallbacks must cover missing local tooling, no local browser, blocked headless execution, and key-requiring agent-mode features. Octo owns any role skill exposure. | Targeted inspection proving no forbidden key or hosted service requirement was introduced, artifact handling still points to Linear, compact `Work done` evidence replaces legacy packet requirements, and fallback behavior is documented. Attempt at least one safe local smoke check when a usable browser path exists, or record a concrete environment-based not-applicable rationale. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when browser-facing acceptance is required and every no-key local path is blocked, or when required source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Octo role skill sources or provider-view projections | Symphony contains no Octo role skill source inventory or exposure manifests. Active Symphony workflow, runtime-specification, validator, and test consumers do not reconstruct Octo registration or activation policy from repository-local skill paths. `EmberAGI/scaling-octo-engine` remains the only editable authority for discovery, registration, activation, role exposure, provider-view generation, and evaluation; Symphony remains responsible for provider-native launch and permission projection of validated skill execution contracts. | Focused repository tests proving both old tracked inventories are absent, every active Symphony source-inventory consumer path is gone, and exact registered execution resources still cross the public Agent Runtime Interface to each provider Adapter without parent-root widening. Run `make all` because the contract changes the repository acceptance surface. | `Agent Fixes` for any reintroduced source, manifest, source-inventory consumer, activation-policy copy, or widened runtime projection. `Human Escalation` only when the Octo source-ownership contract conflicts with a required runtime source. |
| Claude Code role status observability | Claude Code normalized usage and streamed progress feed the same role status snapshot, `/api/v1/state` totals, status logs, and dashboard surfaces used by Codex-backed roles. Final Claude `input_tokens`, `output_tokens`, and `total_tokens` must be folded into runtime totals, and usable streamed Claude assistant/tool/result events should update `last_message` beyond the initial session-start marker. | Deterministic Elixir tests covering orchestrator aggregation of Claude normalized usage/progress and dashboard humanization of Claude stream/result events. Run the targeted status tests at minimum, and run broader `make all` validation when the branch changes shared orchestration, runtime adapter, or dashboard behavior. | `Agent Fixes` for missing aggregation, stale progress text, or insufficient deterministic tests. `Human Escalation` when provider evidence or required source artifacts conflict and the expected status contract cannot be determined locally. |
| Duplicate top-level role-run prevention | Top-level implementer/reviewer/QA/etc. dispatch must be gated by all same-scope Linear-visible structured claim leases plus local process ownership metadata. Claim lease reads must include paginated tracker comments so older same-scope markers cannot be hidden outside the first comment page. App-server launch adapters must pass a scoped non-secret ownership marker into provider process environments so late-spawned detached descendants can be detected without broad command-name or package-name matching. Running issues that leave active dispatch must record process cleanup or quarantine before releasing the same-scope claim lease. Normal worker completion must not mark process ownership cleaned while scoped app-server evidence remains live; it must quarantine and fail closed before the active-state continuation check. Stalled worker restarts with live owned process evidence must surface a quarantined or blocked cleanup state in the retry lease/status payload, including scoped process ownership metadata, instead of looking like an ordinary retry. Same-thread continuation inside one role run must preserve `agent.max_turns` behavior. Retry-by-ID and leaked-claim cleanup regressions must stay covered. Process cleanup/quarantine tests must use synthetic fixtures or controlled local PIDs, never committed production process registries, generated workspaces, or session logs. | Deterministic Elixir tests covering claim lease marker parsing and upsert ownership, paginated claim-lease comment reads, duplicate dispatch refusal, running issue termination or reconciliation releasing the same-scope claim lease after process completion/quarantine, normal worker completion with a live app-server process tree, stalled worker restart with live owned process evidence producing quarantined retry/status metadata, coexistence of different-role/workspace leases and process records without hiding same-scope active owners, expired lease recovery when no live process remains, retry-by-ID preservation, leaked-claim cleanup preservation, snapshot/API lease and process payloads, app-server ownership env propagation for each runtime provider, and synthetic process-leak fixtures showing a live child PID, observed owned process tree, or late-detached process with matching inherited ownership marker blocks replacement dispatch after the recorded parent exits. Run broader `make all` validation because this surface changes shared orchestration and status behavior. | `Agent Fixes` for missing duplicate-refusal, retry/recovery regressions, noisy tracker updates, hidden paginated lease markers, running-termination release gaps, normal-completion cleanup gaps, stalled-live-process status gaps, or insufficient process fixture proof. `Human Escalation` when required tracker/process semantics conflict with issue or ADR sources. |
| Irrecoverable runtime failure classification and escalation | Runtime retry policy uses a provider-neutral failure family before ordinary retry scheduling. Deterministic irrecoverable families immediately stop ordinary retry, update or preserve a blocked/escalated same-scope claim lease, apply or preserve the exact `Human Escalation` tracker label, move the issue to `Human Escalation` when supported, and write a redacted operator-visible note. Repeated identical no-progress failures use the bounded fingerprint and three-consecutive-observation threshold from [Agent Runtime](./agent-runtime.md); elapsed wall-clock time is not an eligibility cap, and the two-minute target is a rapid-loop feedback expectation only. Tracker mutation failures during escalation stay blocked/escalated and do not re-enter ordinary retry. Status API, dashboard, logs, and claim leases distinguish blocked/escalated runtime failures from retry queue entries. Secret-bearing provider payloads, tokens, environment values, full issue bodies, and unbounded process output are never emitted. | Evidence discovery first inventories available Octo-owned role run logs, runtime status logs, claim leases, tracker notes/handoffs, local runtime state, existing redacted incident notes, and bounded non-destructive local Codex/Claude CLI probes where the authenticated CLI contexts are available. Deterministic tests then cover the classifier interface, provider-adapter normalization for Codex and Claude auth failures using redacted fixtures that preserve observed provider/runtime error shapes where durable evidence exists, missing config/tool/CLI, permission denied, invalid protocol, unsupported app-server contract, malformed provider event schema, repeated identical no-progress threshold, immediate escalation after the third consecutive matching observation for both rapid-loop and retry-backoff-spaced observations, reset-condition handling, and transient/rate-limit exclusions, AgentRunner exit normalization, Orchestrator retry suppression and escalation routing, tracker label/state/comment success and failure paths, memory tracker claim leases, status API/dashboard representation, run-log summaries, and redaction of token-like/provider payload fields. Include regression coverage for existing Codex revoked-token, Codex empty-completed-turn, Claude 401/403 auth, generic retryable agent-exit cases, and at least one adapter-boundary test proving synthetic-only fixtures do not bypass real provider parsing. Run broader `make all` validation because this surface changes shared orchestration, tracker, runtime adapter, and status behavior. | `Agent Fixes` for missing families, over-classifying transient failures, under-classifying deterministic human-action failures, retry leakage after an irrecoverable classification, delayed escalation after the third matching observation, duplicate/noisy escalation output, missing status distinction, tracker mutation retry regressions, redaction gaps, skipped provider-evidence discovery, or fixtures that classify already-normalized families without exercising provider/runtime parsing. `Human Escalation` when provider/runtime semantics conflict with durable sources or require operator-owned credential/configuration changes to validate. |

## Truthful Repository Gate

`make all` is the repository acceptance Interface. A successful exit MUST mean
that every command in the declared non-live gate completed successfully; the
gate MUST NOT stay green through warning suppression, blanket coverage
exclusions, or a waiver for pre-existing debt.

The coverage command MUST enforce a documented, non-perfect aggregate
threshold over the full production denominator. Perfect coverage of every
hand-written production Module is explicitly not a pass condition, and no
individual Module is required to be fully covered. `ignore_modules` MUST NOT
exclude repository-owned business, orchestration, runtime, provider-Adapter,
tracker, workspace, HTTP, presentation, or other executable production
behavior; a compiler- or framework-generated Module MAY be excluded only when
it contains no repository-authored executable behavior and the narrow
exclusion is named and justified beside the coverage configuration. The
enforced floor (currently 80% aggregate, measured ~82% at adoption) MAY rise
when real coverage rises; it MUST NOT be met by shrinking the denominator,
swapping in a selective Module set, or adding meaningless line-touch tests.

Dialyzer MUST complete with zero warnings. Typespec, callback, and call-graph
defects MUST be corrected at their owning Module or Interface; filters,
nowarn annotations, and broad type weakening MUST NOT be used to make the gate
appear green.

Coverage and static-analysis repairs MUST be proved through public Interfaces
and real Seams. Tests MUST NOT couple to private implementation structure,
duplicate production policy in test helpers, or replace business collaborators
with meaningless doubles merely to touch lines. Provider and tracker Adapters
MUST use deterministic fixtures at their public boundaries; the non-live gate
MUST remain secret-free and MUST NOT call live providers.

The non-live seal applies to the whole test run, including test application
boot: the suite MUST install its deterministic tracker Adapter and a pinned
non-repository workflow configuration before the application (and its
Orchestrator) starts, so no real tracker request — successful or failed — can
occur in any phase of the gate. The suite MUST measure real tracker HTTP
attempts at the Adapter's single network seam, report the count in the gate
output, and fail on any nonzero count.

The same seal covers the implementer delegation transport: the runtime
resolves its default transport through a public configuration seam, and the
suite MUST install a sealed transport there — at boot and for every test —
that rejects any session start with a typed error before a real herdr server,
session, worker, or provider process can exist. Only an explicit per-call
transport injection may override it. A run whose effective workflow
configuration was bypassed or degraded mid-suite therefore fails fast and
deterministically instead of launching real infrastructure.

Shared mutable configuration seams MUST NOT degrade silently inside the gate:
when a test writes its workflow fixture, the write seam MUST verify the
configuration store observed the just-written content before the test
proceeds, and every between-test window MUST keep the effective workflow
pinned to the non-live boot fixture rather than falling back to the
committed repository workflow.

Test-owned orchestration processes MUST NOT outlive the test that started
them: because a `:normal` exit signal to a non-trapping process is a no-op,
the suite releases orchestrators through a monitored kill that waits for the
process to go down, so a leaked orchestrator can never tick against a later
test's workflow configuration and claim that test's seeded tracker issues.
The boot workflow fixture pins a dormant poll interval so the supervised boot
Orchestrator polls exactly once, at application boot, against the sealed
empty tracker; polling-cadence behavior is proved on per-test orchestrators
with explicit intervals. A test that drives dispatch through retry timers
seeds its tracker issues only after its own orchestrator's startup poll has
completed against an empty tracker.

When EMB-1180 changes a large test or validation file, the affected behavior
MUST be moved progressively into focused ExUnit modules organized by the
production Interface being proved. Restoring this Symphony gate does not own
Octo's `scripts/validate-symphony-config`; documentation-path policy in that
Octo validation script is migrated into focused `uv`/`pytest` tests by
EMB-1162.

The same `make all` contract MUST run on supported Linux and macOS development
and CI environments without platform-specific interpreter paths or tool
assumptions. The gate result MUST NOT depend on ambient terminal geometry:
`make all` succeeds or fails identically in ordinary TTY and non-TTY
executions, and tests that assert rendered terminal output MUST pin an
explicit width instead of inheriting the ambient terminal's.

## Required CI Check Surface

GitHub Actions MUST run the repository's declared non-live gate for every pull
request and every push to `main`. The required `make-all` check MUST use a
GitHub-hosted runner, install the Erlang and Elixir versions declared in
`elixir/mise.toml`, and execute both `make -C elixir all` and
`mix specs.check`. It MUST remain repository-local and secret-free: no external
service, paid infrastructure, or operator-provisioned credential is required
to establish the mechanical gate.

Agent Review and Agent QA MAY cite a successful, current `make-all` pull-request
check as evidence for these mechanical commands. They remain responsible for
confirming that the check applies to the reviewed commit and for evaluating
issue-specific acceptance criteria that the repository gate does not cover.

## Edge Cases

- Browser binary is missing.
- Browser binary exists but cannot start in the role sandbox.
- Browser Use CLI or `uvx` is not installed.
- Local Browser Use stdio MCP starts but cannot connect to a local browser.
- Headless mode is blocked by display, sandbox, or dependency constraints.
- The issue needs authentication or third-party data that Agent QA cannot
  access.
- Browser Use agent mode is installed but refuses to run without an LLM
  provider key.
- Screenshot or recording capture succeeds locally but upload to Linear fails.
- Browser automation is irrelevant to the issue and would add noise rather than
  evidence.

## Constraints

- Keep this domain contract under `docs/specs/` and keep role-specific operational
  policy out of runtime adapter internals.
- Do not add required secrets, hosted browser accounts, hosted browser
  infrastructure, or provider keys to satisfy QA browser validation.
- Do not store durable QA proof only in local files, GitHub comments, object
  stores, or other non-Linear locations for Linear-backed Octo workflows.

## Open Questions About System Behavior

None for EMB-187 intake. If a future Browser Use integration cannot provide
useful local no-key behavior, that limitation should be routed as Human
Escalation or a separate design issue rather than weakening the no-key
contract.

## References

- [Agent Runtime](./agent-runtime.md)
- [Symphony Service](./symphony-service.md)
- [Symphony Handoff Artifacts](./symphony-handoff-artifacts.md)
- [ADR 0001: Provider-Neutral Agent Runtimes](../../adr/0001-provider-neutral-agent-runtimes.md)
- [EMB-187: Add no-key Browser Use capability for Agent QA](https://linear.app/emberai/issue/EMB-187/add-no-key-browser-use-capability-for-agent-qa)
- [EMB-1065: Merge son-of-anton TDD execution contract into the shared tdd skill and restore default-on doctrine](https://linear.app/emberai/issue/EMB-1065/merge-son-of-anton-tdd-execution-contract-into-the-shared-tdd-skill)
- [EMB-1180: Restore a fully green Symphony make all baseline](https://linear.app/emberai/issue/EMB-1180/restore-a-fully-green-symphony-make-all-baseline)
