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

## Agent QA

[`qa.json`](qa.json) exposes the EMB-187 Browser Use skill to Agent QA only:

- [`browser-use`](../skills/browser-use/SKILL.md)

The skill is limited to issue-appropriate local browser evidence capture with
Browser Use CLI commands or local stdio MCP. It must not require Browser Use
Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, LLM provider keys,
or new operator-provisioned secrets. Implementer, reviewer, landing, and
backlog-processor manifests must not include this skill by default.

## Backlog Processing Skill Sources

EMB-220 adds the shared [`to-issues`](../skills/to-issues/SKILL.md) skill
source for Octo/Symphony backlog breakdown technique. It is not exposed through
any default role manifest in this repository. Wrapper-side or role-specific
work must explicitly scope any backlog-processor exposure before using it in an
unattended workflow.

## Omitted Upstream Siblings

EMB-186 intentionally localizes only the upstream directories named in the
issue. Other Matt Pocock skills, Anthropic skills, and Son of Anton `.rulesync`
skills are omitted because they are not acceptance criteria for this child and
would broaden the implementer role surface without a reviewed Octo workflow
contract.
