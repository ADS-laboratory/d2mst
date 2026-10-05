# d2mst — Dynamic Distributed Minimum Spanning Tree

**d2mst** (pronounced *"d-squared-MST"*) is a fully decentralized, self-healing protocol that keeps a
**minimum spanning tree (MST)** correct while the network underneath it changes: links fail, new
links appear, nodes crash or join, possibly all at the same time. It is written in
[Gleam](https://gleam.run) and runs on the BEAM, with one OTP actor per node and one per link.

Classic algorithms such as Gallager–Humblet–Spira (GHS) build an MST from scratch. When the
topology changes, the naive fix is to rebuild everything. d2mst instead **repairs only the part of
the tree that is affected**, with no central coordinator and with each node knowing only its own
incident links.

## Highlights

- **Initial construction** with a GHS-style fragment-merging algorithm.
- **Link failure repair.** When a tree edge breaks, the cut-off fragment looks for its minimum outgoing
  edge. Two strategies are implemented and benchmarked against each other:
  - a naive search costing O(|E|) messages;
  - a distributed **binary search over edge weights** inspired by King, Kutten and Thorup. Each step
    tests an interval with a hashed **XOR aggregation** of incident edge identifiers (no false
    positives, false-negative probability around 2⁻⁶⁴), for **O(N log N)** messages.
- **Link addition.** Two messages climb the tree to the endpoints' lowest common ancestor, which
  finds the heaviest edge on the new cycle and prunes it, or merges two partitions. This costs O(N) messages.
- **Concurrency.** Overlapping events are safe: every fragment carries an *identity* that is
  refreshed on each restructuring, and intra-fragment messages from a stale identity are discarded.
- **Failure transparency.** A node crash is observed by its neighbours as link failures, so the
  protocol only has to handle one failure event (`LinkDown`).

## How it is tested

Correctness is exact: after the network settles, the result either is the unique MST of the
current graph or it is not. Every test therefore ends with the same **oracle**
(`test/sim/oracle.gleam`), which compares the distributed result with Kruskal's algorithm and checks:

1. all nodes are quiescent;
2. the union of the locally reported tree edges equals Kruskal's edge set;
3. there is exactly one root per connected component;
4. every parent pointer follows an active tree edge.

The protocol logic is a pure state machine (`d2mst/algorithm.handle`), and it runs under **two
runtimes**:

- a **deterministic simulator** (`test/sim/runner.gleam`) that can replay any interleaving step by step;
- the real **OTP actor system**, where link failures are actual process deaths and handlers run
  truly in parallel.

On top of these runtimes the suite contains:

- **seeded fuzzing** on random connected graphs, where any failure is reproducible from its seed;
- **concurrent bursts** of events that fire without settling in between;
- **regression tests** for specific races, such as two additions whose cycles share tree edges;
- a **long-running simulation** on a 500-node graph with 60 mixed events (edge failures, node crashes,
  new edges, new nodes) fired in overlapping bursts, checked against the oracle after every burst.

## Benchmark

`test/bench_report.gleam` measures message complexity across graph sizes (sparse and dense) and
bursts of several concurrent events, averaging 15 random seeds per cell. It reports each mean as a ratio to the
theoretical term (|E|, N log₂ N or N) so that the asymptotic claims can be checked empirically.

```sh
gleam build --target erlang
erl -pa build/dev/erlang/*/ebin -noshell -eval "bench_report:run(), halt()."
```

## Usage

Requires Gleam ≥ 1.17 and Erlang/OTP.

```sh
gleam run    # interactive demo: random graph → MST → bursts of failures/additions, checked against Kruskal
gleam test   # full test suite
```

## Project layout

```
src/
  d2mst.gleam            demo entry point
  d2mst/
    algorithm.gleam      pure protocol state machine (shared by both runtimes)
    node.gleam           per-node state
    ghs.gleam            initial MST construction (GHS-style)
    failure.gleam        link-failure repair protocol (naive and binary search)
    addition.gleam       link-addition protocol (cycle pruning, partition merge)
    message.gleam        protocol message types
    graph.gleam          graph model, edge identities, Kruskal reference
    fragment.gleam       fragment identity metadata
  engine/                OTP runtime: node and link actors, network setup, generator, logging
test/                    oracle, deterministic simulator, unit/fuzz/regression tests, benchmark
report/                  LaTeX report: analysis, protocol design, implementation, validation
```

## Authors

Leonardo Danelutti and Lorenzo Della Giustina. Developed as the project for the *Distributed
Systems* course of the M.Sc. in Computer Science, University of Udine (2026).
