---
tracker:
  kind: linear
  project_slug: "symphony-0c79b11b75ea"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
notifications:
  telegram:
    bot_token: $TELEGRAM_BOT_TOKEN
    chat_id: $TELEGRAM_CHAT_ID
    # Optional forum topic id. Omit this, or set it to 1, for Telegram's General topic.
    message_thread_id: $TELEGRAM_MESSAGE_THREAD_ID
    events:
      - human_escalation
      - agent_failed
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/openai/symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    cd elixir && mise exec -- mix workspace.before_remove
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
# Runtime selection. Codex is the default and reference runtime; set the
# provider to claude_code to run role turns through the first-party Claude Code
# shim (claude-app-server) instead. Codex-backed workflows are unchanged when
# this block is omitted.
# agent_runtime:
#   provider: claude_code
# Claude Code shim configuration (used when agent_runtime.provider is
# claude_code). Authentication is operator-managed Claude subscription OAuth on
# the role host; no API key is read or stored here. Unattended runs use
# bypassPermissions and must stay non-interactive (ADR 0002). no_thinking maps
# to MAX_THINKING_TOKENS=0 (the verified Claude Code no-thinking invocation;
# Fable 5 cannot disable thinking and is rejected at config validation).
# claude_code:
#   command: claude
#   model: sonnet
#   effort: high
#   no_thinking: true
#   permission_mode: bypassPermissions
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record the blocker in a compact `## Symphony Handoff` and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Prerequisite: Linear MCP or `linear_graphql` tool is available

The agent should be able to talk to Linear, either via a configured Linear MCP server or injected `linear_graphql` tool. If none are present, stop and ask the user to configure Linear.

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by reading the Linear issue body, any existing legacy `## Codex Workpad` as read-only context, the `## Symphony Handoff` trail, PR attachments, and relevant branch-local specs or ADRs before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, acceptance criteria, links).
- Treat the issue body, branch, PR, legacy read-only Workpad context, compact handoff trail, and optional observability artifacts as the source of truth for continuation.
- Do not create or update Linear `## Codex Workpad` comments. Existing Workpads are historical context only.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: execute it before considering the work complete and summarize the result in compact handoff `Work done` or linked evidence.
- When meaningful out-of-scope improvements are discovered during execution,
  file a separate Linear issue instead of expanding scope. The follow-up issue
  must include a clear title, description, and acceptance criteria, be placed in
  `Backlog`, be assigned to the same project as the current issue, link the
  current issue as `related`, and use `blockedBy` when the follow-up depends on
  the current issue.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.
- Use the blocked-access escape hatch only for true external blockers (missing required tools/auth) after exhausting documented fallbacks.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.
- `architecture`: shared architecture vocabulary and bounded implementation
  review guidance. Octo role workflows decide when and how to invoke it.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `Todo` -> queued; immediately transition to `In Progress` before active work.
  - Special case: if a PR is already attached, treat as feedback/rework loop (run full PR feedback sweep, address or explicitly push back, revalidate, return to `Human Review`).
- `In Progress` -> implementation actively underway.
- `Agent Fixes` -> incremental implementer feedback loop; preserve the
  existing branch, PR, legacy read-only Workpad context, and handoff trail while
  addressing reviewer or QA gaps.
- `Agent Review` -> implementation PR is ready for agent review; validate
  requested changes before returning work to QA.
- `Agent QA` -> QA validation is underway; follow the active Octo QA role
  workflow before QA handoff.
- `Human Review` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow (do not call `gh pr merge` directly).
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then read source artifacts and start execution flow without creating a Workpad.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current issue, branch, PR, and handoff context.
   - `Agent Fixes` -> continue the existing branch and PR as an incremental
     feedback loop; use the latest handoff trail and branch-local specs when
     addressing requested changes.
   - `Agent Review` -> run reviewer validation for the current PR before
     moving work back to QA.
   - `Agent QA` -> run QA validation according to the active Octo QA role
     workflow, then hand off according to the QA result.
   - `Human Review` -> wait and poll for decision/review updates.
   - `Merging` -> on entry, open and follow `.codex/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow.
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order:
   - `update_issue(..., state: "In Progress")`
   - read the issue body, legacy Workpad context when present, handoff trail, PR attachments, and relevant specs or ADRs
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Read the durable source artifacts for the issue:
    - Linear issue body and current state.
    - Existing legacy `## Codex Workpad` comment when present, as read-only history.
    - Full `## Symphony Handoff` trail.
    - PR attachments and current branch state.
    - Relevant branch-local specs, ADRs, or issue-linked durable documents.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Do not create or update Linear `## Codex Workpad` comments for planning, progress, validation, or handoff notes.
