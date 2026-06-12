# Source

- Upstream: `anthropics/skills@d230a6d`
- Upstream directory: `skills/frontend-design/`
- Localized files: [SKILL.md](SKILL.md), [LICENSE.txt](LICENSE.txt)

## Local Adaptation

The upstream directory is preserved and augmented with Octo implementer
activation rules in [SKILL.md](SKILL.md). The local rules scope the skill to
issue-owned frontend/UI work, avoid backend-only or unrelated redesign work,
and keep accessibility, responsive behavior, performance, text fit,
no-overlap checks, visual validation, and domain-appropriate tone inside the
repository's existing product and framework conventions.

EMB-816 extends the local adaptation with Octo's UI quality contract:
project-local `DESIGN.md` discovery and precedence, no inherited Octo-wide
visual baseline, issue-scoped controls/states/accessibility/responsive/
performance evidence, design-led motion/Lottie decisions, supporting
`ui-animation` and `text-to-lottie` trigger boundaries, optional reference
decision points for RangeFlow, Liveline, Agentation-style HITL feedback,
localized data-viz/grid/identity/video/brand references, and diagnostic React
performance guidance.
