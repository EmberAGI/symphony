---
name: testing
description: Apply Octo's cross-language integrity rules for test doubles, fixtures, provider stubs, and external-provider integration evidence. Use when implementing, reviewing, or verifying tests that depend on doubles, fixtures, mocks, HTTP handlers, provider responses, or claimed provider-contract evidence.
---

# Testing Integrity

Use this skill with the selected repository's test commands, conventions, and
the Implementer's `$tdd` method when applicable. This skill owns exactly two
cross-language integrity rules.

## 1. Do Not Reimplement Application Decisions In Test Infrastructure

Test doubles, fixtures, HTTP handlers, and provider stubs may model transport
and provider responses. They must not reproduce application validation,
policy, result calculation, or other business decisions in a way that can make
a broken implementation pass.

Keep the production Interface under test as the place where application
behavior is decided. A substitute may supply an input, capture an output, or
emulate a real boundary; it must not independently compute the application's
expected answer.

## 2. Require Provenance For External-Provider Evidence

An external-provider fixture counts as provider integration evidence only when
its contract shape has authoritative provenance, such as provider
documentation, a published schema, or a captured real response.

Speculative fixtures must be labeled provisional. They may support local
development, but they must not be reported as proof that the provider
integration works.

## Scope Boundary

This initial Interface does not define determinism or isolation policy, test
tiers, concurrency, integration-boundary design, runner commands, recording or
replay mechanics, fixture lifecycle, MSW behavior, Zod behavior, or other
language-specific conventions. Use selected-repository authority and the
applicable language or framework skill for those concerns. Surface conflicts
instead of expanding this skill during issue work.
