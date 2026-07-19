# Deepening

How to deepen a cluster of shallow modules safely, given its dependencies.
Assumes the vocabulary in [LANGUAGE.md](LANGUAGE.md): **module**,
**interface**, **seam**, and **adapter**.

Apply this only to implementation files selected by the invoking task or role
workflow. Use it to explain a bounded architecture request or to verify one
that already exists.

## Dependency Categories

When assessing a candidate for deepening, classify its dependencies. The
category determines how the deepened module is tested across its seam.

### 1. In-Process

Pure computation, in-memory state, no I/O. Always deepenable: merge the
modules and test through the new interface directly. No adapter needed.

### 2. Local-Substitutable

Dependencies that have local test stand-ins, such as an in-memory filesystem
or local database substitute. Deepenable if the stand-in exists. The deepened
module is tested with the stand-in running in the test suite. The seam is
internal; no port is exposed at the module's external interface.

### 3. Remote But Owned

Your own services across a network boundary: microservices, internal APIs,
queues, or similar owned systems. Define a port at the seam. The deep module
owns the logic; the transport is injected as an **adapter**. Tests use an
in-memory adapter. Production uses the HTTP, gRPC, queue, or runtime adapter.

Recommendation shape: "Define a port at the seam, implement a production
adapter and an in-memory adapter for testing, so the logic sits in one deep
module even though it crosses a network or runtime seam."

### 4. True External

Third-party services you do not control. The deepened module takes the
external dependency as an injected port; tests provide a mock adapter.

## Seam Discipline

- **One adapter means a hypothetical seam. Two adapters means a real one.** Do
  not introduce a port unless at least two adapters are justified, typically
  production and test. A single-adapter seam is just indirection.
- **Internal seams vs external seams.** A deep module can have internal seams
  private to its implementation, used by its own tests, as well as the external
  seam at its interface. Do not expose internal seams through the interface
  just because tests use them.

## Testing Strategy: Replace, Do Not Layer

- Old unit tests on shallow modules become waste once tests at the deepened
  module's interface exist. Delete or retire them when the new interface tests
  cover the behavior.
- Write new tests at the deepened module's interface. The **interface is the
  test surface**.
- Tests assert on observable outcomes through the interface, not internal
  state.
- Tests should survive internal refactors. They describe behavior, not
  implementation. If a test has to change when the implementation changes, it
  is testing past the interface.

## Bounded Use

When a deepening request is warranted, include the requested testing strategy
and the relevant durable context. If the dependency strategy would create or
change an ADR-worthy decision, cite the relevant `docs/adr/` file or missing
decision and route according to the invoking workflow.
