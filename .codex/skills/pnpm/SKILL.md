---
name: pnpm
description: pnpm package-management policy for implementer role work. Use only when durable repo signals show pnpm is the selected package manager and work touches dependencies, lockfiles, workspace scripts, install commands, or package-manager decisions.
---

# Pnpm

## Octo Implementer Use

Use this skill only when the owning issue, Codex Workpad, Symphony Handoff
trail, specs, ADRs, or repository files show that pnpm package management is in
scope. Durable repository signals include `pnpm-lock.yaml`,
`pnpm-workspace.yaml`, `packageManager` fields naming pnpm, `.npmrc` pnpm
settings, existing pnpm scripts, or pnpm patch metadata.

Do not impose pnpm on repositories that use npm, yarn, bun, uv, mix, cargo, or
another package manager unless the issue explicitly asks for a migration and
the acceptance criteria cover it.

Octo workflow authority remains unchanged: repository metadata, issue branch,
state transitions, PR ownership, workpad, handoff, validation, and
`Human Escalation` routing are authoritative.

## Core Policy

- Inside repos where pnpm is already the selected package manager, use `pnpm` only and do not switch to `npm`.
- Install dependencies with `pnpm add` or `pnpm add -D`.
- Do not edit dependency entries in `package.json` by hand.
- Use `pnpm install --frozen-lockfile` in CI or other non-interactive install flows.
- Use `pnpm patch` and `pnpm patch-commit` when a third-party dependency needs an in-repo hotfix instead of editing `node_modules` ad hoc.

## Script Contract

Every package should expose these scripts so workspace-level automation stays predictable:

- `lint`
- `lint:fix`
- `format`
- `format:check`
- `test`
- `test:watch`
- `test:ci`
- `build`

Repos may also define more specific scripts such as:

- `test:unit`
- `test:int`
- `test:e2e`
- `test:coverage`
- `test:record-mocks`

## Lint And Format Separation

- `lint` should check only; it should not rewrite files.
- `lint:fix` may apply lint auto-fixes.
- Keep formatting in `format` and `format:check`, not inside lint scripts.

## Workflow Notes

- Prefer `pnpm <script>` or `pnpm --filter <pkg> <script>` for task execution.
- When a repo's `.rulesync/` content or workflow docs change, use that repo's documented regeneration command. In Son of Anton source workspaces, that command is `pnpm renew:forge`.
