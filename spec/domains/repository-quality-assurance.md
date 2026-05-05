# Repository Quality Assurance

## Intended Behavior

Repository changes must carry enough local evidence for reviewers and role
agents to verify durable behavior without rediscovering the acceptance bar from
individual Linear issues.

This domain is the repo-level minimum acceptance suite for implementation work.
When a branch adds, changes, removes, or materially changes durable behavior,
the branch must update this file or record a defensible no-change rationale in
the Codex Workpad and final Symphony Handoff.

## Minimum Acceptance Suite

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

## References

- [Agent Runtime](./agent-runtime.md)
- [Provider-Neutral Agent Runtimes ADR](../adr/0001-provider-neutral-agent-runtimes.md)
