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
| Agent QA browser capability, Browser Use CLI/MCP guidance, or browser evidence workflow | Browser Use remains optional, issue-appropriate, QA-only, and exposed only through Agent QA guidance or the Agent QA role manifest. Guidance must not introduce Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, OpenAI/Anthropic/Google provider keys, or new operator-provisioned secrets. QA artifacts for Linear-backed workflows must be attached to Linear; successful Agent QA handoffs to Human Review remain compact, use a tiny `Role note` review summary, and put browser evidence or browser-not-applicable rationale in compact handoff `Work done` or approved Linear attachment metadata. Fallbacks must cover missing local Browser Use CLI/MCP tooling, no local browser, blocked headless execution, and key-requiring agent-mode features. | Targeted inspection proving the Browser Use skill is exposed only to Agent QA, no forbidden key or hosted service requirement was introduced, artifact handling still points to Linear, compact `Work done` evidence replaces legacy packet requirements, and fallback behavior is documented. Attempt at least one safe local smoke check when a usable browser and local Browser Use path exist, or record a concrete environment-based not-applicable rationale. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when browser-facing acceptance is required and every no-key local path is blocked, or when required source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Shared Symphony role skills, role skill manifests, or `CODEX_HOME` skill materialization source | Shared skill directories remain complete, locally committed, discoverable by the intended role, and isolated from roles that should not receive them. Upstream-derived skills must name their source artifacts, keep internal links local, document omitted upstream siblings when only part of an upstream pack is localized, and preserve Octo workflow authority for Linear repository metadata, issue branches, state transitions, PR ownership, Codex Workpad, Symphony Handoff, validation, and `Human Escalation` routing. Skill guidance must not impose language, package-manager, frontend, or workflow conventions on unrelated repositories or issues without durable repository or issue signals. | Targeted inspection or tests proving every manifest path resolves, every exposed skill has a `SKILL.md`, full upstream directories named by the issue are present, internal Markdown links resolve to committed local files, implementer-only skills are absent from non-implementer manifests by default, activation conditions are documented, and Octo workflow-boundary language remains present. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when required upstream source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Claude Code role status observability | Claude Code normalized usage and streamed progress feed the same role status snapshot, `/api/v1/state` totals, status logs, and dashboard surfaces used by Codex-backed roles. Final Claude `input_tokens`, `output_tokens`, and `total_tokens` must be folded into runtime totals, and usable streamed Claude assistant/tool/result events should update `last_message` beyond the initial session-start marker. | Deterministic Elixir tests covering orchestrator aggregation of Claude normalized usage/progress and dashboard humanization of Claude stream/result events. Run the targeted status tests at minimum, and run broader `make all` validation when the branch changes shared orchestration, runtime adapter, or dashboard behavior. | `Agent Fixes` for missing aggregation, stale progress text, or insufficient deterministic tests. `Human Escalation` when provider evidence or required source artifacts conflict and the expected status contract cannot be determined locally. |
| Duplicate top-level role-run prevention | Top-level implementer/reviewer/QA/etc. dispatch must be gated by all same-scope Linear-visible structured claim leases plus local process ownership metadata. Claim lease reads must include paginated tracker comments so older same-scope markers cannot be hidden outside the first comment page. App-server launch adapters must pass a scoped non-secret ownership marker into provider process environments so late-spawned detached descendants can be detected without broad command-name or package-name matching. Running issues that leave active dispatch must record process cleanup or quarantine before releasing the same-scope claim lease. Normal worker completion must not mark process ownership cleaned while scoped app-server evidence remains live; it must quarantine and fail closed before the active-state continuation check. Stalled worker restarts with live owned process evidence must surface a quarantined or blocked cleanup state in the retry lease/status payload, including scoped process ownership metadata, instead of looking like an ordinary retry. Same-thread continuation inside one role run must preserve `agent.max_turns` behavior. Retry-by-ID and leaked-claim cleanup regressions must stay covered. Process cleanup/quarantine tests must use synthetic fixtures or controlled local PIDs, never committed production process registries, generated workspaces, or session logs. | Deterministic Elixir tests covering claim lease marker parsing and upsert ownership, paginated claim-lease comment reads, duplicate dispatch refusal, running issue termination or reconciliation releasing the same-scope claim lease after process completion/quarantine, normal worker completion with a live app-server process tree, stalled worker restart with live owned process evidence producing quarantined retry/status metadata, coexistence of different-role/workspace leases and process records without hiding same-scope active owners, expired lease recovery when no live process remains, retry-by-ID preservation, leaked-claim cleanup preservation, snapshot/API lease and process payloads, app-server ownership env propagation for each runtime provider, and synthetic process-leak fixtures showing a live child PID, observed owned process tree, or late-detached process with matching inherited ownership marker blocks replacement dispatch after the recorded parent exits. Run broader `make all` validation because this surface changes shared orchestration and status behavior. | `Agent Fixes` for missing duplicate-refusal, retry/recovery regressions, noisy tracker updates, hidden paginated lease markers, running-termination release gaps, normal-completion cleanup gaps, stalled-live-process status gaps, or insufficient process fixture proof. `Human Escalation` when required tracker/process semantics conflict with issue or ADR sources. |

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

