---
name: python
description: Python stack policy for implementer role work. Use only when durable repo signals show a Python project and work touches Python code, packaging, virtual environments, type checking, testing, linting, or command execution.
---

# Python

## Octo Implementer Use

Use this skill only when the owning issue, Codex Workpad, Symphony Handoff
trail, specs, ADRs, or repository files show that Python implementation or
tooling is in scope. Durable repository signals include `.py` files,
`pyproject.toml`, `requirements*.txt`, `uv.lock`, `poetry.lock`, `Pipfile`,
Python test files, Python CI jobs, or Python-specific handoff notes.

Do not impose Python conventions on unrelated repositories or issues. Existing
project tooling and validation commands take precedence over defaults here.

Octo workflow authority remains unchanged: repository metadata, issue branch,
state transitions, PR ownership, workpad, handoff, validation, and
`Human Escalation` routing are authoritative.

## Tooling Defaults

- Use `uv` for environment management, dependency management, and command execution.
- Prefer `pyproject.toml` as the package and tool configuration surface.
- Use `uv add`, `uv remove`, and `uv sync` instead of editing dependency lists by hand when a managed Python project is in scope.
- Use `uv run` for repo commands so the managed environment stays authoritative.

## Type Safety

- Prefer fully typed code, including function signatures, return types on public interfaces, and structured data models.
- Avoid `Any` except at unavoidable third-party boundaries, and narrow it immediately when you must use it.
- Prefer `Protocol`, `TypedDict`, `dataclass`, or Pydantic-style models over unstructured dictionaries for stable contracts.
- Validate external inputs and outputs at application boundaries.

## Testing And Quality

- Prefer `pytest` for tests.
- Prefer `ruff` for linting and formatting.
- Prefer `pyright` for static type checking in strict mode when the repo does not already use another checker.
- Keep unit tests fast and boundary-focused; use replay-based integration tests when realistic HTTP payloads matter.

## Workflow Notes

- Keep environment setup reproducible in the repo, not in ad hoc shell state.
- Separate linting, formatting, tests, and type checking into explicit commands.
- If a repo has multiple implementation languages, apply each relevant language policy before making cross-language changes.
