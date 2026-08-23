//// Build a random graph from a user-chosen size, then repeatedly prompt for a
//// round of node/edge failures and additions, fire them as one overlapping 
//// burst, wait for the network to re-converge, and report the round's stats. 
//// Repeats until blocked.

import d2mst/graph.{type Graph, Edge}
import engine/console
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

/// Convergence poll budget per round: up to `await_attempts` retries,
/// `await_interval_ms` apart, before a round is declared not converged.
const await_attempts = 2000

const await_interval_ms = 25

/// Extra edges wired per node addition
const join_extra_edges = 1

pub fn main() {
  io.println("== d2mst interactive ==")
  let node_count = console.ask_int("number of nodes: ", 1)
  let edge_pct = console.ask_int_range("edge_pct (0-100): ", 0, 100)
  let seed = console.now_ms()

  let g = generator.connected(seed, node_count, edge_pct)
  let lg = logger.start()
  let net = network.start(g, lg)

  io.println("\n-- initial construction --")
  let before = logger.total_sent(lg, 10_000)
  let t0 = console.now_ms()
  network.wake_all(net)
  let net = converge_and_report(net, lg, before, t0)
  loop(net, lg, seed + 1, node_count)
}

/// Prompt for one round's operation counts, apply them, report, repeat.
fn loop(net: Network, lg: Subject(logger.Msg), seed: Int, next_id: Int) -> Nil {
  io.println("\n== next round ==")
  let node_fail = console.ask_int("node failures: ", 0)
  let node_add = console.ask_int("node additions: ", 0)
  let edge_fail = console.ask_int("edge failures: ", 0)
  let edge_add = console.ask_int("edge additions: ", 0)
  console.wait_enter("press Enter to fire this round...")

  let before = logger.total_sent(lg, 10_000)
  let t0 = console.now_ms()
  let #(net, seed, next_id) =
    apply_round(net, seed, next_id, node_fail, node_add, edge_fail, edge_add)
  let net = converge_and_report(net, lg, before, t0)
  loop(net, lg, seed, next_id)
}

/// Wait for the network to halt, run the oracle check, and print the
/// requested stats.
fn converge_and_report(
  net: Network,
  lg: Subject(logger.Msg),
  before: Int,
  t0: Int,
) -> Network {
  case
    console.try_run(fn() {
      logger.await_halt(lg, net.graph.nodes, await_attempts, await_interval_ms)
    })
  {
    Error(Nil) | Ok(Error(_)) -> {
      io.println("FAILED: did not converge in time")
      net
    }
    Ok(Ok(summaries)) -> {
      let t1 = console.now_ms()
      let check_result = check(net.graph, summaries)
      let t2 = console.now_ms()
      let after = case console.try_run(fn() { logger.total_sent(lg, 10_000) }) {
        Ok(n) -> n
        Error(Nil) -> {
          io.println("  (message count unavailable: logger still busy)")
          before
        }
      }
      case check_result {
        Error(reason) -> io.println("CHECK FAILED: " <> reason)
        Ok(_) -> io.println("ok")
      }
      report(net.graph, t1 - t0, t2 - t1, after - before, after)
      net
    }
  }
}

fn report(
  g: Graph,
  converge_ms: Int,
  check_ms: Int,
  round_messages: Int,
  total_messages: Int,
) -> Nil {
  io.println("  nodes:               " <> int.to_string(list.length(g.nodes)))
  io.println("  edges:               " <> int.to_string(list.length(g.edges)))
  io.println("  time to converge:    " <> int.to_string(converge_ms) <> " ms")
  io.println("  time for check:      " <> int.to_string(check_ms) <> " ms")
  io.println(
    "  messages this round: "
    <> int.to_string(round_messages)
    <> " (total so far: "
    <> int.to_string(total_messages)
    <> ")",
  )
}

/// Check that every node halted, the union of reported tree edges equals the 
/// unique Kruskal MST, one root per connected component, and every parent 
/// pointer is a tree edge.
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

/// Apply one round's requested operation counts, in this order: node
/// failures, node additions, edge failures, edge additions. Nothing
/// settles in between, so the effects overlap the way a GHS repair must
/// tolerate.
fn apply_round(
  net: Network,
  seed: Int,
  next_id: Int,
  node_fail: Int,
  node_add: Int,
  edge_fail: Int,
  edge_add: Int,
) -> #(Network, Int, Int) {
  let #(net, seed) = repeat(node_fail, net, seed, fail_random_node)
  let #(net, seed, next_id) = add_nodes(net, seed, next_id, node_add)
  let #(net, seed) = repeat(edge_fail, net, seed, fail_random_edge)
  let #(net, seed) = repeat(edge_add, net, seed, add_random_edge)
  #(net, seed, next_id)
}

fn repeat(
  n: Int,
  net: Network,
  seed: Int,
  f: fn(Network, Int) -> #(Network, Int),
) -> #(Network, Int) {
  case n <= 0 {
    True -> #(net, seed)
    False -> {
      let #(net, seed) = f(net, seed)
      repeat(n - 1, net, seed, f)
    }
  }
}

fn add_nodes(
  net: Network,
  seed: Int,
  next_id: Int,
  count: Int,
) -> #(Network, Int, Int) {
  case count <= 0 {
    True -> #(net, seed, next_id)
    False -> {
      let #(net, seed) = join_node(net, seed, next_id)
      add_nodes(net, seed, next_id + 1, count - 1)
    }
  }
}

fn fail_random_node(net: Network, seed: Int) -> #(Network, Int) {
  case net.graph.nodes {
    [] | [_] -> {
      io.println("  (skip node failure: fewer than 2 nodes left)")
      #(net, seed)
    }
    nodes -> {
      let #(idx, seed) = generator.rand_below(seed, list.length(nodes))
      let assert Ok(n) = at(nodes, idx)
      #(network.crash_node(net, n), seed)
    }
  }
}

fn fail_random_edge(net: Network, seed: Int) -> #(Network, Int) {
  case net.graph.edges {
    [] -> {
      io.println("  (skip edge failure: no edges left)")
      #(net, seed)
    }
    edges -> {
      let #(idx, seed) = generator.rand_below(seed, list.length(edges))
      let assert Ok(e) = at(edges, idx)
      #(network.fail_link(net, e.u, e.v), seed)
    }
  }
}

fn add_random_edge(net: Network, seed: Int) -> #(Network, Int) {
  let nodes = net.graph.nodes
  case list.length(nodes) < 2 {
    True -> {
      io.println("  (skip edge addition: fewer than 2 nodes)")
      #(net, seed)
    }
    False -> {
      let #(u_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let #(v_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let assert Ok(u) = at(nodes, u_idx)
      let assert Ok(v) = at(nodes, v_idx)
      let #(w, seed) = generator.rand_below(seed, 100)
      case u == v {
        True -> #(net, seed)
        False -> #(network.add_link(net, Edge(u, v, w + 1)), seed)
      }
    }
  }
}

/// Add a node and wire it into the network: one guaranteed edge to a random 
/// existing node, plus up to `join_extra_edges` more to other random existing
/// nodes.
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
