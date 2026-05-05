# Repository Quality Assurance

## Intended behavior

Repository QA workflows give Agent QA enough evidence-gathering capability to
validate issue-appropriate runtime, UI, and browser-facing behavior without
adding external hosted browser services or new operator-provisioned API secrets.

Browser Use is an optional Agent QA capability only. It is not a general
Symphony role skill, not a requirement for implementer/reviewer/landing roles,
and not a release gate for non-browser issues.

## Domain concepts

**Agent QA**: The Symphony role responsible for verifying that an implementation
meets the owning issue's acceptance criteria before the work is treated as
ready for human/operator review.

**Browser Use**: A QA-owned browser-facing validation capability. In this
domain, the name means local, deterministic browser inspection or automation
that can collect useful evidence without external provider keys. It does not
mean Browser Use Cloud, a hosted browser service, or an autonomous LLM browser
agent that requires an OpenAI, Anthropic, Google, or similar provider key.

**QA artifact**: Evidence generated during QA, such as screenshots, page-state
summaries, form-flow notes, command output, logs, or short recordings.

## Rules and invariants

- Browser Use may be exposed only to Agent QA guidance and QA acceptance
  workflows. Other Symphony roles must not gain it as a general-purpose role
  skill through this contract.
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

## Interfaces/contracts

Agent QA browser-facing validation should record:

- why browser automation was relevant or why it was not applicable;
- the local tool path used, such as an existing Playwright setup, a browser CLI,
  a local no-key Browser Use controller, or manual inspection;
- the pages, states, or flows inspected;
- the QA artifacts generated and where they were attached in Linear;
- any fallback chosen and the reason for that fallback.

When Agent QA successfully moves a Linear-backed issue to Human Review, that
record must appear in the Human Review Packet inside the `## Symphony Handoff`
comment. Browser-facing checks belong in the packet's validation matrix, mapped
to the issue acceptance criteria or repo-level minimum acceptance results they
support. Browser evidence belongs in the packet's artifact index, with each
Linear attachment or Linear comment location named and described.

If Agent QA creates no external browser artifact, the artifact index is still
required. It must state that no browser artifact was useful or possible and
give the rationale, such as no browser-facing acceptance surface, no usable
local browser, blocked headless execution, sandbox launch restrictions, or a
desired Browser Use path that required a forbidden key or hosted service.

Allowed local no-key paths include:

- existing repository Playwright or browser test tooling;
- deterministic local browser CLI automation when a browser binary is already
  available in the role environment;
- local Browser Use primitives that do not request hosted browser services and
  do not request an LLM provider key;
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

## Minimum acceptance suite

Changes that add, remove, or materially change Agent QA browser capability must
validate all of the following before handoff:

- no external API-key or hosted-browser requirement was introduced;
- Browser Use remains QA-only and was not promoted to a general role skill;
- QA guidance requires useful artifacts to be attached to Linear for
  Linear-backed workflows;
- successful Agent QA handoffs to Human Review require browser evidence or a
  browser-not-applicable rationale in the Human Review Packet's Artifact Index,
  and browser-facing checks in the Validation Matrix;
- fallback paths cover no local browser, blocked headless execution, and
  key-requiring agent-mode features;
- operational readiness behavior is explicit: blocked local execution falls
  back to manual inspection, existing browser tooling, not-applicable rationale,
  or Human Escalation;
- at least one safe local smoke check was attempted, or a concrete
  environment-based not-applicable rationale was recorded.

## Edge cases

- Browser binary is missing.
- Browser binary exists but cannot start in the role sandbox.
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

## Open questions about system behavior

None for EMB-187 intake. If a future Browser Use integration cannot provide
useful local no-key behavior, that limitation should be routed as Human
Escalation or a separate design issue rather than weakening the no-key
contract.

## Decision log or links to ADRs

- EMB-187: Agent QA may use Browser Use only as an optional local/no-key
  evidence capture capability. Provider-keyed autonomous agent modes and hosted
  browser services are outside this issue's accepted contract.

## References to source issues

- [EMB-187: Add no-key Browser Use capability for Agent QA](https://linear.app/emberai/issue/EMB-187/add-no-key-browser-use-capability-for-agent-qa)
