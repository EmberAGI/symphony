# Browser Use Skill Source

This Agent QA-only skill was added for EMB-187.

Source artifacts:

- Linear EMB-187 issue body and acceptance criteria.
- Linear operator notes from 2026-05-05 requiring Browser Use CLI/local skill
  exposure for Agent QA while preserving the no-cloud/no-key boundary.
- Repository workflow and QA contracts in `elixir/WORKFLOW.md` and
  `spec/domains/repository-quality-assurance.md`.

The accepted local command surface is:

- `browser-use open`
- `browser-use state`
- `browser-use click`
- `browser-use type`
- `browser-use screenshot`
- `uvx --from 'browser-use[cli]' browser-use --mcp`

Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, LLM
provider keys, and new operator-provisioned secrets are intentionally excluded.
