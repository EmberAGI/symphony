# Interface Design

When a chosen deepening candidate needs alternative interfaces, design it more
than once. The first idea is unlikely to be the best.

Uses the vocabulary in [LANGUAGE.md](LANGUAGE.md): **module**,
**interface**, **seam**, **adapter**, and **leverage**.

For Agent QA, this file is supporting evaluation guidance. QA may use it to
explain why an implementation-touched interface is shallow, or to verify an
implementer repair. QA should not run an open-ended design workshop, spawn
design agents, or rewrite production code.

## Process

### 1. Frame The Problem Space

Before proposing a new interface, state the problem space for the candidate:

- constraints any new interface must satisfy;
- dependencies it would rely on, and which category they fall into according
  to [DEEPENING.md](DEEPENING.md);
- an illustrative code sketch only when it clarifies constraints. The sketch is
  not a production patch.

For Octo/Symphony QA, keep this frame tied to the implementation-touched files
and to durable context from `spec/`, `spec/adr/`, and relevant `CONTEXT.md`
vocabulary.

### 2. Compare Distinct Interface Shapes

Consider at least two meaningfully different interface shapes before making a
recommendation:

- **Minimize the interface**: aim for one to three entry points and maximize
  leverage per entry point.
- **Optimize for the common caller**: make the default case trivial.
- **Support necessary flexibility**: include extension only where the issue,
  specs, or current callers prove it is needed.
- **Design around adapters** when dependencies cross an owned remote seam or a
  true external service seam.

Each candidate shape should describe:

1. Interface: types, methods, parameters, invariants, ordering, and error
   modes.
2. Usage example showing how callers use it.
3. What the implementation hides behind the seam.
4. Dependency strategy and adapters, using [DEEPENING.md](DEEPENING.md).
5. Trade-offs: where leverage is high, where the interface is still thin, and
   where locality improves.

### 3. Recommend One Direction

Compare designs by **depth**, **locality**, and **seam placement**. Recommend
the strongest direction in plain English. If the best direction combines parts
of multiple designs, describe the hybrid and why it has more leverage.

## QA Use

Agent QA emits at most one set of architectural suggestions per Linear issue.
If the `Architectural suggestions` marker already exists, use this file only to
verify the existing request and the implementer's response. Do not add another
interface-design request.
