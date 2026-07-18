# 0003: Canonical Documentation Authority

Date: 2026-07-18

## Status

Accepted for EMB-1161 intake.

## Context

Symphony's durable specifications and ADRs currently live under top-level
`spec/`. Octo and spec-chat are converging on `docs/specs` and `docs/adr`, a
layout that works with the verbatim engineering skills used by Octo and keeps
product/domain specifications distinct from architectural decisions.

Keeping aliases or teaching every caller both layouts would create two
interfaces and make future writes ambiguous. Moving Symphony independently
also creates a short integration interval before Octo can pin the merged
revision and update its role guidance.

## Decision

Symphony will atomically move its canonical context map and specifications to
`docs/specs/` and its ADRs to `docs/adr/`. The truth-making merge removes the
old top-level `spec/` and any top-level `specs/`; no symlink, duplicate tree,
read fallback, or write fallback remains.

The repository exposes the new hierarchy as its documentation authority
Interface. Octo issues use an exact work-contract `contract_ref` under the
standard hierarchy. During the ordered cross-repository cutover, new
Symphony-selected Octo work stays out of executable states after this merge
until EMB-1162 is deployed.

## Consequences

- Active instructions, skills, workflows, tests, and links move in the same
  change.
- Missing authority and nonstandard spec-like files become visible validation
  results rather than alternate discovery paths.
- Octo must pin the merged descendant revision and complete its companion
  migration before Symphony-selected work resumes.
- Git history remains available through moves, while historical external text
  is not rewritten.

## Alternatives considered

- Keep `spec/` permanently. Rejected because it prevents convergence on the
  standard hierarchy used by Octo's verbatim engineering skills.
- Add symlinks or dual-path fallback. Rejected because it creates a shallow,
  ambiguous Interface and indefinite migration debt.
- Move Symphony and Octo in one issue. Rejected because each Linear issue and
  PR must remain owned by exactly one canonical repository.

## References

- [Documentation Authority](../specs/domains/documentation-authority.md)
- [EMB-1161](https://linear.app/emberai/issue/EMB-1161/migrate-symphony-canonical-documentation-paths-to-docsspecs-and)
- [EMB-1162](https://linear.app/emberai/issue/EMB-1162/migrate-octo-and-spec-chat-canonical-documentation-paths-to-docsspecs)