4.  Build a local execution plan from the source artifacts. If detailed continuation evidence is needed, write it to an approved observability artifact and cite it from the compact handoff.
5.  Ensure acceptance criteria and required validation are current before edits.
    - If changes are user-facing, include a UI walkthrough acceptance check in the local plan or observability artifact.
    - If changes touch app files or app behavior, include app-specific flow checks such as launch path, changed interaction path, and expected result path.
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, treat those requirements as mandatory checks with no optional downgrade.
6.  Run a principal-style self-review of the plan and refine it before editing.
7.  Before implementing, capture a concrete reproduction signal in local validation notes, linked evidence, or the final compact handoff `Work done` field.
8.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then preserve the pull/sync result in local validation notes, linked evidence, or the final compact handoff `Work done` field.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Compact context and proceed to execution.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this protocol before moving to `Human Review`:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from all channels:
   - Top-level PR comments (`gh pr view --comments`).
   - Inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`).
   - Review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable reviewer comment (human or bot), including inline review comments, as blocking until one of these is true:
   - code/test/docs updated to address it, or
   - explicit, justified pushback reply is posted on that thread.
4. Track each feedback item and its resolution status in local notes, commits, or linked evidence.
5. Re-run validation after feedback-driven changes and push updates.
6. Repeat this sweep until there are no outstanding actionable comments.

## Shared Architecture Skill Boundary

The repository-local `.codex/skills/architecture/` directory is shared
architecture guidance, not an Octo QA workflow definition. It preserves the
localized module/interface/depth/seam/adapter vocabulary and bounded evaluation
technique for roles that are explicitly told to use it.

Octo role-specific obligations for Agent QA, reviewer validation, one-time
architecture suggestion markers, handoff packet fields, role exposure, and
operator/console loading are owned by the Octo workflow surface in
`EmberAGI/scaling-octo-engine`. Symphony-local guidance must not copy that
workflow contract or claim that the shared skill is automatically loaded by
Octo QA roles.

The shared skill may use `CONTEXT.md` as vocabulary/context when present.
Durable behavior and architecture authority remain in `spec/` and `spec/adr/`;
`CONTEXT.md` and `docs/adr/` are not canonical durable sources.

## Blocked-access escape hatch (required behavior)

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is **not** a valid blocker by default. Always try fallback strategies first (alternate remote/auth mode, then continue publish/review flow).
- Do not move to `Human Review` for GitHub access/auth until all fallback strategies have been attempted and documented in compact handoff `Work done` or linked evidence.
- If a non-GitHub required tool is missing, or required non-GitHub auth is unavailable, move the ticket to `Human Review` with a short blocker brief in the compact handoff that includes:
  - what is missing,
  - why it blocks required acceptance/validation,
  - exact human action needed to unblock.
- Keep the brief concise and action-oriented; do not add extra top-level comments outside the required compact handoff.

## Agent QA Browser Use capability (QA role only)

This section applies only when the active role is Agent QA. It does not grant
Browser Use as a general Symphony role skill to implementer, reviewer, landing,
or operator roles.

Agent QA may use Browser Use as an optional, issue-appropriate browser-facing
evidence capability when UI/manual acceptance, browser runtime checks,
screenshots, page-state inspection, or form-flow verification materially improve
QA. In this workflow, Browser Use must mean local deterministic browser
automation or inspection that runs without Browser Use Cloud, hosted browser
infrastructure, `BROWSER_USE_API_KEY`, OpenAI/Anthropic/Google provider keys, or
any new operator-provisioned API secret.

The preferred local Browser Use path is the Agent QA-only `browser-use` skill
from `.codex/role-skills/qa.json`. When local prerequisites are present, Agent
QA may use Browser Use CLI commands such as `browser-use open`,
`browser-use state`, `browser-use click <index>`, `browser-use type "text"`,
`browser-use input <index> "text"`, and `browser-use screenshot` against a
local browser session. QA should derive numeric element indices from
`browser-use state`, use `input <index> "text"` for field filling, and reserve
`type "text"` for an already focused field. Local stdio MCP is an acceptable
fallback or alternate path when launched with
`uvx --from 'browser-use[cli]' browser-use --mcp` and used only for local,
no-key browser inspection.

When a Browser Use agent-mode feature or installed library path requires an LLM
provider key or hosted browser service, Agent QA must not add or request that
secret. Use one of these fallbacks instead:

- Browser Use CLI/local stdio MCP only when it runs locally with no key;
- existing repository Playwright/browser tooling;
- deterministic local browser CLI automation if a browser is already available;
- ordinary manual inspection with concise evidence notes;
- a not-applicable rationale when the issue has no browser-facing acceptance
  surface or the role environment has no usable browser or Browser Use CLI/MCP;
- `Human Escalation` when browser-facing acceptance is required and every
  no-key local path is blocked.

Agent QA must attach useful browser evidence to Linear when browser validation
is performed. Acceptable evidence includes screenshots, page-state summaries,
form-flow notes, command output, logs, or short recordings. Do not rely on a
local file path, GitHub comment, object store, or any other non-Linear location
as the durable QA artifact store for Linear-backed Octo workflows.

Before a successful QA handoff to `Human Review`, Agent QA must keep the
`## Symphony Handoff` compact. The successful QA handoff to `Human Review` must
stay compact, use a tiny `Role note` review summary, put the human-review
request in `Next action`, and point browser evidence or browser-not-applicable
rationale to compact handoff `Work done` or approved Linear attachment
metadata.

