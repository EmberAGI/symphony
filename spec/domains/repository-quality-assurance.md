# Repository Quality Assurance

Status: Draft v1

Purpose: Define the minimum repository QA contract for Octo role workflows,
including bounded architecture review, reviewer validation, implementer repair
behavior, and shared role skill source acceptance.

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
forked normative copy.

Successful `Agent QA` to `Human Review` handoffs MUST use that consumer
reference to follow Octo's upstream human-review packet contract. The handoff
MUST include the upstream packet sections by name, including a mandatory
Artifact Index that either lists artifacts or states that no external artifact
was useful for the issue.

## Bounded Architecture QA

Agent QA MUST run the repository-local `qa-architecture` skill during QA.
The localized skill directory MUST preserve complete upstream-derived support files
needed for the architecture vocabulary and deepening process:
`LANGUAGE.md`, `DEEPENING.md`, and `INTERFACE-DESIGN.md`.

The pass is bounded to implementation-touched files for the current Linear
issue. QA MUST record the diff basis used to select files. Valid bases include:

- PR changed files for the implementation PR.
- Merge-base comparison between `HEAD` and the recorded issue branch base.
- Merge-base comparison between `HEAD` and `origin/main` when no explicit issue
  branch base is recorded.

QA MUST filter the resulting changed-file list to implementation code files.
When no implementation-touched code files are in scope, QA MUST record
`Architecture QA: not applicable` with the diff basis.

QA MUST NOT use the architecture pass for whole-repository improvement scouting.
Architecture findings must be tied to implementation-touched files.

## Architectural Suggestions

Agent QA may emit at most one set of architectural suggestions per Linear issue.
Before adding suggestions, QA MUST check the issue handoff trail and PR
discussion for a counted marker: a prior failed Agent QA handoff containing a
standalone block headed by this exact marker:

```text
Architectural suggestions
```

The counted marker MUST include the required failed architecture QA fields:
diff basis, changed files reviewed, relevant spec files updated, and requested
changes. Successful QA evidence such as `Architectural suggestions: none`,
inline mentions, examples, and contract summaries MUST NOT consume the one
allowed suggestion set.

If a counted marker already exists, later QA passes MUST verify the existing
marked requests and MUST NOT add more architecture suggestions for that Linear
issue.

When architecture causes QA failure, the handoff MUST include:

- the `Architectural suggestions` marker;
- diff basis;
- changed files reviewed;
- relevant spec files updated;
- short requested changes.

QA SHOULD update relevant branch-local `spec/` files when requesting
architecture changes. QA MUST NOT edit production implementation files.

QA MUST route to `Human Escalation` when a request would create or change an
ADR-worthy decision, conflicts with an accepted ADR, or depends on missing
operator intent. The handoff MUST cite the relevant `spec/adr/` file or missing
ADR decision.

## Reviewer Contract

Agent Review MUST validate QA-requested architectural changes before returning
work to QA. Reviewer validation MUST include:

- the marked QA architectural suggestions, when present;
- implementation changes made for those suggestions;
- related branch-local spec updates;
- any referenced `spec/adr/` constraints.

Review MUST NOT move work back to QA while a QA-requested architecture change
or related spec update remains unverified.

## Implementer Contract

When work enters Agent Fixes because of architectural suggestions, the
implementer MUST use both:

- the QA-updated branch-local specs; and
- the QA handoff containing the `Architectural suggestions` marker.

Implementer fixes SHOULD keep production changes scoped to the requested
architecture repairs and update validation evidence before returning to Agent
Review.

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

Repository changes that add or materially change QA architecture behavior MUST
validate that:

- Agent QA has access to the localized `qa-architecture` skill.
- The localized `qa-architecture` skill directory includes complete
  upstream-derived support files for language, deepening, and interface-design
  guidance.
- The repository includes a thin Symphony-local handoff-artifacts consumer
  reference that identifies Octo's source-of-truth spec, records local deltas,
  and guards against silently forking the Octo contract.
- Successful QA-to-Human-Review guidance requires Octo's upstream human-review
  packet sections and mandatory Artifact Index without redefining the full
  Octo handoff-artifacts contract in Symphony.
- The skill and workflow enforce changed-file-only scope and require a recorded
  diff basis.
- `CONTEXT.md` can be preserved as useful domain vocabulary, while `spec/` and
  `spec/adr/` are canonical durable context paths.
- QA records not-applicable when no implementation-touched code files are in
  scope.
- QA failure handoffs caused by architecture include the `Architectural
  suggestions` marker, diff basis, changed files reviewed, relevant spec files
  updated, and requested changes.
- QA does not edit production implementation files when requesting
  architecture changes.
- ADR-worthy or ADR-conflicting requests route to `Human Escalation` with
  `spec/adr/` references.
- Agent QA emits at most one set of architectural suggestions per Linear issue,
  and only a prior failed-QA architecture-suggestions block consumes that set.
- Agent Review validates QA-requested architecture changes and related spec
  updates before moving work back to QA.
- Agent Fixes uses QA-updated specs and the QA handoff when addressing
  architecture suggestions.

## References

- [Agent Runtime](./agent-runtime.md)
- [Symphony Service](./symphony-service.md)
- [Symphony Handoff Artifacts](./symphony-handoff-artifacts.md)
- [ADR 0001: Provider-Neutral Agent Runtimes](../adr/0001-provider-neutral-agent-runtimes.md)
