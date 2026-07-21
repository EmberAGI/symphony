# Symphony Handoff Artifacts

Status: Draft v1

Purpose: Provide a Symphony-local reference point for Octo-managed handoff
artifact behavior without forking Octo's normative handoff-artifacts contract.

## Source of Truth

Octo owns the normative handoff-artifacts contract at:

```text
EmberAGI/scaling-octo-engine:docs/specs/domains/symphony-handoff-artifacts.md
```

Symphony agents use this document only as a local consumer reference so the
required spec-read contract can be satisfied inside the Symphony repository.
This file MUST NOT copy the full Octo contract or become an independently
maintained source of truth for Octo handoff packet behavior.

## Provenance

- Upstream owner: `EmberAGI/scaling-octo-engine`
- Upstream path: `EmberAGI/scaling-octo-engine:docs/specs/domains/symphony-handoff-artifacts.md`
- Local reference introduced for EMB-185 on 2026-05-05 after operator
  escalation resolution.
- Reference basis: Linear EMB-185 operator note dated 2026-05-05T21:05:00Z.

When Octo pins or updates its source contract, Symphony should keep this
reference section current with the upstream repository/path or the deployed
Octo version that supplied the requirement. The upstream contract remains
authoritative when this local reference and Octo policy differ.

## Local Deltas

No Symphony-specific local deltas are defined.

If a future Symphony change needs local behavior that differs from Octo's
source contract, that change MUST record the delta in this section and update
the relevant branch-local specs before relying on it in QA, review, or landing.
ADR-worthy or ADR-conflicting deltas MUST route to Human Escalation with the
relevant `docs/adr/` reference or missing ADR decision.

## Consumer Contract

For Octo-managed Symphony issues, agents and reviewers SHOULD read this file
when a workflow requires handoff-artifact spec context. They SHOULD then follow:

- the current Linear issue body and handoff trail;
- the repository workflow in `elixir/WORKFLOW.md`;
- the repository QA contract in `docs/specs/domains/repository-quality-assurance.md`;
- Octo's upstream handoff-artifacts contract when detailed artifact packet
  behavior is needed.

This file is intentionally limited to source identification, provenance, local
delta tracking, and anti-fork guidance.

## Successful QA Packets

When an Octo-managed Symphony issue moves successfully from `Agent QA` to
`Human Review`, QA MUST follow Octo's upstream handoff-artifacts contract for
the human-review packet. The local workflow MUST NOT redefine that contract,
but it MUST require these upstream packet sections by name: Review Focus,
Executive Summary, Action Log, Validation Matrix, Artifact Index, Environment
and Provenance, Known Limitations, and Merge Readiness.

The Artifact Index is mandatory even when no external artifact is useful for
the issue; in that case it states that no external artifact was useful and
gives the rationale.

## Anti-Fork Guard

Changes to this file MUST preserve all of the following unless an operator
explicitly reassigns ownership of the handoff-artifacts contract:

- Octo's `EmberAGI/scaling-octo-engine` spec path is identified as the source
  of truth.
- Symphony-local deltas are explicit.
- The full Octo contract is not copied into this repository.

## References

- [Repository Quality Assurance](./repository-quality-assurance.md)
- [Spec Index](../index.spec.html)
