# Source

- Upstream: `EmberAGI/son-of-anton@faf1d5a`
- Upstream directory: `.rulesync/skills/nodejs/`
- Localized files: [SKILL.md](SKILL.md)

## Local Adaptation

The upstream directory is preserved and augmented with Octo implementer
activation rules in [SKILL.md](SKILL.md). Use is limited to issue-scoped
Node.js work with durable signals such as `package.json`, lockfiles, runtime
scripts, JavaScript server entrypoints, specs, ADRs, workpad notes, or handoff
trail evidence.

This local version intentionally diverges from `EmberAGI/son-of-anton@faf1d5a`
to align validation wording with the shared Symphony TDD execution contract
without moving TypeScript, Vitest, test-tier, or task-runner architecture into
the runtime skill. It now recommends targeted package/runtime scripts while
iterating and the established repo gate near handoff.
