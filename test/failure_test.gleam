import d2mst/graph
import d2mst/node
import engine/generator.{connected}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleeunit/should
import sim/oracle.{check}
import sim/runner.{
  type Sim, add_link, add_node, converge, converge_with_strategy, crash_node,
  fail_link, settle, summaries,
}

/// A single tree edge fails; the protocol must repair and re-converge to
/// the MST of the resulting graph.
pub fn single_link_failure_recovery_test() {
  let g = connected(123, 5, 50)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Remove a Selected edge from the graph.
  let selected_edges =
    list.flatten(list.map(summaries(sim), fn(summary) { summary.tree_edges }))

  // Topology change: drop the first edge in the graph.
  let assert [target_edge_id, ..] = selected_edges
  let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

  let sim_failed = fail_link(sim, target_edge.u, target_edge.v)

  // Let the protocol converge again.
  let sim_recovered = settle(sim_failed)

  // Verify the protocol found the new MST for the degraded graph.
  check(sim_recovered.graph, summaries(sim_recovered))
  |> should.be_ok
}

/// Two tree edge failures in sequence, each settled before the next, on
/// consecutively repaired trees.
pub fn sequential_link_failures_recovery_test() {
  let g = connected(101, 6, 60)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Failure 1.
  let assert [edge1_id, ..] =
    list.flatten(list.map(summaries(sim), fn(s) { s.tree_edges }))
  let assert Ok(edge1) = graph.find_edge(sim.graph, edge1_id)

  let sim1 = fail_link(sim, edge1.u, edge1.v) |> settle
  check(sim1.graph, summaries(sim1)) |> should.be_ok

  // Failure 2 (on the newly formed MST).
  let assert [edge2_id, ..] =
    list.flatten(list.map(summaries(sim1), fn(s) { s.tree_edges }))
  let assert Ok(edge2) = graph.find_edge(sim1.graph, edge2_id)

  let sim2 = fail_link(sim1, edge2.u, edge2.v) |> settle
  check(sim2.graph, summaries(sim2)) |> should.be_ok
}

/// Repair after a link failure using the BinarySearch MOE-search strategy
/// with a non-default sample_k, instead of the default linear scan.
pub fn binary_search_repair_with_custom_sample_k_test() {
  let g = connected(77, 8, 40)

  // Every node runs the BinarySearch Phase 3 procedure with a non-default sample_k
  let sim = converge_with_strategy(g, node.BinarySearch(sample_k: 3))
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert [target_edge_id, ..] =
    list.flatten(list.map(summaries(sim), fn(summary) { summary.tree_edges }))
  let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

  let sim_recovered = fail_link(sim, target_edge.u, target_edge.v) |> settle

  check(sim_recovered.graph, summaries(sim_recovered)) |> should.be_ok
}

/// Single random tree edge failure, repeated across 50 random topologies,
/// to catch repair bugs specific to particular graph shapes.
pub fn fuzz_multiple_topologies_test() {
  // Test seeds 1 through 50.
  let seeds = generator.ints(1, 50)

  list.each(seeds, fn(seed) {
    let g = connected(seed, 10, 30)
    let sim = converge(g)

    // Failure: remove a random edge from the MST.
    let assert [target_edge_id, ..] =
      list.flatten(list.map(summaries(sim), fn(summary) { summary.tree_edges }))
    let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

    let sim = fail_link(sim, target_edge.u, target_edge.v) |> settle

    check(sim.graph, summaries(sim))
    |> should.be_ok
  })
}

