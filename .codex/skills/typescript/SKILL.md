---
name: typescript
description: TypeScript policy for implementer role work. Use only when durable repo signals show TypeScript is in scope and work touches TypeScript code, config, tests, ESLint rules, compiler behavior, or HTTP replay handlers such as MSW.
---

# TypeScript

## Octo Implementer Use

Use this skill only when the owning issue, Codex Workpad, Symphony Handoff
trail, specs, ADRs, or repository files show that TypeScript implementation or
tooling is in scope. Durable repository signals include `.ts` or `.tsx` files,
`tsconfig*.json`, TypeScript package scripts, Vitest/MSW files, ESLint config
for TypeScript, lockfiles, or TypeScript-specific handoff notes.

Do not impose TypeScript conventions on JavaScript-only, Python, Elixir, or
other repositories unless the issue explicitly asks for TypeScript migration or
new TypeScript surfaces.

Octo workflow authority remains unchanged: repository metadata, issue branch,
state transitions, PR ownership, workpad, handoff, validation, and
`Human Escalation` routing are authoritative.

## Scope

- Use this skill for TypeScript language and toolchain policy.
- Pair it with the active runtime policy for the repo instead of assuming one JavaScript runtime.

## Language And Runtime Defaults

- Target `ES2022`.
- Use `NodeNext` module resolution.
- Keep strict type-checking enabled.
- Keep source maps enabled for debugging.
- Use `tsx` for development execution when package scripts need a TypeScript runtime.

## Code Quality Rules

- Never use `any`.
- Never use Zod `.passthrough()`.
- Import and reuse existing interfaces and types instead of redefining them.
- Validate external structured inputs and outputs at application boundaries
  using the repo's established schema validation library. In TypeScript repos
  that already use Zod, use Zod.
- If relative imports are emitted into built JavaScript, keep the required `.js` extension in source imports.

## External Structured Input Validation

- Treat parsed config files, provider/API payloads, process/env-derived
  structured config, persisted local files, and other untrusted or externally
  supplied structured data as external boundaries.
- Parse wire and file formats with a structured parser first, such as JSON,
  TOML, YAML, CSV, or URL/form parsers. Treat the parsed result as `unknown`
  until it is validated.
- Validate the parsed value with the repo's established schema validation
  library, then map the validated result to internal domain types or
  env-shaped runtime config.
- Do not hand-roll ad hoc shape checks when a schema library is already
  established in the repo, unless the reason is documented in the code or
  issue evidence.
- Keep this boundary validation out of MSW handlers and mock loaders that
  should replay recorded payloads unmodified.

## Testing Stack

- Use Vitest for new tests.
- Follow the target repo's documented test-tier placement. When no repo
  convention exists, default to co-located `*.unit.test.ts` and
  `*.int.test.ts` files.
- Keep shared test infrastructure in the repo's established shared test-support location.
- If the behavior under test needs an end-to-end surface and one does not exist yet, set one up instead of pretending the coverage is optional.
- Use the repo's declared replay-recording command to record real API
  responses for replay-based integration tests.
- Control test log visibility with `LOG_LEVEL=error`, `LOG_LEVEL=warn`, or `LOG_LEVEL=debug`.

Use the repo's tier vocabulary. In generic terms, unit tests are hermetic and
in-process; integration tests exercise repo wiring through public surfaces with
externals mocked; e2e tests are opt-in live, streaming-paced, browser,
wall-clock, deployed, or full-surface checks and are not the red-green loop.

During iteration, prefer the narrowest repo-declared Vitest project, tier,
package, or single-file command that exercises the behavior. When Vitest
projects exist, use the narrowest project and file invocation that covers the
current slice.

## MSW And Replay Handlers

- Treat MSW handlers as tape recorders, not API simulators.
- Match requests and select the correct recorded fixture, then replay status, headers, and body unmodified.
- Do not transform recorded payloads to fit application expectations.
- Do not add fallback responses when a mock is missing.
- Do not synthesize errors; record and replay real error responses.
- Do not run schema validation in handlers or mock loaders.
- Keep business logic out of handlers.

## Validation Commands

Use targeted-first validation while iterating, then run the established repo
gate once near handoff unless role workflow, stale evidence, or cross-cutting
changes require more. Prefer repo-declared package, tier, project, or
single-file commands for the inner loop.

In pnpm repos, run `pnpm lint:fix` after a completed development slice when
that script exists, and run `pnpm build` near the end of the issue before
opening or updating the PR.

Keep agent-visible output bounded with repo-supported log controls such as
`LOG_LEVEL` plus summaries, tails, and exit codes for long commands.

```bash
pnpm lint:fix
pnpm build
```
