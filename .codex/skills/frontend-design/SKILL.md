---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces with high design quality. Use for implementer role UI/frontend work that changes web components, pages, dashboards, applications, or styling within the owning issue scope. Do not use for backend-only changes, chores, unrelated redesigns, or work constrained to an existing design-system decision.
license: Complete terms in LICENSE.txt
---

This skill guides creation of distinctive, production-grade frontend interfaces that avoid generic "AI slop" aesthetics. Implement real working code with exceptional attention to aesthetic details and creative choices.

The user provides frontend requirements: a component, page, application, or interface to build. They may include context about the purpose, audience, or technical constraints.

## Octo Implementer Use

Use this skill only for issue-scoped implementer work where durable source
artifacts ask for UI/frontend implementation or visual refinement. Relevant
artifacts include the Linear issue body, Codex Workpad, Symphony Handoff trail,
linked specs or ADRs, design-system docs, screenshots, and repository UI files.

Do not use this skill for backend-only changes, dependency chores, unrelated
redesigns, or when an existing product spec, framework convention, component
library, accessibility requirement, or design-system rule already constrains
the visual direction. In constrained design-system work, follow the local
system first and use this skill only for fit-and-finish inside those bounds.

Octo workflow boundaries remain authoritative: repository metadata, issue
branch, state transitions, PR ownership, workpad updates, handoff fields,
validation evidence, and `Human Escalation` routing are not overridden by
frontend design preferences.

When implementing, preserve accessibility, responsive behavior, performance,
text fit, and no-overlap requirements. Validate visually when the app can run,
using screenshots or browser checks appropriate to the repository. Match the
domain tone: operational tools should be dense, quiet, and scannable; games or
creative experiences may be more expressive.

### Octo UI Quality Contract

For Octo-managed frontend work, this skill is the primary first-loaded decision
surface for issue-scoped UI/frontend implementation. Use it to decide the
project-appropriate visual direction, whether motion belongs, and which
supporting frontend references or focused skills are relevant. Do not treat
Octo or `scaling-octo-engine` as a universal visual baseline for downstream
repositories.

Before editing UI, discover the applicable project `DESIGN.md` when one exists:

- A repository- or app-local `DESIGN.md` is the design source for that scope.
- A nested app-level `DESIGN.md` supersedes repository-root guidance for
  conflicts inside that app.
- Absence of `DESIGN.md` is not automatically blocking, but missing design
  context that the issue needs must be surfaced in implementation evidence or
  routed through Octo workflow.
- New visual direction must be grounded in the issue, durable project sources,
  existing UI/code conventions, accepted specs, screenshots, brand material, or
  explicit operator-approved design direction. Do not invent a project visual
  identity.

Issue-scoped UI quality includes the expected controls and states, responsive
behavior, accessibility basics, useful empty/loading/error states, purposeful
motion only when justified, interaction performance when relevant, text fit,
and no incoherent overlap. Cite the applied design constraints and UI-quality
assumptions in implementation evidence or handoff text, but keep compact Octo
handoff `Role note` fields reserved for implementation assumptions.

### Supporting Skills And References

Use supporting skills and references only when the shaped issue, applicable
`DESIGN.md`, existing UI context, or operator-approved direction makes them
useful. They are not default dependencies, auth requirements, or reasons to
install packages automatically.

- `ui-animation`: load only for justified interaction, transition,
  microinteraction, or animation behavior after this skill confirms motion fits
  the issue and project context.
- `text-to-lottie`: load only when Lottie or vector animation assets are
  explicitly in scope and the implementer has source assets or promptable
  motion direction, FPS/duration/easing/camera/control requirements,
  runtime/player constraints, and fallback expectations.
- RangeFlow: reference for date, time, range picker, timeline, calendar, or
  scrubber UX and composable React control APIs when those controls are in
  scope.
- Liveline and localized data-viz guidance: references for live chart,
  candlestick, multi-series, orderbook, dashboard, loading/empty,
  hover/scrub, time-window, label, and annotation behavior.
- Agentation-style visual annotation feedback: a development-only HITL adapter
  after a rendered preview exists, normally `In Progress` -> `Human
  Escalation` -> `Agent Fixes`; it is not a production dependency. Blocking
  annotations must be resolved, dismissed with rationale, or promoted into
  updated Linear/spec requirements before acceptance.
- Mueller-Brockmann grid guidance: use for grid-heavy editorial, report, or
  layout-system work.
- Vignelli guidance: use for explicit identity, design-system, or wayfinding
  work.
- Conditional Veo/Hyperframes guidance: use only for video or generated motion
  overlays where text-zone constraints matter.
- Operator-approved brand-book exploration: use only for explicit
  brand-direction work.
