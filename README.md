# d2mst

d2mst (Dynamic-Dystributed Minimum Spanning Tree; pronounced as "d-squared-mst") is a
fully decentralized, self-healing dynamic MST protocol implemented in
[Gleam](https://gleam.run) on the BEAM. The design is described in `report/`.

## Layout

- `report/` — LaTeX report (chapters 1–3: problem, analysis, protocol design).
- `src/d2mst/` — the implementation:
  - `graph.gleam`, `fragment.gleam`, `message.gleam` — pure model: graph +
    unique composite weights (Kruskal test oracle), fragment identities,
    protocol messages;
  - `node.gleam` — the protocol node: a pure `handle(state, event)` state
    machine (currently: asynchronous GHS construction) wrapped in a thin
    OTP actor shell;
  - `link.gleam` — one actor per edge relaying messages between endpoints;
    the single place where link failures (and later: drops, delays, crash
    detection) are injected;
  - `network.gleam` — spawns nodes and links from a graph and exposes the
    topology-event API (`fail_link`, `restore_link`, `crash_node`);
  - `monitor.gleam`, `logger.gleam` — interface components (global snapshot,
    message counters); the protocol never depends on them.
- `test/` — gleeunit suite: unit tests, a deterministic process-free
  protocol runner (`test/sim/runner.gleam`), a seeded random graph
  generator, and a convergence oracle that compares the distributed result
  against the unique Kruskal MST.

## Usage

Requires Gleam (>= 1.17) and Erlang/OTP on the PATH.

```sh
gleam run    # demo: builds a network, runs GHS, prints tree vs oracle
gleam test   # full test suite
```
