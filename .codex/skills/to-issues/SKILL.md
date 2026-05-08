---
name: to-issues
description: Break a plan, spec, PRD, or backlog item into independently grabbable Octo/Symphony issue slices using tracer-bullet vertical slices.
---

# To Issues

Break a plan into independently grabbable issues using vertical slices
(tracer bullets). This is a Symphony-localized version of Matt Pocock's
`to-issues` skill: it preserves the breakdown technique while leaving
repository metadata, Linear workflow state, labels, `sortOrder`, issue
creation, parent/child relationships, handoffs, PR ownership, validation, and
Human Escalation routing to the invoking Octo/Symphony role workflow.

Source attribution and localization notes live in [SOURCE.md](SOURCE.md).

## Octo/Symphony Use

Use this skill only when the invoking role workflow asks you to break a plan,
spec, PRD, Linear issue, or backlog item into implementation issues. The
invoking workflow owns how to read Linear context, which repository metadata is
authoritative, whether child issues should be created, which Linear state or
label should be used, how blockers are represented, and what handoff or
operator approval evidence is required.

This shared skill supplies technique only. Do not infer Octo workflow authority
from this file, and do not expose this skill to a role by default unless a role
manifest or wrapper workflow explicitly scopes that exposure.

## Process

### 1. Gather Context

Work from the context supplied by the invoking role workflow. If the user or
workflow passes a Linear issue reference, URL, durable spec, ADR, branch-local
artifact, or local path, read the full relevant source material using the
workflow-approved tools.

When source artifacts are missing, unreadable, or conflicting, stop and follow
the invoking workflow's Human Escalation, Blocked, or operator-routing path.
Do not guess and do not create issues from incomplete authority.

### 2. Explore The Codebase When Useful

If the current repository state matters to the breakdown and has not already
been explored, inspect the relevant files, specs, ADRs, and tests. Issue titles
and descriptions should use the project's domain vocabulary and respect
accepted ADRs in the area being touched.

Keep exploration bounded to the plan being sliced. This skill is not permission
to redesign unrelated code or broaden the backlog item.

### 3. Draft Vertical Slices

Break the plan into **tracer bullet** issues. Each issue is a thin vertical
slice that cuts through all required integration layers end to end, not a
horizontal slice of one layer.

Slices may be **HITL** or **AFK**:

- **HITL** slices require human interaction, such as an architectural decision,
  operator approval, design review, missing credential, or workflow-policy
  decision.
- **AFK** slices can be implemented and merged without human interaction once
  their real dependencies are complete.

Prefer AFK over HITL where the work can be made independently executable
without weakening the product, repository, or workflow contract.

Vertical slice rules:

- Each slice delivers a narrow but complete path through every relevant layer,
  such as data model, API, workflow, UI, tests, docs, or validation.
- A completed slice is demoable or verifiable on its own.
- Prefer many thin slices over a few thick ones.
- Use blockers only for real dependencies where one slice cannot start or
  cannot be validated until another is complete. Do not use blockers as
  priority, grouping, or sequencing hints.
- Do not close, resolve, or otherwise treat a parent issue as complete merely
  because child issues were created.

### 4. Review The Proposed Breakdown

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name.
- **Type**: HITL or AFK.
- **Blocked by**: real dependency slices only, or `None`.
- **User stories covered**: which user stories this addresses, if the source
  material has them.
- **Verification**: the narrow acceptance or validation evidence that proves
  the slice is independently complete.

Ask for review or operator approval only when the invoking workflow requires
approval before issue creation or when the breakdown contains HITL decisions.
Otherwise, follow the role workflow's normal unattended path.

### 5. Publish Or Hand Off Issues Through The Invoking Workflow

When the breakdown is approved or the workflow authorizes unattended creation,
publish or hand off slices through the invoking Octo/Symphony workflow. Use the
workflow-approved Linear macro or issue-creation path so repository metadata,
state, labels, `sortOrder`, parent/child links, handoff comments, Human
Escalation labels, and native blocker relations stay policy-compliant.

Publish dependency blockers first when real issue identifiers are needed by
later slices. Record only real dependencies in blocker fields or native
relations.

Use this body shape unless the invoking workflow provides a stricter template:

```md
## Parent

A reference to the parent issue if the workflow says to create parent-linked
children; otherwise omit this section.

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior,
not layer-by-layer implementation.

Avoid specific file paths or code snippets because they go stale quickly.
Exception: if a prototype produced a snippet that captures a decision more
precisely than prose can, such as a state machine, reducer, schema, or type
shape, inline the decision-rich part and note that it came from a prototype.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- A reference to the blocking ticket if any.

Or `None - can start immediately` if there are no real blockers.
```

Do not close or modify any parent issue unless the invoking workflow explicitly
instructs you to do so.

## Workflow Boundary

This skill does not define Linear state names, Linear label policy, repository
metadata rules, branch names, `sortOrder` policy, parent/child creation
mechanics, native relation policy, PR metadata, Codex Workpad rules, Symphony
Handoff format, validation requirements, or Human Escalation routing. Those
rules live in the active Octo/Symphony workflow, the Linear issue, durable
repository specs, ADRs, and wrapper-owned role guidance.
