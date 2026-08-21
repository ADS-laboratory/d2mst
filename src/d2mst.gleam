//// Demo entrypoint: build a random graph, run the distributed GHS
//// construction on the real actor engine, then fire random topology events
//// in overlapping bursts forever, checking convergence against the Kruskal
//// oracle after every burst.

import d2mst/graph.{type Graph, Edge}
import engine/generator
import engine/logger
import engine/network.{type Network}
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/set

/// Nodes in the graph the simulation starts from.
const initial_node_count = 500

/// Chance (%) of an extra edge between any two nodes not already joined by
/// the initial random spanning tree.
const initial_edge_pct = 33

/// Seed the initial graph's shape is generated from.
const initial_graph_seed = 2026

/// Seed the endless stream of random topology events is generated from.
const event_seed = 909

/// Random topology events fired per burst; within a burst nothing settles,
/// so up to `burst_size` node/edge events overlap.
const burst_size = 5

/// Convergence poll budget per check: up to `await_attempts` retries,
/// `await_interval_ms` apart, before a burst is declared not converged.
const await_attempts = 500

const await_interval_ms = 50

const join_extra_edges = 1

pub fn main() {
  let g =
    generator.connected(
      initial_graph_seed,
      initial_node_count,
      initial_edge_pct,
    )
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)

  io.println("-- initial convergence --")
  case await_and_check(lg, net.graph, await_attempts, await_interval_ms) {
    Error(reason) -> io.println("FAILED: " <> reason)
    Ok(_) -> {
      io.println("ok")
      run_bursts(net, lg, event_seed, initial_node_count + 1, 1)
    }
  }
}

/// Random topology events forever, in bursts of `burst_size`: within a
/// burst nothing settles, so up to `burst_size` node/edge events overlap.
fn run_bursts(
  net: Network,
  lg: Subject(logger.Msg),
  seed: Int,
  next_id: Int,
  i: Int,
) -> Nil {
  let #(net, seed, next_id) = random_event(net, seed, next_id)
  case i % burst_size == 0 {
    False -> run_bursts(net, lg, seed, next_id, i + 1)
    True -> {
      io.println(
        "-- burst ending at event "
        <> int.to_string(i)
        <> " ("
        <> int.to_string(list.length(net.graph.nodes))
        <> " nodes) --",
      )
      case await_and_check(lg, net.graph, await_attempts, await_interval_ms) {
        Error(reason) -> io.println("FAILED: " <> reason)
        Ok(_) -> io.println("ok")
      }
      run_bursts(net, lg, seed, next_id, i + 1)
    }
  }
}

fn await_and_check(
  lg: Subject(logger.Msg),
  g: Graph,
  attempts: Int,
  interval_ms: Int,
) -> Result(Nil, String) {
  case logger.await_halt(lg, g.nodes, attempts, interval_ms) {
    Error(_) -> Error("did not converge in time")
    Ok(summaries) -> check(g, summaries)
  }
}

/// Same invariants as `sim/oracle.check`: every node halted, the union of
/// reported tree edges equals the unique Kruskal MST, one root per
/// connected component, and every parent pointer is a tree edge.
fn check(g: Graph, summaries: List(logger.Summary)) -> Result(Nil, String) {
  let all_halted = list.all(summaries, fn(s) { s.halted })
  let branch =
    list.fold(summaries, set.new(), fn(acc, s) {
      list.fold(s.tree_edges, acc, set.insert)
    })
  let reference =
    graph.kruskal(g)
    |> list.fold(set.new(), fn(acc, e) {
      set.insert(acc, graph.edge_id(e.u, e.v))
    })
  let roots = list.filter(summaries, fn(s) { s.parent == None }) |> list.length
  let components = graph.components(g)
  let parents_ok =
    list.all(summaries, fn(s) {
      case s.parent {
        None -> True
        Some(p) -> set.contains(branch, graph.edge_id(s.id, p))
      }
    })

  use <- bool.guard(!all_halted, Error("not all nodes halted"))
  use <- bool.guard(
    branch != reference,
    Error("tree edges differ from the unique MST"),
  )
  use <- bool.guard(
    roots != components,
    Error(
      "expected "
      <> int.to_string(components)
      <> " root(s), found "
      <> int.to_string(roots),
    ),
  )
  use <- bool.guard(!parents_ok, Error("a parent pointer is not a tree edge"))
  Ok(Nil)
}

fn at(items: List(a), i: Int) -> Result(a, Nil) {
  items |> list.drop(i) |> list.first
}

/// Fire one random topology event: fail a link, add a link, join a new
/// isolated node, or crash a node (kept rare enough to leave >4 nodes
/// alive, so the run has something left to keep mutating).
///
/// Draws the branch out of 7, not 4: `generator.next`'s LCG has a
/// power-of-2 modulus, so its low bits are degenerate. 7 is coprime to the
/// modulus and mixes far better (see `failure_test.random_event`).
fn random_event(net: Network, seed: Int, next_id: Int) -> #(Network, Int, Int) {
  let #(pick, seed) = generator.rand_below(seed, 7)
  case pick {
    0 | 1 ->
      case net.graph.edges {
        [] -> #(net, seed, next_id)
        edges -> {
          let #(i, seed) = generator.rand_below(seed, list.length(edges))
          let assert Ok(e) = at(edges, i)
          #(network.fail_link(net, e.u, e.v), seed, next_id)
        }
      }
    2 | 3 ->
      case list.length(net.graph.nodes) > 4 {
        False -> #(net, seed, next_id)
        True -> {
          let #(idx, seed) =
            generator.rand_below(seed, list.length(net.graph.nodes))
          let assert Ok(n) = at(net.graph.nodes, idx)
          #(network.crash_node(net, n), seed, next_id)
        }
      }
    4 | 5 -> {
      let nodes = net.graph.nodes
      let #(u_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let #(v_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let assert Ok(u) = at(nodes, u_idx)
      let assert Ok(v) = at(nodes, v_idx)
      let #(w, seed) = generator.rand_below(seed, 100)
      case u == v {
        True -> #(net, seed, next_id)
        False -> #(network.add_link(net, Edge(u, v, w + 1)), seed, next_id)
      }
    }
    _ -> {
      let #(net, seed) = join_node(net, seed, next_id)
      #(net, seed, next_id + 1)
    }
  }
}

/// Add a node and wire it into the network: one guaranteed edge to a
/// random existing node (so it is never left stranded), plus up to
/// `join_extra_edges` more to other random existing nodes -- otherwise
/// `add_node` events only ever grow the node count while never replacing
/// the edges lost to `fail_link`/`crash_node`, and the graph thins out
/// over a long run. Some of the extra picks may repeat (harmless:
/// `network.add_link` no-ops on an edge that already exists), which keeps
/// this a flat, node-count-independent amount of work per join.
fn join_node(net: Network, seed: Int, next_id: Int) -> #(Network, Int) {
  case net.graph.nodes {
    [] -> #(network.add_node(net, next_id), seed)
    existing -> {
      let net = network.add_node(net, next_id)
      let count = list.length(existing)

      list.fold(
        generator.ints(1, join_extra_edges + 1),
        #(net, seed),
        fn(acc, _) {
          let #(net, seed) = acc
          let #(idx, seed) = generator.rand_below(seed, count)
          let assert Ok(u) = at(existing, idx)
          let #(w, seed) = generator.rand_below(seed, 100)
          #(network.add_link(net, Edge(u, next_id, w + 1)), seed)
        },
      )
    }
  }
}
