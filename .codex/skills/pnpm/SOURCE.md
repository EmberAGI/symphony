# Source

- Upstream: `EmberAGI/son-of-anton@faf1d5a`
- Upstream directory: `.rulesync/skills/pnpm/`
- Localized files: [SKILL.md](SKILL.md)

## Local Adaptation

The upstream directory is preserved and augmented with Octo implementer
activation rules in [SKILL.md](SKILL.md). Use is limited to issue-scoped pnpm
package-manager work with durable signals such as `pnpm-lock.yaml`,
`pnpm-workspace.yaml`, `packageManager` fields, `.npmrc` pnpm settings, specs,
ADRs, workpad notes, or handoff trail evidence.

This local version intentionally diverges from `EmberAGI/son-of-anton@faf1d5a`
to align with the shared Symphony TDD execution contract. It distinguishes
iteration commands from pre-handoff gates, points agents to repo-declared
affected/cache or package-filter paths when present, warns against bypassing
declared task-runner paths with raw recursive commands, and avoids inventing
new script names beyond the target repo's script contract.
