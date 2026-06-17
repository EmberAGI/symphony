---
name: nodejs
description: Node.js runtime policy for implementer role work. Use only when durable repo signals show a Node.js project and work touches `package.json`, runtime scripts, module-system behavior, environment loading, or server-side JavaScript execution.
---

# Node.js

## Octo Implementer Use

Use this skill only when the owning issue, Codex Workpad, Symphony Handoff
trail, specs, ADRs, or repository files show that Node.js runtime behavior is
in scope. Durable repository signals include `package.json`, lockfiles,
Node-specific config, JavaScript server entrypoints, runtime scripts, or
existing Node.js workflow docs.

Do not impose Node.js conventions on repositories or issues that do not already
use Node.js or explicitly request Node.js. Existing repo scripts, package
manager choices, module-system decisions, and runtime docs take precedence over
generic guidance here.

Octo workflow authority remains unchanged: repository metadata, issue branch,
state transitions, PR ownership, workpad, handoff, validation, and
`Human Escalation` routing are authoritative.

## Scope

Use this skill for Node.js runtime and project policy. Keep language-specific rules out of this skill, and do not use it for alternative JavaScript runtimes.

## Runtime Defaults

- Treat Node.js as the runtime for server-side JavaScript projects in this ecosystem.
- When a Node.js repo's durable signals show pnpm is the selected package manager, use `pnpm` for package management and script execution.
- Prefer explicit package scripts over ad hoc shell commands for repeatable project workflows.
- Keep runtime behavior aligned with the repo's established module system. Do not flip between ESM and CommonJS casually.
- For newly introduced runtime surfaces, prefer modern Node defaults when the repo is not already committed to an older pattern.
- Prefer Node's native capabilities before adding extra runtime dependencies when the standard library already covers the need.

## Project Structure

- Keep runtime entrypoints, scripts, and build output explicit in `package.json`.
- Prefer Node's built-in `.env` loading instead of adding `dotenv` when the runtime surface can use the native flag or equivalent package script wiring.
- Keep environment loading and runtime configuration consistent with the repo's existing approach.
- When a repo uses a generated workspace or supporting scripts, preserve the existing runtime surfaces instead of inventing parallel ones.

## Dependency And Script Policy

- Do not introduce a different package manager into a Node.js repo in this ecosystem.
- Keep linting, formatting, tests, and build steps as separate scripts so automation remains predictable.
- Preserve public default command names unless the Linear issue explicitly
  scopes a durable rename or command-surface change.
- Do not add package scripts, env examples or templates, task-runner or cache
  config, runtime helpers, or wrapper scripts solely for agent validation
  convenience. Use the repo's existing command surface and record any measured
  blocker before proposing durable automation changes.

## Validation

- After changing Node.js runtime code or repo automation, run the relevant package scripts instead of one-off substitutes.
- While iterating, use targeted package or runtime scripts that exercise the
  changed behavior. Near handoff, run the repo's established gate for lint,
  test, build, or runtime validation as applicable.
- In pnpm repos, `pnpm lint:fix` and `pnpm build` are the preferred script forms when those scripts exist.
