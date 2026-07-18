# Repository Quality Assurance

Status: Draft v1

Purpose: Define the minimum repository QA contract for durable behavior
changes, shared role skill source acceptance, and the boundary between
Symphony-owned shared skill source and Octo-owned role workflow guidance.

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

- `spec/`
- `spec/adr/`

`CONTEXT.md` MAY be used as domain vocabulary and contextual naming guidance
when present. `spec/` and `spec/adr/` remain the durable QA authority.
`CONTEXT.md` and `docs/adr/` MUST NOT be treated as canonical sources for Octo
QA decisions.

When a QA, review, or handoff instruction requires handoff-artifact spec
context, agents SHOULD read
`spec/domains/symphony-handoff-artifacts.md`. That file is a Symphony-local
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

## Shared Architecture Skill Source

The repository-local `.codex/skills/architecture/` directory is a neutral
shared architecture skill source. It MUST preserve complete upstream-derived
support files needed for architecture vocabulary and deepening:
`LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md`.

The shared skill MUST remain reusable architecture guidance. It may describe
bounded implementation-file evaluation, deepening opportunities, durable
context usage, and architecture vocabulary, but it MUST NOT define Octo role workflow
obligations such as Agent QA state routing, reviewer gates, handoff packet
fields, one-time suggestion markers, PR metadata, workpad rules, or escalation
labels.

The shared skill MUST preserve the source distinction that `CONTEXT.md` is
domain vocabulary/context when present, while `spec/` and `spec/adr/` remain
canonical durable sources. `docs/adr/` is not a canonical durable source.

## Octo QA Workflow Boundary

Octo-specific requirements for when Agent QA uses the shared architecture
skill, how changed-file-only scope is selected, how not-applicable evidence is
recorded, how failed architecture handoffs are marked, how many suggestion sets
may be emitted, how reviewer validation works, and how Agent Fixes consumes QA
architecture feedback are owned by the canonical Octo workflow guidance in
`EmberAGI/scaling-octo-engine`.

Symphony MUST NOT claim that the shared `architecture` skill is automatically
loaded by Octo QA, operator, or console agents. Integration work that exposes
this shared skill to those surfaces must be tracked in the owning Octo issue
and validated in the Octo repository.

## Browser Use Rules And Invariants

- Browser Use may be exposed only to Agent QA guidance, the Agent QA role-skill
  manifest, and QA acceptance workflows. Other Symphony roles must not gain it
  as a general-purpose role skill through this contract.
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

