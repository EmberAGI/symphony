# Repository Quality Assurance

Status: Draft v1

Purpose: Define the minimum repository QA contract for durable behavior
changes, shared role skill source acceptance, and the boundary between
Symphony-owned shared skill source and Octo-owned role workflow guidance.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`,
`RECOMMENDED`, `MAY`, and `OPTIONAL` in this document are to be interpreted as
described in RFC 2119.

## Intended Behavior

Repository changes must carry enough local evidence for reviewers and role
agents to verify durable behavior without rediscovering the acceptance bar from
individual Linear issues.

This domain is the repo-level minimum acceptance suite for implementation work.
When a branch adds, changes, removes, or materially changes durable behavior,
the branch must update this file or record a defensible no-change rationale in
the Codex Workpad and final Symphony Handoff.

## Durable Sources

Repository QA uses these branch-local durable sources as canonical context:

- `spec/`
- `spec/adr/`

`CONTEXT.md` MAY be used as domain vocabulary and contextual naming guidance
when present. `spec/` and `spec/adr/` remain the durable QA authority.
`CONTEXT.md` and `docs/adr/` MUST NOT be treated as canonical sources for Octo
QA decisions.

When a QA, review, or handoff instruction requires handoff-artifact spec
context, agents SHOULD read
`spec/domains/symphony-handoff-artifacts.md`. That file is a Symphony-local
consumer reference to Octo's source-of-truth handoff-artifacts contract, not a
forked normative copy. The Octo workflow surface remains responsible for
successful QA-to-Human-Review packet details.

## Shared Architecture Skill Source

The repository-local `.codex/skills/architecture/` directory is a neutral
shared architecture skill source. It MUST preserve complete upstream-derived
support files needed for architecture vocabulary and deepening:
`LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md`.

The shared skill MUST remain reusable architecture guidance. It may describe
bounded implementation-file evaluation, deepening opportunities, durable context
usage, and architecture vocabulary, but it MUST NOT define Octo role workflow
obligations such as Agent QA state routing, reviewer gates, handoff packet
fields, one-time suggestion markers, PR metadata, workpad rules, or escalation
labels.

The shared skill MUST preserve the source distinction that `CONTEXT.md` is
domain vocabulary/context when present, while `spec/` and `spec/adr/` remain
canonical durable sources. `docs/adr/` is not a canonical durable source.

## Octo QA Workflow Boundary

Octo-specific requirements for when Agent QA uses the shared architecture
skill, how changed-file-only scope is selected, how not-applicable evidence is
recorded, how failed architecture handoffs are marked, how many suggestion sets
may be emitted, how reviewer validation works, and how Agent Fixes consumes QA
architecture feedback are owned by the canonical Octo workflow guidance in
`EmberAGI/scaling-octo-engine`.

Symphony MUST NOT claim that the shared `architecture` skill is automatically
loaded by Octo QA, operator, or console agents. Integration work that exposes
this shared skill to those surfaces must be tracked in the owning Octo issue
and validated in the Octo repository.

## Shared Role Skill Sources

| Change Surface | Required Invariants | Minimum Local Validation | Escalation Route |
| --- | --- | --- | --- |
| Shared Symphony role skills, role skill manifests, or `CODEX_HOME` skill materialization source | Shared skill directories remain complete, locally committed, discoverable by the intended role, and isolated from roles that should not receive them. Upstream-derived skills must name their source artifacts, keep internal links local, document omitted upstream siblings when only part of an upstream pack is localized, and preserve Octo workflow authority for Linear repository metadata, issue branches, state transitions, PR ownership, Codex Workpad, Symphony Handoff, validation, and `Human Escalation` routing. Skill guidance must not impose language, package-manager, frontend, or workflow conventions on unrelated repositories or issues without durable repository or issue signals. | Targeted inspection or tests proving every manifest path resolves, every exposed skill has a `SKILL.md`, full upstream directories named by the issue are present, internal Markdown links resolve to committed local files, implementer-only skills are absent from non-implementer manifests by default, activation conditions are documented, and Octo workflow-boundary language remains present. Run broader repo tests when code behavior is touched. | `Agent Fixes` for implementation or validation gaps. `Human Escalation` when required upstream source artifacts are missing, unreadable, conflicting, or require operator-provisioned access. |

## EMB-186 Implementer Skill Pack

EMB-186 localizes upstream-derived implementer role skills under
`.codex/skills/` and describes default role exposure in
`.codex/role-skills/implementer.json`.

The localized skill pack must include:

- Matt Pocock `tdd` from `mattpocock/skills@b843cb5`.
- Anthropic `frontend-design` from `anthropics/skills@d230a6d`.
- Son of Anton `.rulesync` skills `nodejs`, `pnpm-patching`, `pnpm`,
  `python`, and `typescript` from `EmberAGI/son-of-anton@faf1d5a`.

The implementer manifest must expose these skills only to the implementer role
by default. Reviewer, QA, landing, and backlog-processor exposure requires a
future issue that updates the role contract and validation.

TDD is mandatory for EMB-97 child work that names TDD and for future issues
that explicitly ask for TDD, red-green-refactor, test-first implementation, or
integration-test-first development. Frontend and language/package-manager
skills must activate only from durable issue or repository signals and must not
override existing product specs, ADRs, framework conventions, component
libraries, accessibility requirements, or package-manager choices.

## Minimum Acceptance Suite

Repository changes that add or materially change shared architecture skill
source behavior MUST validate that:

- The localized shared skill is named `architecture`, not `qa-architecture`.
- The localized `architecture` skill directory includes complete
  upstream-derived support files for language, deepening, and interface-design
  guidance.
- The shared skill remains reusable architecture guidance and does not embed
  Agent QA state routing, reviewer gates, handoff packet fields, one-time
  suggestion marker rules, PR metadata, workpad rules, or escalation-label
  policy.
- `CONTEXT.md` can be preserved as useful domain vocabulary, while `spec/` and
  `spec/adr/` are canonical durable context paths.
- `docs/adr/` is not treated as a canonical durable source.
- The repository includes a thin Symphony-local handoff-artifacts consumer
  reference that identifies Octo's source-of-truth spec, records local deltas,
  and guards against silently forking the Octo contract.
- Symphony workflow/spec guidance records that Octo role exposure and
  QA/reviewer/Agent Fixes architecture workflow behavior are owned by
  `EmberAGI/scaling-octo-engine`.
- Validation guards against reintroducing the QA-specific skill name or
  embedding Octo QA workflow obligations in the shared skill.

## References

- [Agent Runtime](./agent-runtime.md)
- [Symphony Service](./symphony-service.md)
- [Symphony Handoff Artifacts](./symphony-handoff-artifacts.md)
- [ADR 0001: Provider-Neutral Agent Runtimes](../adr/0001-provider-neutral-agent-runtimes.md)
