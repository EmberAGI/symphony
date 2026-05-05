---
name: pnpm-patching
description: Create and maintain pnpm patch files for third-party dependencies, including minified dist bundles. Use only when durable repo signals show a pnpm project and the issue requires dependency hotfixes, node_modules debugging, or patched CJS/ESM outputs.
---

# Pnpm Patching

## Octo Implementer Use

Use this skill only when the issue scope and repository signals show that a
pnpm-managed dependency patch is needed. Relevant signals include
`pnpm-lock.yaml`, `pnpm-workspace.yaml`, `package.json` `patchedDependencies`,
existing `patches/` files, dependency stack traces, issue notes, specs, ADRs,
the Codex Workpad, or the Symphony Handoff trail.

Do not introduce pnpm patching to unrelated package managers or repositories.
If the source artifacts do not prove that patching a dependency is required,
prefer the repository's existing dependency workflow.

Octo workflow authority remains unchanged: repository metadata, issue branch,
state transitions, PR ownership, workpad, handoff, validation, and
`Human Escalation` routing are authoritative.

## Workflow

- Identify the exact package and version from stack traces or lockfile.
- Run `pnpm patch <pkg>@<version>` to open `node_modules/.pnpm_patches/<pkg>@<version>/`.
- Edit only the needed files inside the patch directory.
- Update both CJS and ESM outputs when the package ships both (commonly `dist/index.js` and `dist/index.mjs`).
- Keep edits surgical; avoid whitespace or formatting changes.
- Run `pnpm patch-commit node_modules/.pnpm_patches/<pkg>@<version>` to generate the patch and update the lockfile.

## Navigating Minified Dependencies

- Capture a stack trace to locate the exact file and offset that fails.
- Use the path from the stack to find the matching file in the patch directory.
- Search for a unique snippet or function name near the failing code and replace only the smallest necessary substring.
- If a minified identifier is undefined (example: `Z`), locate the missing binding or rename it to the correct local function name.
- Mirror the change in both CJS and ESM outputs so server and browser builds stay aligned.

## Patch Stability Tips

- Prefer string-replace edits over reformatting to keep diffs tiny.
- If the patch directory already exists, either `pnpm patch-commit` or delete it before re-running `pnpm patch`.
- When upstream changes frequently, pin the dependency version until the fix is released.

## Verification

- Restart dev/test processes that consume the dependency.
- Confirm the error is gone and the patched behavior runs end-to-end.
- Re-check that the patch applies cleanly after `pnpm install`.
