# d2mst

d2mst (Dynamic-Distributed Minimum Spanning Tree; pronounced "d-squared-mst") is a
fully decentralized, self-healing dynamic MST protocol implemented in
[Gleam](https://gleam.run) on the BEAM.

The project models a distributed network as a set of cooperating node processes that
maintain and repair a minimum spanning tree under topology changes. The design and
protocol discussion are in the LaTeX report under `report/`.

## Overview

- `report/` — the project report covering the problem, analysis, protocol,
  implementation, and validation.
- `src/d2mst/` — the core protocol and data model:
  - `graph.gleam` and `fragment.gleam` — graph structure, edge identities, and fragment metadata;
  - `message.gleam` — protocol message types;
  - `node.gleam` — the protocol state machine for distributed MST maintenance;
  - `ghs.gleam` — the GHS-style initial tree construction logic;
  - `failure.gleam` — the failure response protocol for dynamic link repairs;
  - `addition.gleam` — the addition response protocol for cycle pruning and partition merges;
  - `link.gleam` — link actors that relay messages and model failures;
  - `network.gleam` — topology event API and network setup.
- `src/engine/` — runtime support for actors, logging, and simulation plumbing.
- `test/` — a Gleeunit suite with deterministic simulation, topology-event tests,
  failure/recovery validation, and oracle-based correctness checking.

## Usage

Requires Gleam (>= 1.17) and Erlang/OTP on the PATH.

```sh
gleam run    # demo: builds a network, runs GHS, prints tree vs oracle
gleam test   # full test suite
```
