# Browser Use Skill Source

This Agent QA-only skill was added for EMB-187.

Source artifacts:

- Linear EMB-187 issue body and acceptance criteria.
- Linear operator notes from 2026-05-05 requiring Browser Use CLI/local skill
  exposure for Agent QA while preserving the no-cloud/no-key boundary.
- Official Browser Use CLI documentation at
  `https://docs.browser-use.com/open-source/browser-use-cli`, especially
  `state`, `click <index>`, `type "text"`, `input <index> "text"`, and
  `screenshot [path]`.
- Repository workflow and QA contracts in `elixir/WORKFLOW.md` and
  `docs/specs/domains/repository-quality-assurance.md`.
- Symphony handoff artifact contract at
  `/home/admin/scaling-octo-engine/spec/domains/symphony-handoff-artifacts.md`,
  especially the successful QA-to-`Human Review` packet section requirements.

The accepted local command surface is:

- `browser-use open`
- `browser-use state`
- `browser-use click <index>`
- `browser-use type "text"`
- `browser-use input <index> "text"`
- `browser-use screenshot`
- `uvx --from 'browser-use[cli]' browser-use --mcp`

Browser Use Cloud, hosted browser infrastructure, `BROWSER_USE_API_KEY`, LLM
provider keys, and new operator-provisioned secrets are intentionally excluded.
