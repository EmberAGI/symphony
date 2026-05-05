---
name: qa-architecture
description: |
  Required during Agent QA to run a bounded architecture pass over only the
  implementation-touched files for the current Linear issue.
---

# QA Architecture

Surface architectural friction in the current implementation diff and propose
bounded **deepening opportunities**. This is a QA-focused localization of Matt
Pocock's `improve-codebase-architecture` skill: it preserves the vocabulary and
supporting guidance, but limits Agent QA to changed implementation files for the
current Linear issue.

This skill is informed by the project's domain model. `CONTEXT.md`, when
present, is useful domain vocabulary for naming modules and concepts.
Branch-local `spec/` and `spec/adr/` remain the canonical durable sources for
Octo/Symphony QA decisions.

## Glossary

Use these terms exactly in every suggestion. Consistent language is the point:
do not drift into "component," "service," "API," or "boundary." Full
definitions live in [LANGUAGE.md](LANGUAGE.md).

- **Module** - anything with an interface and an implementation: function,
  class, package, or slice.
- **Interface** - everything a caller must know to use the module: types,
  invariants, error modes, ordering, configuration, and performance
  expectations. Not just the type signature.
- **Implementation** - the code inside a module.
- **Depth** - leverage at the interface: a lot of behavior behind a small
  interface. **Deep** means high leverage. **Shallow** means the interface is
  nearly as complex as the implementation.
- **Seam** - where an interface lives; a place behavior can be altered without
  editing in place. Use this, not "boundary."
- **Adapter** - a concrete thing satisfying an interface at a seam.
- **Leverage** - what callers get from depth.
- **Locality** - what maintainers get from depth: change, bugs, knowledge, and
  verification concentrated in one place.

Key principles:

- **Deletion test**: imagine deleting the module. If complexity vanishes, it
  was a pass-through. If complexity reappears across N callers, it was earning
  its keep.
- **The interface is the test surface.**
- **One adapter means a hypothetical seam. Two adapters means a real seam.**

## Octo/Symphony QA Scope

Review only implementation-touched files for the current Linear issue. This
skill is not permission to scout the whole repository for architectural
improvements. Do not inventory the rest of the repository for possible
cleanups.

Record the diff basis before reviewing:

- Prefer PR changed files when an implementation PR exists.
- Otherwise use the merge base between `HEAD` and the recorded issue branch
  base.
- If no explicit issue branch base is recorded, use `origin/main` and say so in
  the QA handoff.

Filter the changed-file list to implementation code files. Specs, ADRs, tests,
workflow files, skill files, and `CONTEXT.md` may be used as context or proof,
but they are not reasons to inspect unrelated production files.

If no implementation-touched code files remain after filtering, record
`Architecture QA: not applicable` with the diff basis and stop this skill.

## Durable Context

Read the project's domain vocabulary and durable decisions in the area being
reviewed before evaluating the touched files:

- Use `CONTEXT.md` vocabulary for domain names and concept language when the
  repository has one.
- Use `spec/` for branch-local product, workflow, and repository behavior.
- Use `spec/adr/` for accepted architecture decisions.
- Use branch-local specs updated by QA in the current issue branch.

Do not use `CONTEXT.md` or `docs/adr/` as canonical sources for Octo work.
`CONTEXT.md` is domain vocabulary/context, not durable QA authority.
`docs/adr/` may be read only as non-authoritative legacy or historical context
when explicitly called out as such.

## Process

### 1. Explore The Touched Files

Walk only the implementation-touched files selected by the recorded diff
basis. Do not spawn additional explorers unless the current role instructions
explicitly allow it.

Explore organically and note where you experience friction:

- Where does understanding one concept require bouncing between many small
  modules?
- Where are modules **shallow** - interface nearly as complex as the
  implementation?
- Where have pure functions been extracted just for testability, but the real
  bugs hide in how they are called, leaving no **locality**?
- Where do tightly coupled modules leak across their seams?
- Which touched modules are untested, or hard to test through their current
  interface?

Apply the **deletion test** to anything that looks shallow: would deleting it
concentrate complexity, or just move it? A "yes, concentrates" is the useful
signal.

Use [DEEPENING.md](DEEPENING.md) to classify dependencies and testing strategy
for any candidate. Use [INTERFACE-DESIGN.md](INTERFACE-DESIGN.md) only to
evaluate or frame a concrete interface repair; Agent QA does not redesign the
implementation inline.

### 2. Present Bounded Candidates

When architecture is not acceptable, present one bounded set of deepening
opportunities. Each candidate must be tied to implementation-touched files and
must include:

- **Files** - which touched files/modules are involved.
- **Problem** - why the current architecture is causing friction.
- **Solution** - plain English description of what should change.
- **Benefits** - explained in terms of locality, leverage, and testability.

Use `CONTEXT.md` vocabulary for the domain and [LANGUAGE.md](LANGUAGE.md)
vocabulary for the architecture. If `CONTEXT.md` defines "Order," talk about
"the Order intake module," not a generic handler name and not an invented
service label.

ADR conflicts: if a candidate contradicts an accepted `spec/adr/` decision,
route to `Human Escalation` instead of requesting implementation changes. Cite
the ADR and explain why the friction might warrant revisiting it. Do not list
every theoretical refactor an ADR forbids.

### 3. Verify Prior Requests

When verifying an implementation pass that followed prior marked architecture
requests:

- use the original marked request as the checklist;
- confirm the requested files and related specs were updated or explicitly
  justified;
- verify tests now cross the intended interface where applicable;
- do not add a second set of architecture suggestions for the same Linear
  issue.

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
- domain/context sources consulted, including `CONTEXT.md` when relevant;
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
  the issue, `CONTEXT.md`, specs, or ADRs.

Escalation handoffs must cite the relevant `spec/adr/` file or the missing ADR
decision.