| Change Surface | Required Invariants | Minimum Local Validation | Escalation Route |
| --- | --- | --- | --- |
| Herdr delegation turn submission | Herdr remains the deep module that owns atomic terminal input and provider keyboard-protocol semantics. Symphony submits orchestrator assignments, worker results, and consultation responses through `pane run`; transport Adapters and generated launchers must never reproduce the operation with `send-text`, synthesized keys, escape sequences, or raw PTY writes. Initial turn acknowledgement records the ready revision, treats `working` as active and an advanced idle/done revision as fast completion, and permits exactly one empty `pane run` confirmation only after a bounded settlement window leaves the agent idle at the unchanged revision. Both generated role projections share one inter-agent message Adapter over Herdr's public Interface: healthy working-target single-line steering passes through; a Claude-target multiline paste receives exactly one confirmation; an idle/done/blocked Claude target receives one confirmation only when its revision remains unchanged after settlement; advanced revisions and non-Claude targets are not confirmed. | Deterministic transport contract tests covering the initial orchestrator assignment and both directions of worker consultation; a confirmation-required fixture proving the initial prompt plus one empty `pane run`, no raw input commands, revision advancement, and durable working acknowledgement; executable generated-wrapper tests for both role projections covering multiline working targets, unchanged idle targets, healthy working steering, advanced revisions, non-Claude targets, command failure, and no repeated confirmation; lifecycle tests covering fast completion, working acknowledgement, and stale-idle refusal; and bounded isolated live Claude tests for fresh-session compact/large-paste prompts plus multiline inter-agent result/follow-up delivery without touching the operator's default Herdr server. Run broader `make all` validation because this boundary affects shared delegation. | `Agent Fixes` for provider-specific PTY input logic, duplicated wrapper policy, raw/decomposed submission, repeated confirmation, missing revision checks, missing direction coverage, or stale-idle completion. `Human Escalation` only when the pinned Herdr contract and a live provider behavior irreconcilably conflict. |
| Agent QA browser capability, Browser Use CLI/MCP guidance, or browser evidence workflow | Browser Use remains optional, issue-appropriate, QA-only, and exposed only through Agent QA guidance or the Agent QA role manifest. Guidance must not introduce Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, OpenAI/Anthropic/Google provider keys, or new operator-provisioned secrets. QA artifacts for Linear-backed workflows must be attached to Linear; successful Agent QA handoffs to Human Review remain compact, use a tiny `Role note` review summary, and put browser evidence or browser-not-applicable rationale in compact handoff `Work done` or approved Linear attachment metadata. Fallbacks must cover missing local Browser Use CLI/MCP tooling, no local browser, blocked headless execution, and key-requiring agent-mode features. | Targeted inspection proving the Browser Use skill is exposed only to Agent QA, no forbidden key or hosted service requirement was introduced, artifact handling still points to Linear, compact `Work done` evidence replaces legacy packet requirements, and fallback behavior is documented. Attempt at least one safe local smoke check when a usable browser and local Browser Use path exist, or record a concrete environment-based not-applicable rationale. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when browser-facing acceptance is required and every no-key local path is blocked, or when required source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Shared Symphony role skills, role skill manifests, or `CODEX_HOME` skill materialization source | Shared skill directories remain complete, locally committed, discoverable by the intended role, and isolated from roles that should not receive them. Upstream-derived skills must name their source artifacts, keep internal links local, document omitted upstream siblings when only part of an upstream pack is localized, and preserve Octo workflow authority for Linear repository metadata, issue branches, state transitions, PR ownership, Codex Workpad, Symphony Handoff, validation, and `Human Escalation` routing. Skill guidance must not impose language, package-manager, frontend, or workflow conventions on unrelated repositories or issues without durable repository or issue signals. | Targeted inspection or tests proving every manifest path resolves, every exposed skill has a `SKILL.md`, full upstream directories named by the issue are present, internal Markdown links resolve to committed local files, implementer-only skills are absent from non-implementer manifests by default, activation conditions are documented, and Octo workflow-boundary language remains present. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when required upstream source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Claude Code role status observability | Claude Code normalized usage and streamed progress feed the same role status snapshot, `/api/v1/state` totals, status logs, and dashboard surfaces used by Codex-backed roles. Final Claude `input_tokens`, `output_tokens`, and `total_tokens` must be folded into runtime totals, and usable streamed Claude assistant/tool/result events should update `last_message` beyond the initial session-start marker. | Deterministic Elixir tests covering orchestrator aggregation of Claude normalized usage/progress and dashboard humanization of Claude stream/result events. Run the targeted status tests at minimum, and run broader `make all` validation when the branch changes shared orchestration, runtime adapter, or dashboard behavior. | `Agent Fixes` for missing aggregation, stale progress text, or insufficient deterministic tests. `Human Escalation` when provider evidence or required source artifacts conflict and the expected status contract cannot be determined locally. |
| Duplicate top-level role-run prevention | Top-level implementer/reviewer/QA/etc. dispatch must be gated by all same-scope Linear-visible structured claim leases plus local process ownership metadata. Claim lease reads must include paginated tracker comments so older same-scope markers cannot be hidden outside the first comment page. App-server launch adapters must pass a scoped non-secret ownership marker into provider process environments so late-spawned detached descendants can be detected without broad command-name or package-name matching. Running issues that leave active dispatch must record process cleanup or quarantine before releasing the same-scope claim lease. Normal worker completion must not mark process ownership cleaned while scoped app-server evidence remains live; it must quarantine and fail closed before the active-state continuation check. Stalled worker restarts with live owned process evidence must surface a quarantined or blocked cleanup state in the retry lease/status payload, including scoped process ownership metadata, instead of looking like an ordinary retry. Same-thread continuation inside one role run must preserve `agent.max_turns` behavior. Retry-by-ID and leaked-claim cleanup regressions must stay covered. Process cleanup/quarantine tests must use synthetic fixtures or controlled local PIDs, never committed production process registries, generated workspaces, or session logs. | Deterministic Elixir tests covering claim lease marker parsing and upsert ownership, paginated claim-lease comment reads, duplicate dispatch refusal, running issue termination or reconciliation releasing the same-scope claim lease after process completion/quarantine, normal worker completion with a live app-server process tree, stalled worker restart with live owned process evidence producing quarantined retry/status metadata, coexistence of different-role/workspace leases and process records without hiding same-scope active owners, expired lease recovery when no live process remains, retry-by-ID preservation, leaked-claim cleanup preservation, snapshot/API lease and process payloads, app-server ownership env propagation for each runtime provider, and synthetic process-leak fixtures showing a live child PID, observed owned process tree, or late-detached process with matching inherited ownership marker blocks replacement dispatch after the recorded parent exits. Run broader `make all` validation because this surface changes shared orchestration and status behavior. | `Agent Fixes` for missing duplicate-refusal, retry/recovery regressions, noisy tracker updates, hidden paginated lease markers, running-termination release gaps, normal-completion cleanup gaps, stalled-live-process status gaps, or insufficient process fixture proof. `Human Escalation` when required tracker/process semantics conflict with issue or ADR sources. |
| Irrecoverable runtime failure classification and escalation | Runtime retry policy uses a provider-neutral failure family before ordinary retry scheduling. Deterministic irrecoverable families immediately stop ordinary retry, update or preserve a blocked/escalated same-scope claim lease, apply or preserve the exact `Human Escalation` tracker label, move the issue to `Human Escalation` when supported, and write a redacted operator-visible note. Repeated identical no-progress failures use the bounded fingerprint and three-consecutive-observation threshold from [Agent Runtime](./agent-runtime.md); elapsed wall-clock time is not an eligibility cap, and the two-minute target is a rapid-loop feedback expectation only. Tracker mutation failures during escalation stay blocked/escalated and do not re-enter ordinary retry. Status API, dashboard, logs, and claim leases distinguish blocked/escalated runtime failures from retry queue entries. Secret-bearing provider payloads, tokens, environment values, full issue bodies, and unbounded process output are never emitted. | Evidence discovery first inventories available Octo-owned role run logs, runtime status logs, claim leases, tracker notes/handoffs, local runtime state, existing redacted incident notes, and bounded non-destructive local Codex/Claude CLI probes where the authenticated CLI contexts are available. Deterministic tests then cover the classifier interface, provider-adapter normalization for Codex and Claude auth failures using redacted fixtures that preserve observed provider/runtime error shapes where durable evidence exists, missing config/tool/CLI, permission denied, invalid protocol, unsupported app-server contract, malformed provider event schema, repeated identical no-progress threshold, immediate escalation after the third consecutive matching observation for both rapid-loop and retry-backoff-spaced observations, reset-condition handling, and transient/rate-limit exclusions, AgentRunner exit normalization, Orchestrator retry suppression and escalation routing, tracker label/state/comment success and failure paths, memory tracker claim leases, status API/dashboard representation, run-log summaries, and redaction of token-like/provider payload fields. Include regression coverage for existing Codex revoked-token, Codex empty-completed-turn, Claude 401/403 auth, generic retryable agent-exit cases, and at least one adapter-boundary test proving synthetic-only fixtures do not bypass real provider parsing. Run broader `make all` validation because this surface changes shared orchestration, tracker, runtime adapter, and status behavior. | `Agent Fixes` for missing families, over-classifying transient failures, under-classifying deterministic human-action failures, retry leakage after an irrecoverable classification, delayed escalation after the third matching observation, duplicate/noisy escalation output, missing status distinction, tracker mutation retry regressions, redaction gaps, skipped provider-evidence discovery, or fixtures that classify already-normalized families without exercising provider/runtime parsing. `Human Escalation` when provider/runtime semantics conflict with durable sources or require operator-owned credential/configuration changes to validate. |

