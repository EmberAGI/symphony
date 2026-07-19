# 0002: Claude Code Unattended Runtime Authentication and Permission Posture

Date: 2026-06-10

## Status

Accepted for EMB-166 intake readiness.

## Context

ADR 0001 establishes the provider-neutral adapter contract and makes Claude
Code the first non-Codex runtime delivered for Octo roles. Octo's production
role stack runs unattended on an operator-managed host, so enabling Claude
Code there forces two trust decisions that are easy to under-document and
surprising without context:

- How the runtime authenticates: a repository- or environment-provisioned
  `ANTHROPIC_API_KEY`, or an operator-managed Claude subscription OAuth login
  that lives only on the role host.
- What permission posture unattended runs use: Claude Code's interactive
  permission prompts, an additional sandbox layer, or bypass-permissions mode
  with no extra sandbox.

Both were decided by the operator during the EMB-166 re-grill (2026-06-10) and
are currently recorded as constraint bullets in `docs/specs/domains/agent-runtime.md`
and the Octo wrapper `scaling-octo-engine`'s `spec/domains/symphony-role-runtime.md`. The decisions
are the result of real trade-offs, shape credential lifecycle and escalation
behavior, and have consequences (a security posture, an expiring credential on
a headless host) that outlive the implementation, so they warrant an ADR
rather than spec bullets alone.

## Decision

The Claude Code runtime for unattended Octo roles authenticates via
operator-managed Claude subscription OAuth on the role host:

- No `ANTHROPIC_API_KEY` or other operator-provisioned API secret is
  introduced for role traffic. Login and credential material stay outside the
  repository.
- No OAuth tokens, API keys, or other credentials may appear in the
  repository, prompts, transcripts, or logs.
- An expired or missing credential fails closed with an operator-visible error
  that routes to the Human Escalation path. A role launch must never hang or
  silently degrade because the subscription login lapsed.

Unattended Claude Code role runs execute in bypass-permissions mode with no
additional sandbox layer:

- Runs are fully non-interactive. The adapter must never block a role turn
  waiting on an interactive permission approval.
- The trust boundary is the role host plus the Octo workflow gates, not a
  runtime sandbox. The non-negotiable skills/tools gate (ADR 0001) — role
  skill materialization, controlled tool execution, normalized tool failures,
  and the no-secret-leakage contract proven by smoke/contract checks — remains
  the release gate before Claude Code is enabled for unattended roles.

## Consequences

Subscription OAuth on a headless host can expire and require operator
re-login. That is an accepted operational cost; the fail-closed launch
behavior plus Human Escalation notification is the mitigation, and operators
should expect occasional re-login interventions instead of silent failures.

Running bypass-permissions with no sandbox means a misbehaving or compromised
role run has the same reach as the role host user. Host-level isolation,
repository allowlisting, and the workflow gates carry the safety burden that a
sandbox would otherwise share. Reviewers and QA must treat secret-leakage and
uncontrolled-tool findings as gate failures, not style issues.

Switching later to provisioned API keys, interactive approval, or a sandboxed
execution layer would change the cost model, credential lifecycle, escalation
behavior, and security posture together; such a reversal needs a new ADR.

## Alternatives Considered

- Provisioned `ANTHROPIC_API_KEY` for role traffic. Rejected by the operator:
  it introduces a new provisioned secret with separate billing and lifecycle,
  while the subscription login is already operator-managed; the integration
  must not require new operator-provisioned API secrets.
- Interactive permission approval. Rejected: unattended role runs must be
  fully non-interactive; a blocked permission prompt stalls the role stack.
- Additional sandbox layer around Claude Code. Rejected for this slice: the
  effective trust boundary is the role host and the Octo workflow gates; a
  sandbox would add failure modes for unattended runs without covering the
  decisions that actually gate enablement (skills/tools gate, no-secret
  contract).

## References

- [ADR 0001: Provider-Neutral Agent Runtimes](./0001-provider-neutral-agent-runtimes.md)
- [Agent Runtime](../specs/domains/agent-runtime.md)
- Octo wrapper `scaling-octo-engine` `spec/domains/symphony-role-runtime.md`
  (Claude Code runtime role model configuration)
- [EMB-166: Integrate Claude Code as an Octo Symphony role runtime](https://linear.app/emberai/issue/EMB-166/integrate-claude-code-as-an-octo-symphony-role-runtime)
