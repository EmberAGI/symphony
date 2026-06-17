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

Use the target repo's declared script contract. When a repo standardizes common
package scripts, keep their meanings predictable:

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

- Use package-filtered, tier-specific, project-specific, or single-file
  commands while iterating when the repo exposes them.
- Reserve repo-root `test`, `test:ci`, build, and other broad gate commands
  for pre-handoff validation unless the role workflow or issue requires an
  earlier gate.
- Prefer the repo's declared affected or cached task-runner path when present,
  such as workspace task commands, affected commands, package filters, or
  project filters. Do not bypass that path with raw recursive per-package
  commands unless the repo has no declared path or the issue is explicitly
  repairing the task-runner path.
- Prefer `pnpm <script>` or `pnpm --filter <pkg> <script>` for task execution
  when that matches the repo's script contract.
- Raw `pnpm --filter` package, dependent, or changed-workspace filters are
  acceptable validation evidence when the repo has no durable affected command.
  Record the selected packages or projects, the filter or command shape, and
  useful timing evidence when reporting validation.
- Do not introduce new script names such as `list:affected`, `test:affected`,
  or equivalent workflow helpers only to satisfy this skill; use the repo's
  declared script contract or raw pnpm filters as bounded evidence.
- Before proposing Turbo, Nx, another cache/task runner, helper scripts, or
  task-runner config, optimize and measure the existing pnpm or package-runner
  path. A fallback needs measured blocker evidence and issue or operator scope
  approval.
- When a repo's `.rulesync/` content or workflow docs change, use that repo's
  documented regeneration command.
