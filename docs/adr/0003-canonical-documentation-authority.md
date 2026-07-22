# 0003: Canonical Documentation Authority under docs/specs and docs/adr

Status: Accepted
Date: 2026-07-18

## Context

Symphony historically stored its durable specification and ADR authority in a
top-level directory named `spec`, with domain specifications in its `domains`
subdirectory and decision records in its `adr` subdirectory. Active references
to that hierarchy were spread across repository instructions, shared skills,
workflows, and ExUnit contract tests. Sibling repositories in the Octo family
adopted the standard `docs/specs` + `docs/adr` hierarchy, and Octo itself
adopts it in a companion issue. Keeping a repository-specific layout forced
every role and verbatim engineering skill to carry Symphony-specific path
knowledge.

The decision is hard to reverse (every consumer, work contract, and pin
follows it), surprising without context (two standard-looking layouts
existed across the repository family), and a real trade-off (see
alternatives), so it is recorded as an ADR.

## Decision

- `docs/specs/index.spec.html`, `docs/specs/domains/`, and `docs/adr/` are the only
  durable authority locations in this repository.
- The index is the sole, offline, annotatable context map. It loads the
  repository-owned spec-chat runtime, exposes stable anchors, and navigates
  every canonical domain specification and ADR. It has no Markdown twin.
- The migration is one atomic repository cutover: the truth-making change
  leaves no top-level directory named `spec` or `specs`, no duplicate tree,
  no symlink alias, and no read or write fallback.
- Missing canonical authority fails visibly. Bounded validation warns about
  spec-like files outside the standard hierarchy without loading them as
  alternate authority.
- Durable work contracts name an exact `contract_ref` under `docs/specs/` or
  `docs/adr/`. Provider-neutral Octo roles need no legacy fallback behavior.
- From this merge until the companion Octo adoption issue is deployed, new
  Symphony work stays outside executable Octo states; no compatibility alias
  is introduced for the interval.

## Alternatives considered

- Keep the permanent top-level legacy hierarchy: rejected; it preserves
  repository-specific discovery and blocks the family-wide standard.
- Symlink or dual-path fallback during a transition window: rejected by the
  operator; a second readable authority invites divergence and makes "which
  file is true" ambiguous.
- A single cross-repository PR migrating Symphony and Octo together:
  rejected; it violates one-repository-per-issue ownership and couples two
  release trains.

## Consequences

- Every role and skill uses one standard hierarchy across the repository
  family; no alias or repository-specific discovery survives.
- Review annotations target stable HTML anchors, while canonical behavior and
  decisions remain owned by the linked domain specifications and ADRs.
- Historical Git commits and immutable completed Linear history still
  mention the legacy layout; they are not rewritten. Upstream
  `scaling-octo-engine` references keep their own paths until that
  repository's migration lands.
- The documentation-authority contract is specified in
  [`docs/specs/domains/documentation-authority.md`](../specs/domains/documentation-authority.md)
  and enforced by deterministic ExUnit contract tests.