For pnpm and TypeScript monorepo guidance, shared skills must distinguish
workspace linking from package interface resolution. A pnpm workspace
dependency selects the local package, but the package's `exports`, `main`,
`types`, `files`, and publish metadata still define the interface that local
consumers, tests, bundlers, and packed artifacts observe. The skills should
therefore treat package manifests as architecture: they define a Module
interface, caller expectations, resolver behavior, validation cost, and
publish/runtime adapter behavior.

When a target repository uses pnpm workspaces and TypeScript, shared guidance
should prefer source-first local workspace resolution for private/internal
packages when the repository's TypeScript, Node, Vitest, Vite, Next, tsx,
ESLint, and build tooling can consume that source consistently. Packages that
must publish, pack, or run as built Node artifacts may expose `dist`, but the
skill should recommend explicit publish-time metadata such as `publishConfig`
or a deliberately consistent conditional-export/custom-condition strategy
instead of making all local workspace consumers rely on stale or repeatedly
rebuilt `dist` artifacts.

pnpm workspace signals alone are enough for generic pnpm guidance such as
filters, package-local scripts, and workspace dependency hygiene. The
source-first TypeScript resolver and package-manifest doctrine requires durable
pnpm workspace signals plus TypeScript or runtime resolver signals.

Package scripts should remain package-local. A package's `lint`, `test`,
`build`, and optional `check` aggregate should validate that package's own
surface and must not hide broad sibling dependency rebuilds behind lifecycle
hooks such as `prelint`, `pretest`, or `prebuild` without a documented target
repository reason. Root or task-runner orchestration owns dependency graph
selection, ordering, affected/default/full validation tiers, and timing
evidence. Single-package convenience hooks such as `predev` or `prestart` may
remain useful in a target repository, but the skills must distinguish that
developer convenience from root recursive validation.

The shared pnpm skill should recommend `check` as the conventional
package-level aggregate when a target repository wants one. It must not teach
`pnpm run all` as an Octo validation convention, and it must not treat
`make all` as universal across package managers, languages, or repository
structures. Repository-declared commands remain authoritative: pnpm filters,
changed-plus-dependent selection, selected package evidence, and elapsed timing
are the cache-free baseline before proposing Turbo, Nx, Rush, another
task-result cache, or durable helper scripts.

Skill changes in this area must create or extend a durable prompt eval or
fixture surface for slow pnpm/TypeScript monorepo validation scenarios. When no
repo-local skill eval surface exists, the implementation should add a minimal
one following the skill-creator pattern: realistic prompts, baseline or
old-skill comparison when useful, objective assertions or grading records,
aggregate benchmark evidence, and reviewable outputs. Human review may
supplement that evidence, but it is not a replacement for the durable eval or
fixture. The eval surface should be scoped to proving this pnpm/TypeScript
monorepo doctrine, not to building a general-purpose skill-eval platform, but
its layout and helper choices should be reusable enough for future shared
skill evals to copy or extend.
Baseline or old-skill comparison is not mandatory for this doctrine update;
updated-skill pass/fail evidence against the explicit rubric is the required
bar. Add comparison artifacts only when they clarify the regression risk
without forcing new comparison infrastructure into the issue.

These evals should stay lightweight. They should use static repo-dossier
fixtures and concept-bucket grading rather than constructing a full repository
or running package installs, builds, or tests. A positive dossier may include
only the representative snippets needed for judgment, such as
`pnpm-workspace.yaml`, root and package `package.json` excerpts, a local
package with `exports` or `types` pointing at `dist`, a consumer import,
TypeScript/runtime resolver clues, lifecycle scripts, and timing notes. The
grader should evaluate concepts and ordering instead of brittle exact prose.
The required positive eval should exercise the combined pnpm workspace plus
TypeScript/runtime resolver and package-manifest scenario because that is the
failure mode this doctrine corrects. Separate pnpm-only or TypeScript-only
evals are optional when they are cheap and clarify behavior, but they are not
required for this issue's durable evidence.
The eval surface does not need a fully deterministic grader. Deterministic
assertions should be used where they are cheap and useful, such as fixture
shape or required output sections, while recommendation quality may be graded
through an explicit rubric, saved grading records, and human-assisted or
model-assisted review evidence. The rubric and evidence must be durable enough
for reviewers and QA to verify why each eval passed or failed.
The evidence should prove agents recommend the manifest and source-resolution
architecture before falling back to command-level timing tweaks. The eval
surface should also include at least one negative or control prompt for a
repository without durable pnpm workspace plus TypeScript or runtime resolver
signals, proving the skills do not impose pnpm, TypeScript, source-first
workspace, or package-manifest refactor guidance where those recommendations
are not selected by the target repository.

Ideal monorepo guidance should also cover strict workspace dependency
intentions such as `workspace:*` or `workspace:^`, pnpm catalogs for shared
external versions, clear package taxonomy such as `apps/*`, `packages/*`,
`services/*`, and `tools/*`, explicit generated-artifact contracts, CI tiers
for affected/default/full/regression/live validation, and timing budgets as
product expectations. These recommendations are still conditional on durable
repository signals and must not impose pnpm or TypeScript conventions on
repositories that have selected other tools.

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
- [EMB-1117: Improve pnpm and TypeScript monorepo skills for source-first workspace validation](https://linear.app/emberai/issue/EMB-1117/prd-improve-pnpm-and-typescript-monorepo-skills-for-source-first)
