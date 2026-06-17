---
name: tdd
description: Primary test-driven development loop for implementation work, used by default when the active role workflow requires TDD, red-green-refactor, test-first implementation, or integration-test-first development.
---

# Test-Driven Development

## Octo Implementer Use

Use this skill as the primary development loop for implementation work when
the active role workflow requires TDD, red-green-refactor, test-first
implementation, or integration-test-first development. Role workflows own the
trigger policy; this skill owns how to execute the loop once active.

This skill does not replace Octo workflow authority. Linear repository
metadata, the issue branch, state transitions, PR ownership, legacy
`## Codex Workpad` context when present, immutable `## Symphony Handoff`
fields, validation requirements, and `Human Escalation` routing remain
authoritative. If this skill conflicts with issue instructions, specs, ADRs,
or handoff guidance, record the conflict and route per the role workflow
instead of silently choosing the skill.

For unattended Symphony implementer runs, treat approval steps as "derive
approval from durable source artifacts already present in the
issue, specs, ADRs, workpad, or handoff." Ask the user only when required
source artifacts are missing, unreadable, or conflicting.

## Philosophy

**Core principle**: Tests should verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't.

**Good tests** are integration-style: they exercise real code paths through public APIs. They describe _what_ the system does, not _how_ it does it. A good test reads like a specification - "user can checkout with valid cart" tells you exactly what capability exists. These tests survive refactors because they don't care about internal structure.

**Bad tests** are coupled to implementation. They mock internal collaborators, test private methods, or verify through external means (like querying a database directly instead of using the interface). The warning sign: your test breaks when you refactor, but behavior hasn't changed. If you rename an internal function and tests fail, those tests were testing implementation, not behavior.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation.** This is "horizontal slicing" - treating RED as "write all tests" and GREEN as "write all code."

This produces **crap tests**:

- Tests written in bulk test _imagined_ behavior, not _actual_ behavior
- You end up testing the _shape_ of things (data structures, function signatures) rather than user-facing behavior
- Tests become insensitive to real changes - they pass when behavior breaks, fail when behavior is fine
- You outrun your headlights, committing to test structure before understanding the implementation

**Correct approach**: Vertical slices via tracer bullets. One test → one implementation → repeat. Each test responds to what you learned from the previous cycle. Because you just wrote the code, you know exactly what behavior matters and how to verify it.

```
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
  ...
```

## Execution Contract

The three laws of TDD:

1. Do not write production logic until a failing test requires it.
2. Do not write more of a test than is sufficient to fail for the current
   behavior.
3. Do not write more production code than is sufficient to pass the current
   failing test.

### 1. Plan Behavior Slices

When exploring the codebase, use the project's domain glossary so that test
names and interface vocabulary match the project's language, and respect ADRs
in the area you're touching.

Before writing implementation logic:

- Identify the public interface or boundary for the change.
- Build a behavior list from acceptance criteria. Each acceptance criterion
  gets at least one red-green-refactor cycle; record discovered extra
  behaviors in the role-owned handoff or evidence surface.
- Identify opportunities for [deep modules](deep-modules.md) and
  [testable interfaces](interface-design.md).
- Derive unattended-run approval from durable source artifacts when humans are
  not in the loop.

You cannot test everything. Focus testing effort on critical paths, complex
logic, and externally observable behavior. Do not add tests whose only value is
checking compiler or type-system guarantees.

### 2. RED

Write exactly one failing test for the current behavior slice.

The current slice's first red test is a tracer test at that slice's declared
boundary: HTTP surface, exported entry point, public module interface, service
method, worker contract, or similar repo-defined public surface. This is
integration-tier by default when the target repo has an integration tier.
Pure-logic slices may be unit-only when the handoff or evidence records the
rationale. This does not mean every test in the issue is integration-tier, and
it never makes e2e part of the red-green loop.

