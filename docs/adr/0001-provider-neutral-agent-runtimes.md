# 0001: Provider-Neutral Agent Runtimes

Date: 2026-05-04

## Status

Accepted for EMB-166 intake readiness.

## Context

Symphony currently describes its execution path around Codex app-server. Octo
needs Symphony to run real role workflows with a mix of Codex, Claude Code, and
Pi workers while preserving the existing Codex path and keeping Octo workflow
policy outside provider-specific adapters.

The reviewed Claude Code work shows that a small app-server-compatible adapter
can bridge Claude Code into Symphony, but the useful parts are the adapter
boundary, session/thread model, cancellation, permission handling, and Symphony
compatibility behavior rather than the external fork as an ownership base.

The reviewed Pi work shows that Pi has a native JSONL RPC mode. Forcing Pi
through a Codex-shaped protocol would hide useful provider semantics and make
skills, extensions, cancellation, and artifacts harder to reason about.

Octo also requires skills and tools to work in unattended runs. A provider is
not useful if role skills cannot load, required tools cannot execute, tool
failures stall the run, artifacts/proof are not collectible, or credentials leak
into prompts or logs.

## Decision

Symphony will use a provider-neutral runtime adapter contract between the Agent
Runner and concrete coding-agent providers.

The required Octo multi-runtime providers are:

- `codex`, preserving the existing Codex app-server path as the reference
  runtime.
- `claude_code`, implemented as a first-party Symphony adapter or shim informed
  by the reviewed Claude app-server work.
- `pi`, implemented as a native Pi JSONL RPC adapter.

Adapters expose the same logical lifecycle to Symphony:

- start or resume a session in the selected workspace;
- run the initial turn and continuation turns;
- send follow-up input where supported;
- cancel and stop sessions;
- normalize provider-native events;
- collect declared artifacts and proof.

Runtime config selects the provider and declares command, environment,
permission policy, tool bundle, artifact policy, and capability information.
Provider-specific config is still allowed, and the existing `codex` config
remains the backward-compatible default for Codex.

For configured skills with executable resources, the provider-neutral runtime
boundary also carries a resolved skill execution contract. The integrating
workflow registers the exact skill package root, locked runtime inputs, and
external tool executables; `AgentRuntime` validates and propagates the same
contract to top-level roles, Implementer orchestrators, and workers. Provider
adapters translate only those entries into native discovery, read, execute,
environment, or launch permissions. They do not grant the enclosing
orchestration checkout, runtime state, provider authentication, production
configuration, or unregistered sibling resources.

The selected product workspace remains the writable repository and evidence
authority. Registered skill execution resources are read-only orchestration
inputs. Symphony owns this runtime propagation seam, while Octo owns its skill
inventory, registration manifest, activation policy, and provider-native
evaluation.

Working skills and tools are a release gate. A runtime must not be enabled for
unattended Octo use until role skills load or translate correctly, required
tools execute through controlled runtime-native mechanisms, tool failures
normalize, and secrets are not exposed through prompts or logs.

## Consequences

This adds adapter complexity, but keeps the orchestrator stable while allowing
provider-specific protocols to remain native.

Codex remains backward compatible and continues to be the reference runtime for
behavior and tests.

Claude Code and Pi can evolve independently behind the adapter contract without
forcing every provider to emulate Codex app-server internally.

Octo can mix providers across roles only after skills, tools, normalized events,
artifacts/proof, and failure behavior are validated for each enabled runtime.

Adding executable resources now requires explicit registration and
provider-native projection tests, but avoids relying on ambient host access or
granting a whole orchestration checkout to make one skill runnable.

## Alternatives Considered

- Keep Symphony Codex-only.
  This preserves simplicity but prevents Octo from using Claude Code or Pi.
- Rebase Octo onto an external Claude Code Symphony fork.
  This would import useful compatibility behavior but would weaken ownership of
  Ember's Symphony fork and make upstream synchronization harder.
- Force every provider through a Codex-shaped app-server protocol.
  This provides a single transport shape, but it hides native Pi RPC and Claude
  Code behavior and makes provider-specific skills, tools, cancellation, and
  artifacts harder to implement correctly.
- Treat tools and skills as follow-up polish.
  This is unsafe for unattended Octo roles because provider runs would appear
  enabled before they can actually perform required workflow operations.
- Grant the complete orchestration checkout to every provider session.
  Rejected because a configured skill's executable dependencies are narrower,
  the product workspace must remain the sole writable evidence authority, and
  runtime/auth/config paths must not become incidental provider inputs.

## References

- EMB-166: https://linear.app/emberai/issue/EMB-166/implement-multi-runtime-symphony-support-for-codex-claude-code-and-pi
- EMB-1199: https://linear.app/emberai/issue/EMB-1199/expose-registered-skill-runtime-paths-to-every-managed-role
- [Agent Runtime](../specs/domains/agent-runtime.md)
- [Symphony Service](../specs/domains/symphony-service.md)
- https://github.com/sumansid/claude-app-server
- https://github.com/sapsaldog/claude-app-server
- https://github.com/sapsaldog/symphony
- https://github.com/badlogic/pi-mono
- https://github.com/tmustier/pi-symphony
- https://github.com/gannonh/kata
