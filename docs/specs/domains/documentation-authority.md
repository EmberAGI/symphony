# Documentation Authority

Status: Active
Decision record: [ADR 0003](../../adr/0003-canonical-documentation-authority.md)

This domain defines where Symphony's durable specification and architecture
authority lives, how consumers discover it, and how the repository validates
that exactly one authority hierarchy exists.

## Canonical hierarchy

The only durable authority locations in this repository are:

- `docs/specs/index.md` — the spec index and entry point.
- `docs/specs/domains/` — canonical domain specifications.
- `docs/adr/` — accepted architecture decision records.

Visual specifications, when present, live at `docs/specs/**/*.spec.html` or
`docs/adr/**/*.spec.html` according to which authority owns them. No other
location is a durable authority, and no alias, symlink, duplicate tree, or
read/write fallback to another location is permitted.

Durable Symphony work contracts name an exact `contract_ref` under
`docs/specs/` or `docs/adr/`. Provider-neutral Octo roles resolve authority
through this standard hierarchy only; they need no Symphony-specific path
knowledge and no legacy fallback behavior.

## Authority failure modes

Documentation-authority validation fails visibly — with errors, not silent
degradation — when any of the following holds:

- `docs/specs/index.md` is missing or is not a regular file.
- `docs/specs/domains/` is missing, empty, or not a real directory.
- `docs/adr/` is missing, empty, or not a real directory.
- A top-level directory named `spec` or `specs` exists in any form,
  including as a symlink or an empty directory. A legacy-only hierarchy is
  not a fallback authority; a legacy tree next to the canonical one is a
  duplicate authority. Both are rejected.
- Any canonical authority path, ancestor, or contained authority entry is a
  symlink. Aliasing the canonical hierarchy from or to another path is
  rejected, while symlinks unrelated to canonical authority remain outside
  this invariant.

## Bounded validation

Validation is bounded and deterministic:

- Nonstandard spec-like files — for example `*.spec.html` files or nested
  `spec`, `specs`, or `adr` directories outside `docs/specs/` and
  `docs/adr/` — produce warnings that name the offending paths. They are
  never loaded as alternate authority.
- Active references are scanned for stale legacy authority paths. A
  reference to a top-level `spec`-or-`specs` path segment is stale unless
  the referencing line names the upstream `scaling-octo-engine` repository,
  whose own documentation migration is owned by that repository. Plural
  `specs` references are classified using their source context: explicit
  relative paths resolve from the referencing file, repository paths resolve
  from the repository root, and only paths resolving under `docs/specs/` are
  canonical.
- Relative links inside canonical authority documents must resolve to
  existing files whose physical targets remain within the repository after
  symlink resolution; a link that escapes the repository root directly or
  through an in-repository symlink is rejected even when its target exists.
- Stale-reference scanning covers only active surfaces: inside a Git work
  tree, the tracked source, documentation, and metadata file types
  (Markdown, Elixir sources, TOML, JSON, YAML). Outside a Git work tree it
  falls back to a bounded directory walk that excludes build, dependency,
  and VCS directories. It does not follow symlinks and does not consult any
  location outside the repository root.

## Consumers

- Repository instructions (`README.md`, `elixir/AGENTS.md`, and
  `elixir/WORKFLOW.md`) reference the canonical hierarchy directly. Octo-owned
  skills consume the hierarchy from `EmberAGI/scaling-octo-engine`.
- ExUnit contract tests exercise the public documentation-authority
  contract: canonical success, missing hierarchy, legacy-only hierarchy,
  duplicate and alias rejection, stale active references, relative link
  integrity, and nonstandard-path warnings.
- Octo consumes this repository at a pinned revision; from the migration
  merge until the Octo adoption issue is deployed, no compatibility alias
  exists for the interval, by decision.