In RED mode, source changes outside tests must be declaration-only: types,
interfaces, empty or throwing stubs, module exports, or equivalent compile
scaffolding. Production logic in a RED diff is a violation.

Run the narrowest command that proves the test fails and capture the failure
excerpt for the behavior. Assertion-level red evidence is required at least
once per behavior. Compile-failure counts as red only for scaffold steps before
the behavior can reach an assertion.

### 3. GREEN

Write the minimal implementation needed for the current test to pass.

Rules:

- One failing test per iteration.
- Minimal implementation per slice.
- No speculative features.
- No broad refactors while RED.
- Keep tests focused on observable behavior through public interfaces.

After the narrow test passes, commit or checkpoint at a per-slice cadence when
the role workflow expects commits. Separate red-only commits are not required:
failing commits harm bisect and revert hygiene, so captured red excerpts carry
the audit burden.

### 4. Refactor And Harden

After the current slice is GREEN, look for [refactor candidates](refactoring.md):

- Extract duplication.
- Deepen modules by moving complexity behind simple interfaces.
- Apply SOLID principles where natural.
- Consider what new code reveals about existing code.
- Run targeted tests after each refactor step.

Add one or two edge or negative cases per meaningful boundary after the
tracer path is green. Use property-based tests where pure or branchy logic
warrants it. Coverage is a guardrail, not a target.

## Test Tiers

Use the target repo's documented test tier names, suffixes, budgets, owners,
triggers, placement rules, and gate commands. In generic terms:

- Unit tests are hermetic, in-process, and use fake time when needed. They do
  not use live providers, production secrets, real network calls, or wall-clock
  sleeps.
- Integration tests exercise real repo wiring through public module boundaries
  while still avoiding live providers, production secrets, real external
  network calls, and wall-clock sleeps. They should prefer fake timers, local
  mocks, record/replay fixtures, stub servers, or equivalent seams for clocks,
  randomness, network, process, and provider behavior.
- E2e tests cover live, streaming-paced, wall-clock, browser, CLI, deployed, or
  other full-surface behavior.

E2e or other opt-in suites are never the red-green loop. Use them as
acceptance or release evidence when the repo or issue calls for them. Repos
that maintain e2e, live, or opt-in suites should document their trigger,
owner, budget, and required environment.

When repo-level parallelism is expected, integration tests should isolate ports,
temporary directories, databases, queues, caches, and other mutable state per
test worker or process. If the repo has a flake, quarantine, retry, or skip
convention, use it only with an explicit owner, rationale, and follow-up path
instead of hiding an unknown failure.

## Loop Economics

Iterate with the narrowest test file, project, package, or tier command that
exercises the current behavior. Run the full repo gate once near handoff unless
the role workflow, stale evidence, or a cross-cutting change requires more.

If the repo declares affected or cached task-runner commands through Turbo, Nx,
Vitest projects, package filters, or another runner, use those paths instead of
bypassing them with ad hoc broad recursion. Do not invent script names; use the
repo's declared script contract.

Bound long agent-visible output with summaries, tails, exit codes, and
repo-supported log controls such as `LOG_LEVEL`. Preserve enough failure text
to make the red/green evidence reviewable without streaming full logs into the
conversation.

## Mocking Doctrine

Mock external providers, network services, clocks, randomness, process
boundaries, and other nondeterministic dependencies. Prefer real code through
owned public interfaces. Use fakes only at real seams or adapters.

Do not mock private helpers, internal collaborators, or implementation details
as a substitute for behavior coverage. External HTTP should use the target
repo's standard MSW, stub-server, record-replay, or equivalent convention.

## Skill Evaluation Carve-Out

Repo-owned skill packages may validate through `skill-creator` evals when
RED/GREEN unit tests are not the right behavior surface. Skill behavior and
quality should be evaluated with realistic prompt-based evals and human review
rather than brittle string-matching tests as the primary validation path.

## Checklist Per Cycle

```
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only
[ ] Test would survive internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
```
