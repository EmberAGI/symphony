---
name: browser-use
description: |
  Agent QA-only local Browser Use CLI guidance for browser-facing runtime
  checks, screenshots, page-state inspection, and form-flow evidence without
  Browser Use Cloud, hosted browser infrastructure, provider keys, or new
  operator-provisioned secrets.
---

# Browser Use For Agent QA

Use this skill only when the active Symphony role is Agent QA and the owning
issue has browser-facing acceptance criteria or would materially benefit from
browser runtime checks, UI/manual acceptance support, screenshots, page-state
inspection, form-flow verification, or similar evidence capture.

Do not use this skill for implementer, reviewer, landing, backlog processor, or
operator roles. Do not use it as a general role skill.

## No-Key Boundary

This skill must not require or request:

- `BROWSER_USE_API_KEY`
- Browser Use Cloud
- hosted browser infrastructure
- OpenAI, Anthropic, Google, or other LLM provider keys
- new operator-provisioned API secrets

If a Browser Use feature, agent mode, MCP endpoint, or installed package asks
for one of those keys or hosted services, stop using that path. Choose an
allowed fallback or route to Human Escalation when browser-facing acceptance is
required and no local no-key path can verify it.

## Preferred Local CLI Path

When local prerequisites are present, use Browser Use CLI commands against a
local browser session:

```bash
browser-use open <url>
browser-use state
browser-use click <index>
browser-use type "text"
browser-use input <index> "text"
browser-use screenshot <output-path>
```

Use the smallest browser flow that validates the acceptance criterion. Prefer
deterministic actions and record the page, state, form flow, command output, and
artifact location in the QA handoff. Run `browser-use state` to get the current
page's numbered element indices before interacting. Use `browser-use click
<index>` for indexed elements, `browser-use input <index> "text"` for
click-and-type field filling, and `browser-use type "text"` only when the target
field is already focused.

## Local MCP Fallback

Local stdio MCP is acceptable when it runs without keys or hosted browser
services:

```bash
uvx --from 'browser-use[cli]' browser-use --mcp
```

Use this only as a local controller for browser inspection or automation. Do
not connect to hosted Browser Use MCP or Cloud endpoints for this workflow.

## Artifact Handling

Attach useful browser evidence to Linear for Linear-backed Octo workflows.
Acceptable evidence includes screenshots, page-state summaries, form-flow
notes, command output, logs, and short recordings.

Do not rely on local file paths, GitHub comments, object stores, or other
non-Linear locations as the durable QA artifact store.

Before moving to Human Review, the `## Symphony Handoff` Human Review Packet
must include:

- browser-facing checks in the Validation Matrix;
- every Linear-attached browser artifact in the Artifact Index;
- a clear no-browser or no-artifact rationale when no external browser artifact
  was useful or possible.

## Fallbacks

Use a fallback when Browser Use CLI/MCP is missing, a local browser is missing,
headless execution is blocked, sandbox policy prevents launch, authentication
or third-party data is unavailable, or a desired feature requires a forbidden
key or hosted service.

Allowed fallbacks are:

- existing repository Playwright or browser tooling;
- ordinary manual inspection with concise Linear-attached evidence;
- explicit not-applicable rationale for non-browser issues or environments with
  no usable local browser path;
- Human Escalation when browser-facing acceptance is required and all no-key
  local paths are blocked.

## Octo Workflow Boundaries

Linear repository metadata remains authoritative. Work stays on the issue
branch. PR ownership, state transitions, the Codex Workpad, Symphony Handoff
trail, validation evidence, Linear artifact rules, and Human Escalation routing
remain authoritative.
