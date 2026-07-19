---
name: architecture
description: |
  Reusable architecture guidance for evaluating or improving a bounded set of
  implementation files using module, interface, depth, seam, and adapter
  vocabulary.
---

# Architecture

Surface architectural friction in a bounded implementation scope and propose
concrete **deepening opportunities**. This is a Symphony-localized version of
Matt Pocock's `improve-codebase-architecture` skill: it preserves the
architecture vocabulary and supporting guidance while leaving Octo role
workflow, state routing, handoff markers, and PR ownership rules to the
invoking workflow.

This skill is informed by the project's domain model. `CONTEXT.md`, when
present, is useful domain vocabulary for naming modules and concepts.
Branch-local `docs/specs/` and `docs/adr/` remain the canonical durable sources for
durable Octo/Symphony decisions.

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

## Bounded Scope

Use this skill only for the implementation files named by the invoking task or
role workflow. This skill is not permission to scout the whole repository for
architectural improvements. Do not inventory the rest of the repository for
possible cleanups.

When the invoking workflow is based on a Linear issue, the bounded scope should
come from that workflow's issue diff basis, such as:

- Prefer PR changed files when an implementation PR exists.
- Otherwise use the merge base between `HEAD` and the recorded issue branch
  base.
- If no explicit issue branch base is recorded, use `origin/main` and record
  that assumption in the invoking workflow's evidence.

Filter the selected file list to implementation code files. Specs, ADRs, tests,
workflow files, skill files, and `CONTEXT.md` may be used as context or proof,
but they are not reasons to inspect unrelated production files.

If no implementation code files remain after filtering, record that architecture
review is not applicable for the selected basis and stop this skill.

## Durable Context

Read the project's domain vocabulary and durable decisions in the area being
reviewed before evaluating the bounded files:

- Use `CONTEXT.md` vocabulary for domain names and concept language when the
  repository has one.
- Use `docs/specs/` for branch-local product, workflow, and repository behavior.
- Use `docs/adr/` for accepted architecture decisions.
- Use branch-local specs updated in the current issue branch.

Do not use `CONTEXT.md` as a canonical source for Octo work.
`CONTEXT.md` is domain vocabulary/context, not durable authority.

## Process

### 1. Explore The Bounded Files

Walk only the selected implementation files. Do not spawn additional explorers
unless the current role instructions explicitly allow it.

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
evaluate or frame a concrete interface repair; do not redesign unrelated
implementation inline.

### 2. Present Bounded Candidates

When architecture is not acceptable for the selected scope, present a bounded
set of deepening opportunities. Each candidate must be tied to selected
implementation files and must include:

- **Files** - which touched files/modules are involved.
- **Problem** - why the current architecture is causing friction.
- **Solution** - plain English description of what should change.
- **Benefits** - explained in terms of locality, leverage, and testability.

Use `CONTEXT.md` vocabulary for the domain and [LANGUAGE.md](LANGUAGE.md)
vocabulary for the architecture. If `CONTEXT.md` defines "Order," talk about
"the Order intake module," not a generic handler name and not an invented
service label.

ADR conflicts: if a candidate contradicts an accepted `docs/adr/` decision, do
not silently choose a side. Cite the ADR, explain the friction, and route the
conflict according to the invoking workflow. Do not list every theoretical
refactor an ADR forbids.

### 3. Verify Prior Requests

When verifying an implementation pass that followed prior architecture
requests:

- use the original request as the checklist;
- confirm the requested files and related specs were updated or explicitly
  justified;
- verify tests now cross the intended interface where applicable;
- do not expand verification into a fresh whole-repository improvement pass.

## Workflow Boundary

This skill supplies architecture vocabulary and bounded evaluation technique.
It does not define role workflow obligations, reviewer gates, state
transitions, handoff packet structure, one-time suggestion markers, PR
metadata, workpad rules, or escalation labels. Those rules live in the active
role workflow and durable repository specs. Follow that workflow when deciding
who may make production edits, when specs must change, and how to route
unresolved architecture questions.
