# Role Skill Exposure

This directory describes Symphony-owned shared role skill exposure metadata.
The Octo wrapper pins this repository as `third_party/symphony` and is expected
to expose only the skills listed for each workflow role.

Root `.codex/skills/` is the shared skill source. Role manifests in this
directory are the default exposure contract for localized upstream-derived
skills until a wrapper-specific manifest pins and links them.

## Implementer

[`implementer.json`](implementer.json) exposes the EMB-186 localized upstream
skill pack to the implementer role only:

- [`tdd`](../skills/tdd/SKILL.md)
- [`frontend-design`](../skills/frontend-design/SKILL.md)
- [`nodejs`](../skills/nodejs/SKILL.md)
- [`pnpm-patching`](../skills/pnpm-patching/SKILL.md)
- [`pnpm`](../skills/pnpm/SKILL.md)
- [`python`](../skills/python/SKILL.md)
- [`typescript`](../skills/typescript/SKILL.md)

No reviewer, QA, landing, or backlog-processor manifest should include these
skills by default. If a future issue intentionally expands exposure, that issue
must update this contract, the relevant wrapper manifest, and validation.

## Omitted Upstream Siblings

EMB-186 intentionally localizes only the upstream directories named in the
issue. Other Matt Pocock skills, Anthropic skills, and Son of Anton `.rulesync`
skills are omitted because they are not acceptance criteria for this child and
would broaden the implementer role surface without a reviewed Octo workflow
contract.
