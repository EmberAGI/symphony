# Source

- Upstream: `EmberAGI/son-of-anton@faf1d5a`
- Upstream directory: `.rulesync/skills/typescript/`
- Localized files: [SKILL.md](SKILL.md)

## Local Adaptation

The upstream directory is preserved and augmented with Octo implementer
activation rules in [SKILL.md](SKILL.md). Use is limited to issue-scoped
TypeScript work with durable signals such as `.ts` or `.tsx` files,
`tsconfig*.json`, TypeScript package scripts, Vitest/MSW files, TypeScript
ESLint config, specs, ADRs, workpad notes, or handoff trail evidence.

This local version intentionally diverges from `EmberAGI/son-of-anton@faf1d5a`
to align with the shared Symphony TDD execution contract. It follows
repo-declared tier placement before defaulting to co-located
`*.unit.test.ts`/`*.int.test.ts`, uses targeted-first/gate-once validation
economics, prefers repo-declared Vitest project/tier/package/file targeting
when present, records compact repo-agnostic test tier semantics, and keeps
agent-visible output bounded through repo-supported log controls.
