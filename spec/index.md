# Spec Index

Canonical specs are organized by durable product or system area. Linear issue
IDs belong in references and decision logs, not canonical filenames.

Use this index when deciding where durable behavior belongs. `spec/` and
`spec/adr/` are the source-of-truth layer for agents and reviewers.

## Domains

- [Symphony Service](./domains/symphony-service.md): Language-agnostic service
  specification for the workflow loader, config layer, tracker integration,
  orchestrator, workspace manager, agent runner, observability, validation, and
  optional worker extensions.
- [Agent Runtime](./domains/agent-runtime.md): Provider-neutral coding-agent
  runtime contract, runtime selection, Codex/Claude Code/Pi adapter
  requirements, runtime-native skills and tools, normalized events, artifacts,
  and Octo mixed-runtime validation.
- [Repository Quality Assurance](./domains/repository-quality-assurance.md):
  Repo-level minimum acceptance suite for durable behavior changes, including
  shared role
  skill source validation, Symphony/Octo workflow-boundary validation, Agent QA
  browser-facing validation, evidence capture, artifact handling, and fallback
  behavior.
- [Symphony Handoff Artifacts](./domains/symphony-handoff-artifacts.md):
  Symphony-local consumer reference for Octo-owned handoff-artifact behavior,
  including source-of-truth provenance, local deltas, and anti-fork guardrails.

## ADRs

ADRs live under `spec/adr/` and are created lazily when a decision is hard to
reverse, surprising without context, and the result of a real trade-off.

- [0001: Provider-Neutral Agent Runtimes](./adr/0001-provider-neutral-agent-runtimes.md)
- [0002: Claude Code Unattended Runtime Authentication and Permission Posture](./adr/0002-claude-code-unattended-auth-and-permission-posture.md)