Symphony MUST NOT expose a root shared skill named `linear` for raw Linear
GraphQL usage, schema introspection, Linear comment mutation recipes, or
`linear_graphql` upload workflows. Raw Linear tool contracts may remain in
Symphony service/runtime specifications, but Octo role workflow guidance and
repo-owned Linear helper skills must not be shadowed by a Symphony
`.codex/skills/linear` source.

Repository changes that add, rename, or remove shared Linear helper skill
sources MUST validate that no `.codex/skills/linear/SKILL.md` file is present,
that no role manifest exposes a shared skill named `linear`, and that unrelated
shared skills remain present.

Repository changes that add or materially change the shared `to-issues` skill
source MUST validate that:

- The localized shared skill directory `.codex/skills/to-issues/` resolves and
  includes the complete upstream `skills/engineering/to-issues/` file set named
  by the owning issue, plus local source attribution.
- The localized skill keeps internal Markdown links local and resolvable.
- The localized skill preserves the upstream breakdown technique: independently
  grabbable tracer-bullet vertical slices, HITL/AFK classification, real
  dependency-only blockers, and no parent issue closure merely because child
  issues were created.
- The localized skill records that repository metadata, Linear states, labels,
  `sortOrder`, handoffs, parent/child issue creation, native relation policy,
  validation, PR ownership, and Human Escalation routing remain owned by the
  invoking Octo/Symphony workflow.
- The skill is not exposed to unrelated roles by default unless a role manifest
  explicitly scopes that exposure.

Repository changes that add or materially change shared architecture skill
source behavior MUST validate that:

- The localized shared skill is named `architecture`, not `qa-architecture`.
- The localized `architecture` skill directory includes complete
  upstream-derived support files for language, deepening, and interface-design
  guidance.
- The shared skill remains reusable architecture guidance and does not embed
  Agent QA state routing, reviewer gates, handoff packet fields, one-time
  suggestion marker rules, PR metadata, workpad rules, or escalation-label
  policy.