/// Two nodes crash concurrently (without settling in between) on a fixed
/// topology; the protocol must still converge to a correct MST.
pub fn concurrent_node_failures_test() {
  let g = connected(11, 12, 30)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert [n1, n2, ..] = sim.graph.nodes
  let sim = sim |> crash_node(n1) |> crash_node(n2) |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Two concurrent node crashes, repeated across random topologies.
pub fn fuzz_concurrent_node_failures_test() {
  let seeds = generator.ints(51, 80)

  list.each(seeds, fn(seed) {
    let g = connected(seed, 12, 30)
    let sim = converge(g)

    let assert [n1, n2, ..] = sim.graph.nodes
    let sim = sim |> crash_node(n1) |> crash_node(n2) |> settle

    check(sim.graph, summaries(sim))
    |> should.be_ok
  })
}

/// A node crash and a new edge addition fired concurrently (without
/// settling in between), mixing Tier 2 repair with Tier 3 addition.
pub fn concurrent_node_crash_and_link_addition_test() {
  let g = connected(13, 10, 25)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert [n1, n2, ..] = sim.graph.nodes
  let sim =
    sim
    |> crash_node(n1)
    |> add_link(graph.Edge(n2, 1000, 42))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Crashing the current fragment root forces a new root to be elected;
/// checks repair handles the widest possible single-node split correctly.
pub fn crash_root_test() {
  let g = connected(7, 14, 25)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let r = root_id(sim)
  let sim = sim |> crash_node(r) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Root crash, repeated across 40 random topologies.
pub fn fuzz_crash_root_test() {
  generator.ints(1, 40)
  |> list.each(fn(seed) {
    let g = connected(seed, 14, 25)
    let sim = converge(g)
    check(sim.graph, summaries(sim)) |> should.be_ok

    let r = root_id(sim)
    let sim = sim |> crash_node(r) |> settle
    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

/// Crashing the highest-degree node in the graph, i.e. the node with the
/// most incident links to repair simultaneously.
pub fn crash_hub_test() {
  let g = connected(9, 18, 60)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let hub = max_degree_node(sim)
  let sim = sim |> crash_node(hub) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Hub crash, repeated across 40 random topologies.
pub fn fuzz_crash_hub_test() {
  generator.ints(1, 40)
  |> list.each(fn(seed) {
    let g = connected(seed, 16, 60)
    let sim = converge(g)
    check(sim.graph, summaries(sim)) |> should.be_ok

    let hub = max_degree_node(sim)
    let sim = sim |> crash_node(hub) |> settle
    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

/// Three tree edges of the same fragment fail without settling in between,
/// so several independent repair waves are in flight at once.
pub fn concurrent_multi_split_test() {
  let g = connected(21, 16, 30)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let edges = tree_edge_ids(sim)
  let assert Ok(e1) = at(edges, 0)
  let assert Ok(e2) = at(edges, 1)
  let assert Ok(e3) = at(edges, 2)
  let assert Ok(a1) = graph.find_edge(sim.graph, e1)
  let assert Ok(a2) = graph.find_edge(sim.graph, e2)
  let assert Ok(a3) = graph.find_edge(sim.graph, e3)

  let sim =
    sim
    |> fail_link(a1.u, a1.v)
    |> fail_link(a2.u, a2.v)
    |> fail_link(a3.u, a3.v)
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Concurrent multi-edge split, repeated across 30 random topologies.
pub fn fuzz_concurrent_multi_split_test() {
  generator.ints(1, 30)
  |> list.each(fn(seed) {
    let g = connected(seed + 100, 16, 30)
    let sim = converge(g)
    check(sim.graph, summaries(sim)) |> should.be_ok

    let edges = tree_edge_ids(sim)
    let take = int.min(3, list.length(edges))
    let picked =
      generator.ints(0, take - 1)
      |> list.filter_map(fn(i) { at(edges, i) })
      |> list.filter_map(fn(eid) { graph.find_edge(sim.graph, eid) })

    let sim =
      list.fold(picked, sim, fn(s, e) { fail_link(s, e.u, e.v) }) |> settle

    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

/// Root crash immediately followed by a link failure inside one of the
/// freshly-orphaned subtrees, without settling in between, across 30 seeds.
pub fn crash_root_then_fail_link_test() {
  generator.ints(1, 30)
  |> list.each(fn(seed) {
    let g = connected(seed + 200, 16, 30)
    let sim = converge(g)
    check(sim.graph, summaries(sim)) |> should.be_ok

    let r = root_id(sim)
    let edges = tree_edge_ids(sim)
    // Any tree edge not touching the root, so the second failure lands
    // inside one of the freshly-orphaned subtrees.
    let assert Ok(candidate) =
      list.find(edges, fn(eid) { eid.low != r && eid.high != r })
    let assert Ok(e) = graph.find_edge(sim.graph, candidate)

    let sim =
      sim
      |> crash_node(r)
      |> fail_link(e.u, e.v)
      |> settle

    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

/// Hub crash repaired via the BinarySearch MOE-search strategy, across 25
/// random topologies.
pub fn fuzz_crash_hub_binary_search_test() {
  generator.ints(1, 25)
  |> list.each(fn(seed) {
    let g = connected(seed + 300, 16, 40)
    let sim = converge_with_strategy(g, node.BinarySearch(sample_k: 2))
    check(sim.graph, summaries(sim)) |> should.be_ok

    let hub = max_degree_node(sim)
    let sim = sim |> crash_node(hub) |> settle
    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

/// sample_k: 0 -> the search narrows one edge per round instead of bisecting.
pub fn fuzz_binary_search_sample_k_0_test() {
  generator.ints(1, 15)
  |> list.each(fn(seed) {
    let g = connected(seed + 1000, 14, 30)
    let sim = converge_with_strategy(g, node.BinarySearch(sample_k: 0))
    check(sim.graph, summaries(sim)) |> should.be_ok

    let hub = max_degree_node(sim)
    let sim = sim |> crash_node(hub) |> settle
    check(sim.graph, summaries(sim)) |> should.be_ok
  })
}

// --- long-running random simulation -----------------------------------------

fn at(items: List(a), i: Int) -> Result(a, Nil) {
  items |> list.drop(i) |> list.first
}

/// Fire one random topology event: fail a link, add a link, join a new
/// isolated node, or crash a node (kept rare enough to leave >4 nodes
/// alive, so the run has something left to keep mutating).
///
/// Draws the branch out of 7, not 4: `generator.next`'s LCG has a
/// power-of-2 modulus, so its low bits are degenerate (mod 4 of the raw
/// state only ever advances by a fixed +1 per draw, and every branch here
/// consumes a multiple of 4 draws of its own, so `rand_below(seed, 4)`
/// landed on the same branch for 40 events straight before this was
/// changed). 7 is coprime to the modulus and mixes far better.
fn random_event(sim: Sim, seed: Int, next_id: Int) -> #(Sim, Int, Int) {
  let #(pick, seed) = generator.rand_below(seed, 7)
  case pick {
    0 | 1 ->
      case sim.graph.edges {
        [] -> #(sim, seed, next_id)
        edges -> {
          let #(i, seed) = generator.rand_below(seed, list.length(edges))
          let assert Ok(e) = at(edges, i)
          #(fail_link(sim, e.u, e.v), seed, next_id)
        }
      }
    2 | 3 ->
      case list.length(sim.graph.nodes) > 4 {
        False -> #(sim, seed, next_id)
        True -> {
          let #(idx, seed) =
            generator.rand_below(seed, list.length(sim.graph.nodes))
          let assert Ok(n) = at(sim.graph.nodes, idx)
          #(crash_node(sim, n), seed, next_id)
        }
      }
    4 | 5 -> {
      let nodes = sim.graph.nodes
      let #(u_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let #(v_idx, seed) = generator.rand_below(seed, list.length(nodes))
      let assert Ok(u) = at(nodes, u_idx)
      let assert Ok(v) = at(nodes, v_idx)
      let #(w, seed) = generator.rand_below(seed, 100)
      case u == v {
        True -> #(sim, seed, next_id)
        False -> #(add_link(sim, graph.Edge(u, v, w + 1)), seed, next_id)
      }
    }
    _ -> #(add_node(sim, next_id), seed, next_id + 1)
  }
}

/// 500-node graph subjected to 60 random topology events (link failure,
/// link addition, node join, or node crash) fired in overlapping bursts of
/// 5, checking correctness after every burst and at the end.
pub fn long_running_random_topology_test() {
  let g = connected(2024, 500, 15)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // 60 events in bursts of 5: within a burst nothing settles, so up to 5
  // node/edge events overlap
  let #(final_sim, _seed, _next_id) =
    list.fold(generator.ints(1, 60), #(sim, 909, 1000), fn(acc, i) {
      let #(sim, seed, next_id) = acc
      let #(sim, seed, next_id) = random_event(sim, seed, next_id)
      case i % 5 == 0 {
        True -> {
          let sim = settle(sim)
          check(sim.graph, summaries(sim)) |> should.be_ok
          #(sim, seed, next_id)
        }
        False -> #(sim, seed, next_id)
      }
    })

  let final_sim = settle(final_sim)
  check(final_sim.graph, summaries(final_sim)) |> should.be_ok
}

/// Same as long_running_random_topology_test's random-event-burst
/// procedure, repeated across 5 different starting topologies/seeds.
pub fn fuzz_long_running_random_topology_test() {
  let seeds = generator.ints(1, 5)

  list.each(seeds, fn(top_seed) {
    let g = connected(top_seed, 40, 15)
    let sim = converge(g)
    check(sim.graph, summaries(sim)) |> should.be_ok

    let #(final_sim, _seed, _next_id) =
      list.fold(
        generator.ints(1, 60),
        #(sim, top_seed * 1000 + 3, 1000),
        fn(acc, i) {
          let #(sim, seed, next_id) = acc
          let #(sim, seed, next_id) = random_event(sim, seed, next_id)
          case i % 5 == 0 {
            True -> {
              let sim = settle(sim)
              check(sim.graph, summaries(sim)) |> should.be_ok
              #(sim, seed, next_id)
            }
            False -> #(sim, seed, next_id)
          }
        },
      )

    let final_sim = settle(final_sim)
    check(final_sim.graph, summaries(final_sim)) |> should.be_ok
  })
}

// Helpers

fn root_id(sim: Sim) -> graph.NodeId {
  let assert Ok(r) = list.find(summaries(sim), fn(s) { s.parent == None })
  r.id
}

fn max_degree_node(sim: Sim) -> graph.NodeId {
  let assert [first, ..] = sim.graph.nodes
  list.fold(sim.graph.nodes, first, fn(best, n) {
    let deg = list.length(graph.incident(sim.graph, n))
    let best_deg = list.length(graph.incident(sim.graph, best))
    case deg > best_deg {
      True -> n
      False -> best
    }
  })
}

fn tree_edge_ids(sim: Sim) -> List(graph.EdgeId) {
  list.flatten(list.map(summaries(sim), fn(s) { s.tree_edges }))
}
