# Documentation Authority

## Intended behavior

Symphony exposes one canonical durable documentation hierarchy to maintainers,
Octo roles, and other repository consumers. The context map is
`docs/specs/index.md`, domain specifications live under `docs/specs/domains/`,
and architecture decisions live under `docs/adr/`.

The hierarchy is a repository Interface. Callers use these stable locations
without learning Symphony's internal documentation layout or probing legacy
paths.

## Domain concepts

**Documentation authority**: The repository-owned specifications and ADRs that
define durable behavior and architecture.

**Context map**: `docs/specs/index.md`, the entry point that links canonical
domain specifications and ADRs.

**Atomic cutover**: One truth-making merge that moves all canonical files and
active references together, leaving no second writable authority.

**Nonstandard specification path**: A spec-like durable file outside
`docs/specs/` or `docs/adr/`. Historical Git objects and immutable completed
Linear history are not repository paths and are excluded.

## Rules and invariants

- `docs/specs/index.md`, `docs/specs/`, and `docs/adr/` are Symphony's only
  canonical durable specification locations.
- Top-level `spec/` and `specs/` do not remain after the cutover. Symlink
  aliases, duplicate trees, read fallbacks, and write fallbacks are forbidden.
- Active repository instructions, shared skills, workflows, source metadata,
  tests, fixtures, examples, and links use the canonical hierarchy.
- An Octo issue that changes durable Symphony behavior names an exact
  `contract_ref` under `docs/specs/` or `docs/adr/`. Generic roles do not need
  Symphony-specific path knowledge beyond that standard contract.
- Missing canonical authority fails visibly. Spec-like files outside the
  standard hierarchy produce bounded migration warnings rather than becoming
  alternate authority.
- Moves preserve Git history. Relative Markdown and HTML links remain valid.
- A Symphony mainline cutover revision must remain a descendant of the Octo
  pin it replaces so Octo can promote it without dropping runtime behavior.

## Interfaces/contracts

- Context map: `docs/specs/index.md`
- Domain specifications: `docs/specs/domains/**/*.md`
- Architecture decisions: `docs/adr/*.md`
- Visual specifications, when present: `docs/specs/**/*.spec.html` or
  `docs/adr/**/*.spec.html`
- Shared visual assets, when present: `docs/specs/.style/` and
  `docs/specs/.viz/`
- Octo objective locator: the exact `contract_ref` in the issue's
  `octo-work-contract/v1` envelope

## Edge cases

- If both a canonical path and a legacy path exist after the truth-making
  merge, validation fails rather than selecting one.
- Historical commits, merged PR text, and completed Linear comments may retain
  old path strings; active source and executable issue contracts may not.
- During the ordered cross-repository cutover, new Symphony-selected Octo work
  remains out of executable states after EMB-1161 lands and until EMB-1162 is
  deployed. No compatibility alias is introduced for that interval.
- Branch-local intake artifacts may describe the final hierarchy before the
  truth-making merge; they do not make the old mainline hierarchy noncanonical.

## Constraints

- EMB-1180 must first restore Symphony's declared `make all` baseline so this
  migration can satisfy the repository gate without a waiver.
- The cutover must work on supported Linux and macOS environments without
  platform-specific interpreter assumptions.
- The migration introduces no new secret, provider credential, runtime
  environment variable, or hosted service.

## Non-goals

- Changing the meaning of existing Symphony domain specifications or ADRs.
- Defining Octo workflow policy owned by `EmberAGI/scaling-octo-engine`.
- Migrating another repository's source tree in the Symphony PR.
- Retaining permanent compatibility for the old hierarchy.

## Open questions about system behavior

None. The operator approved the standard hierarchy and fail-visible posture on
2026-07-18.

## Decision log or links to ADRs

- [ADR 0003: Canonical Documentation Authority](../../adr/0003-canonical-documentation-authority.md)
- 2026-07-18: Grill confirmed that Symphony owns only its repository cutover;
  Octo adoption and pin promotion remain in EMB-1162.

## References to source issues

- [EMB-1161](https://linear.app/emberai/issue/EMB-1161/migrate-symphony-canonical-documentation-paths-to-docsspecs-and)
- [EMB-1162](https://linear.app/emberai/issue/EMB-1162/migrate-octo-and-spec-chat-canonical-documentation-paths-to-docsspecs)
- [EMB-1180](https://linear.app/emberai/issue/EMB-1180/restore-a-fully-green-symphony-make-all-baseline)
