# Interface Design

When a chosen deepening candidate needs alternative interfaces, design it more
than once. The first idea is unlikely to be the best.

Uses the vocabulary in [LANGUAGE.md](LANGUAGE.md): **module**,
**interface**, **seam**, **adapter**, and **leverage**.

This file is supporting evaluation guidance. Use it to explain why a selected
interface is shallow, or to verify a bounded implementation repair. Do not run
an open-ended design workshop, spawn design agents, or rewrite unrelated
production code.

## Process

### 1. Frame The Problem Space

Before proposing a new interface, state the problem space for the candidate:

- constraints any new interface must satisfy;
- dependencies it would rely on, and which category they fall into according
  to [DEEPENING.md](DEEPENING.md);
- an illustrative code sketch only when it clarifies constraints. The sketch is
  not a production patch.

For Octo/Symphony work, keep this frame tied to the selected implementation
files and to durable context from `docs/specs/`, `docs/adr/`, and relevant
`CONTEXT.md` vocabulary.

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

## Bounded Use

Use this file only within the bounded scope supplied by the invoking task or
role workflow. If prior architecture requests already exist, use this file to
verify that request and the implementation response before proposing any new
interface-design direction allowed by the workflow.