Before any QA handoff, Agent QA validation notes must state which browser path
was used, which pages/states/flows were checked, where Linear artifacts were
attached, or why browser automation was not applicable. If no local browser is
available, headless execution is blocked, sandbox policy prevents launch, or a
desired feature requires a forbidden key, record the fallback chosen and the
reason.

## Step 2: Execution phase (Todo -> In Progress -> Human Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is captured in local validation notes, linked evidence, or the final compact handoff before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load existing legacy Workpad context only if present; do not mutate it.
4.  Implement against the source artifacts and local plan:
    - Keep local notes current enough to support final validation and handoff.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in local validation notes, linked evidence, or the compact handoff `Work done` field so reviewers can follow the evidence.
    - If app-touching, run `launch-app` validation and capture/upload media via `github-pr-media` before handoff.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the required validation for your scope and confirm it passes; if it fails, address issues and rerun until green, then commit and push changes.
8.  Attach PR URL to the issue as Linear/GitHub attachment metadata.
    - Ensure the GitHub PR has label `symphony` (add it if missing).
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Prepare a compact `## Symphony Handoff` with exactly these fields:
    - `From -> To`
    - `Work done`
    - `Role note`
    - `Next action`
    Detailed source artifacts, validation logs, screenshots, or checklist material belong in linked evidence or approved Linear attachment metadata, not in the Linear handoff body.
11. Before moving to `Human Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes.
    - Confirm every required ticket-provided validation/test-plan item is complete and cited in compact handoff `Work done` or linked evidence.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-read the issue context before state transition so the compact handoff matches completed work.
12. Only then move issue to `Human Review`.
    - Exception: if blocked by missing required non-GitHub tools/auth per the blocked-access escape hatch, move to `Human Review` with the blocker brief and explicit unblock actions.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `Human Review`.

## Step 3: Human Review and merge handling

1. When the issue is in `Human Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, open and follow `.codex/skills/land/SKILL.md`, then run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching.
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue.
4. Preserve any existing `## Codex Workpad` comment as legacy read-only history.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Build a fresh local plan from source artifacts and execute end-to-end without creating or updating a Workpad.

## Completion bar before Human Review

- Step 1/2 work is complete and accurately reflected in branch state, PR metadata, compact handoff `Work done`, and any linked evidence.
- Acceptance criteria and required ticket-provided validation items are complete.
- Validation/tests are green for the latest commit.
- PR feedback sweep is complete and no actionable comments remain.
- PR checks are green, branch is pushed, and PR is linked on the issue.
- Required PR metadata is present (`symphony` label).
- If app-touching, runtime validation/media requirements from `App runtime validation (required)` are complete.

## Guardrails

- If the branch PR is already closed/merged, do not reuse that branch or prior implementation state for continuation.
- For closed/merged branch PRs, create a new branch from `origin/main` and restart from reproduction/planning as if starting fresh.
- If issue state is `Backlog`, do not modify it; wait for human to move to `Todo`.
- Do not edit the issue body/description for planning or progress tracking.
- Do not create or update Linear `## Codex Workpad` comments. Existing Workpads remain legacy read-only context.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- If out-of-scope improvements are found, create a separate Backlog issue rather
  than expanding current scope, and include a clear
  title/description/acceptance criteria, same-project assignment, a `related`
  link to the current issue, and `blockedBy` when the follow-up depends on the
  current issue.
- Do not move to `Human Review` unless the `Completion bar before Human Review` is satisfied.
- In `Human Review`, do not make changes; wait and poll.
- If state is terminal (`Done`), do nothing and shut down.
- Keep issue text concise, specific, and reviewer-oriented.
- If blocked, add a compact `## Symphony Handoff` describing blocker, impact, and next unblock action.

## Compact handoff template

Use this exact structure for new Linear transition comments:

````md
## Symphony Handoff

- From -> To:
- Work done:
- Role note:
- Next action:
````
