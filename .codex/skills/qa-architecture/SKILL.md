---
name: qa-architecture
description: |
  Required during Agent QA to run a bounded architecture pass over only the
  implementation-touched files for the current Linear issue.
---

# QA Architecture

Use this skill during Agent QA after ordinary correctness checks are understood.
It adapts architecture review vocabulary for Octo without turning QA into a
whole-repository improvement hunt.

## Scope

Review only implementation-touched files for the current Linear issue.

The diff basis MUST be recorded before reviewing:

- Prefer PR changed files when an implementation PR exists.
- Otherwise use the merge base between `HEAD` and the recorded issue branch
  base. If no explicit issue branch base is recorded, use `origin/main` and say
  so in the QA handoff.
- Filter the changed-file list to implementation code files. Specs, ADRs,
  tests, workflow files, and skill files may be used as context or proof, but
  they are not reasons to scout unrelated production files.

If no implementation-touched code files remain after filtering, record
`Architecture QA: not applicable` with the diff basis and stop this skill.

## Durable Context

Use repository-local durable sources:

- `spec/`
- `spec/adr/`
- branch-local specs updated by QA in the current issue branch

Do not use `CONTEXT.md` or `docs/adr/` as canonical sources for Octo work.
They may be read only as non-authoritative historical context when explicitly
called out as such.

## Review Vocabulary

Look for deepening opportunities in the touched implementation files:

- boundaries that should be sharper;
- duplicated concepts that should become one named abstraction;
- coupling that makes the changed behavior harder to test or reason about;
- unclear ownership between workflow policy, runtime adapters, tracker writes,
  and repository-local specs;
- missing or stale durable specs when the implementation changes behavior;
- a local design that conflicts with an accepted ADR.

Keep suggestions short, concrete, and tied to changed files. Do not inventory
the rest of the repository for possible cleanups.

## One-Time Suggestion Rule

Agent QA may emit at most one set of architectural suggestions per Linear
issue.

Before adding suggestions, search the Linear issue handoff trail and PR
discussion for the exact marker:

```text
Architectural suggestions
```

If the marker already exists for this Linear issue, do not add new
architecture suggestions. Later QA passes only verify whether the existing
marked requests were addressed.

## QA Outputs

When architecture is acceptable, include this in the QA handoff:

- diff basis;
- changed files reviewed;
- durable specs or ADRs consulted;
- `Architectural suggestions: none`.

When QA fails because of architecture, the handoff MUST include:

```md
Architectural suggestions

- Diff basis:
- Changed files reviewed:
- Relevant spec files updated:
- Requested changes:
```

QA SHOULD update the relevant branch-local `spec/` files when requesting
architecture changes so the implementer and reviewer share the same durable
target. QA MUST NOT edit production implementation files.

Route to `Human Escalation` instead of requesting implementation changes when:

- the suggested change creates or changes an ADR-worthy decision;
- the implementation conflicts with an accepted ADR;
- the correct behavior depends on product or operator intent not recorded in
  the issue, specs, or ADRs.

Escalation handoffs must cite the relevant `spec/adr/` file or the missing ADR
decision.

## Verification

When verifying an implementation pass that followed prior marked architecture
requests:

- use the original marked request as the checklist;
- confirm the requested files and related specs were updated or explicitly
  justified;
- do not add a second set of architecture suggestions for the same Linear
  issue.