- `CONTEXT.md` can be preserved as useful domain vocabulary, while `spec/` and
  `spec/adr/` are canonical durable context paths.
- `docs/adr/` is not treated as a canonical durable source.
- The repository includes a thin Symphony-local handoff-artifacts consumer
  reference that identifies Octo's source-of-truth spec, records local deltas,
  and guards against silently forking the Octo contract.
- Symphony workflow/spec guidance records that Octo role exposure and
  QA/reviewer/Agent Fixes architecture workflow behavior are owned by
  `EmberAGI/scaling-octo-engine`.
- Validation guards against reintroducing the QA-specific skill name or
  embedding Octo QA workflow obligations in the shared skill.

## EMB-187 Agent QA Browser Use

EMB-187 exposes a local Browser Use skill only for Agent QA through
`.codex/role-skills/qa.json` and `.codex/skills/browser-use/`.

Agent QA may use the skill only when browser-facing validation, screenshots,
page-state inspection, form-flow verification, or manual acceptance evidence is
relevant to the owning issue. Preferred no-key paths are Browser Use CLI
commands against a local browser session and local stdio MCP via
`uvx --from 'browser-use[cli]' browser-use --mcp`.
Browser Use CLI flows must derive numeric element indices from
`browser-use state`; use `click <index>` for indexed clicks,
`input <index> "text"` for field filling, and `type "text"` only after the
target field is focused.

Provider-keyed autonomous Browser Use agent modes and Browser Use Cloud remain
outside this issue's accepted contract.

## EMB-186 Implementer Skill Pack

EMB-186 localizes upstream-derived implementer role skills under
`.codex/skills/` and describes default role exposure in
`.codex/role-skills/implementer.json`.

The localized skill pack must include:

- Matt Pocock `tdd` from `mattpocock/skills@b843cb5`.
- Anthropic `frontend-design` from `anthropics/skills@d230a6d`.
- Son of Anton `.rulesync` skills `nodejs`, `pnpm-patching`, `pnpm`,
  `python`, and `typescript` from `EmberAGI/son-of-anton@faf1d5a`.

The implementer manifest must expose these skills only to the implementer role
by default. Reviewer, QA, landing, and backlog-processor exposure requires a
future issue that updates the role contract and validation.

The shared `tdd` skill is the canonical home for implementer red-green-refactor
execution-loop doctrine. It must describe TDD as the primary development loop
for implementation work when the active role workflow requires it, while Octo
role workflows own activation, routing, handoff evidence, and submodule
delivery. The skill's execution contract should favor small behavior slices,
current-slice tracer tests at repo-declared public boundaries, targeted-first
validation, bounded output, and repo-declared test tiers/task runners without
hardcoding repository-specific Vitest, Turbo/Nx, secret, timing, or placement
details. Role-skill exposure metadata should keep `tdd` discoverable for
implementers without preserving an obsolete EMB-97/explicit-request-only
activation list as the full trigger policy.

The shared `tdd` skill must have one execution loop. It may preserve upstream
behavior-through-public-interface philosophy and links to upstream support
docs, but must not duplicate an upstream Workflow section beside a separate
local contract. The five upstream support docs in `.codex/skills/tdd/` must
remain byte-pristine against the recorded upstream pin unless a future issue
intentionally changes the source relationship.

Shared TDD doctrine must state that e2e is not the red-green loop; exact tier
budgets, triggers, placement, owners, and gate commands come from target repo
specs. Skill package behavior may use realistic prompt-based evals and human
review when RED/GREEN unit tests are the wrong surface.

Frontend and language/package-manager skills must activate only from durable
issue or repository signals and must not override existing product specs, ADRs,
framework conventions, component libraries, accessibility requirements, or
package-manager choices. TypeScript, pnpm, and Node.js guidance may align with
the TDD loop by pointing agents to repo-declared placement, task runner,
affected-cache, validation, and output-control contracts, but test taxonomy and
workflow activation must remain in the appropriate skill or role workflow.

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

- Keep this domain contract under `spec/` and keep role-specific operational
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
- [ADR 0001: Provider-Neutral Agent Runtimes](../adr/0001-provider-neutral-agent-runtimes.md)
- [EMB-187: Add no-key Browser Use capability for Agent QA](https://linear.app/emberai/issue/EMB-187/add-no-key-browser-use-capability-for-agent-qa)
- [EMB-1065: Merge son-of-anton TDD execution contract into the shared tdd skill and restore default-on doctrine](https://linear.app/emberai/issue/EMB-1065/merge-son-of-anton-tdd-execution-contract-into-the-shared-tdd-skill)
- [EMB-1180: Restore a fully green Symphony make all baseline](https://linear.app/emberai/issue/EMB-1180/restore-a-fully-green-symphony-make-all-baseline)
