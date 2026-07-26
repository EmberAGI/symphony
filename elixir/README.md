# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
the canonical specs under [`../docs/specs/`](../docs/specs/). Start with
[`../docs/specs/index.spec.html`](../docs/specs/index.spec.html) and the service spec at
[`../docs/specs/domains/symphony-service.md`](../docs/specs/domains/symphony-service.md).

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on the canonical specs under `docs/specs/`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Obtain any optional role skills from their owning orchestration repository;
   Symphony does not distribute an Octo role skill pack.
   - A separately supplied `linear` skill may use Symphony's `linear_graphql`
     app-server tool for raw Linear GraphQL operations such as comment editing
     or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

### Atomic cutover bootstrap

When Octo performs an atomic cutover, its wrapper supplies
`SYMPHONY_EXECUTION_GENERATION` and, when the orchestration root is not used,
`SYMPHONY_WORK_ADMISSION_PATH` to the Symphony process. The marker path is
otherwise derived as
`$SYMPHONY_ORCHESTRATION_ROOT/.runtime/symphony/work-admission.json`. Symphony
only reads and atomically writes that small admission marker; the wrapper owns
generation construction, close/drain, process materialization, and verified
reopen. A configured missing or invalid marker starts Symphony closed, so the
wrapper must explicitly open the matching generation after verification.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

### Runtime selection (Codex or Claude Code)

Codex is the default and reference runtime. Symphony can instead run role turns
through a first-party Claude Code shim (`claude-app-server`) that drives the
local `claude` CLI behind the same app-server contract. Select the runtime with
`agent_runtime.provider` and configure the shim with a `claude_code` block:

```yaml
agent_runtime:
  provider: claude_code
  skill_execution_contracts:
    - skill: linear
      package_root: /opt/octo/.agents/skills/linear
      runtime_inputs: [/opt/octo/pyproject.toml, /opt/octo/uv.lock]
      tool_executables: [/opt/octo/bin/uv]
claude_code:
  command: claude
  model: sonnet
  effort: high          # one of: low, medium, high, xhigh, max
  no_thinking: true     # maps to MAX_THINKING_TOKENS=0 (Fable 5 cannot disable thinking)
  permission_mode: bypassPermissions
```

Notes:

- Omitting `agent_runtime` (or setting `provider: codex`) keeps the existing
  Codex behavior unchanged.
- `skill_execution_contracts` is supplied by the integrating workflow and is
  provider-neutral. Each record registers one exact skill package root, its
  locked runtime inputs, and its executable tools. Symphony validates local or
  remote materialization before provider work, rejects selected-workspace and
  broad orchestration roots, then gives Codex and Claude Code only the exact
  read-only paths. Skill activation and source ownership remain outside
  Symphony.
- The shim authenticates via operator-managed Claude subscription OAuth on the
  role host; it never reads, stores, or logs an `ANTHROPIC_API_KEY` or OAuth
  token. An expired or missing credential fails closed with an operator-visible
  error instead of hanging.
- Unattended runs use `bypassPermissions` with no extra sandbox and stay fully
  non-interactive. Invalid `effort` values and disabling thinking on a model
  that cannot (Fable 5) are rejected at config validation.

### Irrecoverable runtime failures

Symphony classifies runtime failures before ordinary retry scheduling. The
exact recoverable shapes are atom or two-tuple `turn_timeout`, `network_error`,
`service_unavailable`, `rate_limited`, `capacity_unavailable`, and
`operator_interrupted`; two-tuple `empty_turn_completed`,
`turn_input_required`, `approval_required`,
`implementer_hard_budget_exhausted`, `implementer_agent_stalled`, and
`implementer_agent_unobservable`; `workspace_hook_timeout/3`;
`workspace_hook_failed/4` with status `75`; and routing, remote-command, or
status-read wrappers only when their nested failure is one of those exact
recoverable shapes. Unknown failures fail closed; error text or tuple names
that merely contain words such as `timeout` do not widen the allowlist. In
particular, bare or supervision-wrapped `herdr_agent_status_timeout` is an
irrecoverable typed workspace/runtime-protocol failure.

Irrecoverable failures do not consume the ordinary retry loop. The orchestrator
verifies and marks same-scope process ownership `blocked`, records a compact
run-log event when run logging is configured, applies the `Human Escalation`
label, and moves the issue to `Human Escalation` when that state exists. This
path neither reads nor writes Linear comments. After repairing credentials,
configuration, missing tools, permissions, workspace/protocol state, or
provider event handling, record the material issue/branch/workspace input
change and move the issue back to the appropriate active role state, or deploy
a new verified execution generation. Merely moving an unchanged issue back to
an active state remains blocked.

Before the first failure-driven redispatch, Symphony re-reads durable
process-ownership evidence. An unchanged checkpoint with the identical failure
fingerprint and no reset evidence is blocked before another run starts. If an
already-started replacement run inherits that observation and later exits
normally, that exit does not erase the prior typed failure or enter the
normal-completion path when its reset marker is unchanged, regardless of
reconstructed retry-attempt metadata. A verified successful retry after changed
material issue/branch/workspace input or execution generation is a distinct run
and clears the prior observation at terminal settlement. The orchestrator
passes that current marker into ownership acquisition, which may replace a
blocked record only when the stored marker differs, even after holder death or
a role-service restart. The automatically applied `Human Escalation` label does
not change that marker. Clean continuation checks do not carry or consult stale
failure observations.

The fail-closed default intentionally sends previously generic workspace/setup,
maximum-turn, cleanup/settlement, supervisor, exception, and future adapter
failures to the blocked Human Escalation path. Operators should repair the
underlying condition and materially update durable issue/workspace input or
deploy a new execution generation; infrastructure-sounding names and timeout
prose do not authorize another run.

### Comment-independent role-run ownership

Candidate selection and dispatch use Linear issue state only. Before a local
worker starts, Symphony atomically acquires the exact issue/workspace/role scope
through `Runtime.ProcessOwnership`; a conflicting or malformed record fails
closed, and holder/run-mismatched updates or releases are rejected. Remote
worker dispatch is unsupported in this V1 and fails closed.

Provider processes receive the exact ownership-record path through
`SYMPHONY_ROLE_OWNERSHIP_PATH`. Runtime consumers must read that value rather
than reconstructing the path. Retry, recovery, cleanup, quarantine,
escalation, and status reuse the verified record. Deleting every Linear issue
comment does not change dispatch or generation-fence behavior.

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/worktree_init.sh`: repository-local Codex workspace setup helper

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