- React performance diagnostics: use only when responsiveness symptoms or
  risks exist, such as typing lag, scroll jank, animation frame drops,
  hydration delay, heavy dashboards, charts, large lists, or too much live DOM.
  Classify the bottleneck before changing code: repeated JavaScript work,
  excessive DOM, forced layout/paint, bad scheduling, or hydration/client work.
  Choose the smallest matching fix such as memoization, virtualization,
  scheduling, workerization, client-boundary changes, or layout/paint fixes.

### Motion And Lottie

Motion is design-led. This skill decides whether motion should exist; focused
motion or Lottie guidance implements that decision after it is justified by the
issue, applicable `DESIGN.md`, existing UI, or explicit operator-approved
design direction.

For text-to-Lottie work, prompt like a motion designer: describe easing such as
ease-in/ease-out, camera pans/zooms/pushes, source SVGs or Figma exports when
available, explicit FPS and duration, interaction triggers, segment behavior,
and editable controls or parameters when the animation should remain tunable.

When integrating a generated Lottie asset, name the asset format/path,
player/runtime choice, autoplay/loop/segment controls, interaction triggers,
editable controls if supported, reduced-motion or static fallback, performance
constraints, and validation evidence.

### Visual Evidence

When the app can run, validate the rendered result with screenshots, browser
checks, or repository-appropriate visual evidence. Evidence should cover the
applicable project `DESIGN.md` or explicit no-file/not-applicable rationale,
expected controls and states, responsive behavior, accessibility basics,
motion/Lottie fallback behavior when scoped, optional UI aid boundaries, and
interaction responsiveness when performance-sensitive UI is in scope.

## Design Thinking

Before coding, understand the context and commit to a BOLD aesthetic direction:
- **Purpose**: What problem does this interface solve? Who uses it?
- **Tone**: Pick an extreme: brutally minimal, maximalist chaos, retro-futuristic, organic/natural, luxury/refined, playful/toy-like, editorial/magazine, brutalist/raw, art deco/geometric, soft/pastel, industrial/utilitarian, etc. There are so many flavors to choose from. Use these for inspiration but design one that is true to the aesthetic direction.
- **Constraints**: Technical requirements (framework, performance, accessibility).
- **Differentiation**: What makes this UNFORGETTABLE? What's the one thing someone will remember?

**CRITICAL**: Choose a clear conceptual direction and execute it with precision. Bold maximalism and refined minimalism both work - the key is intentionality, not intensity.

Then implement working code (HTML/CSS/JS, React, Vue, etc.) that is:
- Production-grade and functional
- Visually striking and memorable
- Cohesive with a clear aesthetic point-of-view
- Meticulously refined in every detail

## Frontend Aesthetics Guidelines

Focus on:
- **Typography**: Choose fonts that are beautiful, unique, and interesting. Avoid generic fonts like Arial and Inter; opt instead for distinctive choices that elevate the frontend's aesthetics; unexpected, characterful font choices. Pair a distinctive display font with a refined body font.
- **Color & Theme**: Commit to a cohesive aesthetic. Use CSS variables for consistency. Dominant colors with sharp accents outperform timid, evenly-distributed palettes.
- **Motion**: Use animations for effects and micro-interactions. Prioritize CSS-only solutions for HTML. Use Motion library for React when available. Focus on high-impact moments: one well-orchestrated page load with staggered reveals (animation-delay) creates more delight than scattered micro-interactions. Use scroll-triggering and hover states that surprise.
- **Spatial Composition**: Unexpected layouts. Asymmetry. Overlap. Diagonal flow. Grid-breaking elements. Generous negative space OR controlled density.
- **Backgrounds & Visual Details**: Create atmosphere and depth rather than defaulting to solid colors. Add contextual effects and textures that match the overall aesthetic. Apply creative forms like gradient meshes, noise textures, geometric patterns, layered transparencies, dramatic shadows, decorative borders, custom cursors, and grain overlays.

NEVER use generic AI-generated aesthetics like overused font families (Inter, Roboto, Arial, system fonts), cliched color schemes (particularly purple gradients on white backgrounds), predictable layouts and component patterns, and cookie-cutter design that lacks context-specific character.

Interpret creatively and make unexpected choices that feel genuinely designed for the context. No design should be the same. Vary between light and dark themes, different fonts, different aesthetics. NEVER converge on common choices (Space Grotesk, for example) across generations.

**IMPORTANT**: Match implementation complexity to the aesthetic vision. Maximalist designs need elaborate code with extensive animations and effects. Minimalist or refined designs need restraint, precision, and careful attention to spacing, typography, and subtle details. Elegance comes from executing the vision well.

Remember: Claude is capable of extraordinary creative work. Don't hold back, show what can truly be created when thinking outside the box and committing fully to a distinctive vision.
