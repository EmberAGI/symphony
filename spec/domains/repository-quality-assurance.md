# Repository Quality Assurance

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

## Rules And Invariants

- Browser Use may be exposed only to Agent QA guidance, the Agent QA role-skill
  manifest, and QA acceptance workflows. Other Symphony roles must not gain it
  as a general-purpose role skill through this contract.
- Browser Use must remain optional and issue-appropriate. Agent QA should use
  it when browser-facing validation, screenshots, page-state inspection,
  form-flow verification, or manual acceptance evidence materially improves QA.
- Browser Use must not require `BROWSER_USE_API_KEY`, Browser Use Cloud, hosted
  browser infrastructure, or any new operator-provisioned API secret.
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
- Browser automation must respect the operational readiness posture of the
  role environment. If no usable browser is available, headless execution is
  blocked, dependencies are absent, sandbox policy prevents launch, or a desired
  feature needs a forbidden key, Agent QA must use the documented fallback path
  instead of silently weakening validation.

## Interfaces And Contracts

Agent QA browser-facing validation should record:

- why browser automation was relevant or why it was not applicable;
- the local tool path used, such as Browser Use CLI, local Browser Use stdio
  MCP, existing Playwright/browser tooling, or manual inspection;
- the pages, states, or flows inspected;
- the QA artifacts generated and where they were attached in Linear;
- any fallback chosen and the reason for that fallback.

When Agent QA successfully moves a Linear-backed issue to Human Review, that
record must appear in the Human Review Packet inside the `## Symphony Handoff`
comment. The packet must preserve the complete successful QA-to-`Human Review`
section shape: Review Focus, Executive Summary, Action Log, Validation Matrix,
Artifact Index, Environment And Provenance, Known Limitations, and Merge
Readiness. Browser-facing checks belong in the packet's validation matrix,
mapped to the issue acceptance criteria or repo-level minimum acceptance
results they support. Browser evidence belongs in the packet's artifact index,
with each Linear attachment or Linear comment location named and described.

If Agent QA creates no external browser artifact, the artifact index is still
required. It must state that no browser artifact was useful or possible and
give the rationale, such as no browser-facing acceptance surface, no usable
local browser, blocked headless execution, sandbox launch restrictions, missing
local Browser Use CLI/MCP tooling, or a desired Browser Use path that required
a forbidden key or hosted service.

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

## Minimum Acceptance Suite

| Change Surface | Required Invariants | Minimum Local Validation | Escalation Route |
| --- | --- | --- | --- |
| Agent QA browser capability, Browser Use CLI/MCP guidance, or browser evidence workflow | Browser Use remains optional, issue-appropriate, QA-only, and exposed only through Agent QA guidance or the Agent QA role manifest. Guidance must not introduce Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, OpenAI/Anthropic/Google provider keys, or new operator-provisioned secrets. QA artifacts for Linear-backed workflows must be attached to Linear, successful Agent QA handoffs to Human Review must include the complete Human Review Packet section shape, browser evidence or a browser-not-applicable rationale in the Artifact Index, and browser-facing checks in the Validation Matrix. Fallbacks must cover missing local Browser Use CLI/MCP tooling, no local browser, blocked headless execution, and key-requiring agent-mode features. | Targeted inspection proving the Browser Use skill is exposed only to Agent QA, no forbidden key or hosted service requirement was introduced, artifact handling still points to Linear, and fallback behavior is documented. Attempt at least one safe local smoke check when a usable browser and local Browser Use path exist, or record a concrete environment-based not-applicable rationale. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when browser-facing acceptance is required and every no-key local path is blocked, or when required source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |
| Shared Symphony role skills, role skill manifests, or `CODEX_HOME` skill materialization source | Shared skill directories remain complete, locally committed, discoverable by the intended role, and isolated from roles that should not receive them. Upstream-derived skills must name their source artifacts, keep internal links local, document omitted upstream siblings when only part of an upstream pack is localized, and preserve Octo workflow authority for Linear repository metadata, issue branches, state transitions, PR ownership, Codex Workpad, Symphony Handoff, validation, and `Human Escalation` routing. Skill guidance must not impose language, package-manager, frontend, or workflow conventions on unrelated repositories or issues without durable repository or issue signals. | Targeted inspection or tests proving every manifest path resolves, every exposed skill has a `SKILL.md`, full upstream directories named by the issue are present, internal Markdown links resolve to committed local files, implementer-only skills are absent from non-implementer manifests by default, activation conditions are documented, and Octo workflow-boundary language remains present. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when required upstream source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |

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

TDD is mandatory for EMB-97 child work that names TDD and for future issues
that explicitly ask for TDD, red-green-refactor, test-first implementation, or
integration-test-first development. Frontend and language/package-manager
skills must activate only from durable issue or repository signals and must not
override existing product specs, ADRs, framework conventions, component
libraries, accessibility requirements, or package-manager choices.

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
- Browser automation is irrelevant to the issue and would add noise rather
  than evidence.

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
- [Provider-Neutral Agent Runtimes ADR](../adr/0001-provider-neutral-agent-runtimes.md)
- [EMB-187: Add no-key Browser Use capability for Agent QA](https://linear.app/emberai/issue/EMB-187/add-no-key-browser-use-capability-for-agent-qa)
