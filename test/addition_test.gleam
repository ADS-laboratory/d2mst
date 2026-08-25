import d2mst/addition
import d2mst/fragment
import d2mst/graph.{Edge, Graph}
import d2mst/message
import d2mst/node
import engine/generator.{connected}
import gleam/dict
import gleam/list
import gleeunit/should
import sim/oracle.{check}
import sim/runner.{type Sim, add_link, converge, fail_link, settle, summaries}

/// Adding a light edge between two nodes already in the same fragment
pub fn same_fragment_addition_prunes_cycle_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)
  let sim = add_link(sim, Edge(u, v, 0)) |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_true
}

/// Adding a heavy edge between two nodes already in the same fragment
pub fn same_fragment_addition_is_no_op_when_heaviest_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)
  let sim = add_link(sim, Edge(u, v, 500)) |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_false
}

/// Two disjoint, already-converged components are joined by a single new edge
pub fn different_fragment_partition_reconnect_test() {
  let a = connected(11, 5, 30)
  let b = connected(12, 5, 30) |> shift(100)
  let g =
    graph.Graph(
      nodes: list.append(a.nodes, b.nodes),
      edges: list.append(a.edges, b.edges),
    )

  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(0, 100, 42)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

pub fn concurrent_different_fragment_partition_reconnect_test() {
  let a = connected(11, 5, 30)
  let b = connected(12, 5, 30) |> shift(100)
  let g =
    graph.Graph(
      nodes: list.append(a.nodes, b.nodes),
      edges: list.append(a.edges, b.edges),
    )

  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(0, 100, 42))
    |> add_link(Edge(1, 101, 15))
    |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Add a new node to an existing fragment and connect it with a single edge
pub fn new_node_join_test() {
  let g = connected(13, 6, 30)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(0, 1000, 7)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Two edges added concurrently, each closing a cycle in a disjoint fragments, 
/// both lighter than anything already in their cycle.
pub fn concurrent_non_overlapping_additions_test() {
  let a = connected(17, 6, 0)
  let b = connected(18, 6, 0) |> shift(100)
  let g =
    graph.Graph(
      nodes: list.append(a.nodes, b.nodes),
      edges: list.append(a.edges, b.edges),
    )
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u1, v1)) = non_adjacent_pair(a)
  let assert Ok(#(u2, v2)) = non_adjacent_pair(b)

  let sim =
    sim
    |> add_link(Edge(u1, v1, -1))
    |> add_link(Edge(u2, v2, -1))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u1, v1)) |> should.be_true
  list.contains(tree_edge_ids(sim), graph.edge_id(u2, v2)) |> should.be_true
}

/// Same single fragment, two cycles that share no tree edge because they
/// close over sibling subtrees under different branch points (2-1-3 and
/// 5-4-6 never touch each other), added concurrently without settling in
/// between.
pub fn concurrent_disjoint_sibling_cycles_same_fragment_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4, 5, 6], edges: [
      Edge(0, 1, 10),
      Edge(1, 2, 20),
      Edge(1, 3, 30),
      Edge(0, 4, 40),
      Edge(4, 5, 50),
      Edge(4, 6, 60),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(2, 3, 0))
    |> add_link(Edge(5, 6, 0))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// One endpoint (1) of the new edge is a direct ancestor of the other (3)
/// in the tree, so node 1 both originates one side of the Addition wave
/// and is itself the LCA.
pub fn same_fragment_addition_with_ancestor_endpoint_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(1, 3, 0)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// After a same-fragment addition prunes a cycle edge, fire an unrelated
/// failure elsewhere in the tree that requires a full-tree broadcast
/// (ReIden/GoSleep) to reach every node
pub fn addition_then_unrelated_failure_reaches_new_subtree_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4, 5, 6], edges: [
      Edge(0, 1, 10),
      Edge(1, 2, 20),
      Edge(1, 3, 30),
      Edge(0, 4, 40),
      Edge(4, 5, 50),
      Edge(4, 6, 60),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Cycle 2-1-3: prune edge(1, 3) (weight 30), attach new edge (2, 3).
  let sim = add_link(sim, Edge(2, 3, 0)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Break a link and require the whole tree to re-converge, including 
  // whatever is now reachable only through the freshly attached edge.
  let sim = fail_link(sim, 0, 4) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

pub fn addition_no_op_then_refail_then_reprune_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)

  // First round: heavy edge, no-op, leaves pending_additions bookkeeping
  // behind at every node on the way up to the LCA if the leak is present.
  let sim = add_link(sim, Edge(u, v, 500)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_false

  // Remove it, then re-add the same pair, same event_id, this time
  // light enough that it must actually prune the cycle's heaviest edge.
  let sim = fail_link(sim, u, v) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(u, v, 0)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_true
}

/// Two cycles that genuinely overlap (both traverse edges 0-1 and 1-2),
/// added concurrently without settling in between.
pub fn overlapping_cycles_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
      Edge(2, 4, 4),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(0, 3, -1))
    |> add_link(Edge(0, 4, -2))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

pub fn overlapping_cycles_fuzz_test() {
  [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  |> list.each(run_overlap_case)
}

fn run_overlap_case(seed: Int) {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
      Edge(2, 4, 4),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(0, 3, -1 - seed))
    |> add_link(Edge(0, 4, -2 - seed))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Addition mid-flight (before it settles) concurrent with an unrelated
/// tree-edge failure in the same fragment
pub fn addition_concurrent_with_same_fragment_failure_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4, 5, 6], edges: [
      Edge(0, 1, 10),
      Edge(1, 2, 20),
      Edge(1, 3, 30),
      Edge(0, 4, 40),
      Edge(4, 5, 50),
      Edge(4, 6, 60),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(2, 3, 0))
    |> fail_link(0, 4)
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Same overlapping-cycle race as `overlapping_cycles_test`, but shaped so
/// the LCA for both events (node 2) is strictly below the root (node 0)
/// and neither origin (3, 5, 6) is the LCA or the root
pub fn overlapping_cycles_lca_below_root_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4, 5, 6], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
      Edge(2, 4, 4),
      Edge(4, 5, 5),
      Edge(4, 6, 6),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(3, 5, -1))
    |> add_link(Edge(3, 6, -2))
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Addition and failure fired concurrently but in disjoint fragments
pub fn addition_and_failure_in_different_fragments_test() {
  let a =
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(1, 3, 3),
    ])
  let b =
    Graph(nodes: [100, 101, 102, 103], edges: [
      Edge(100, 101, 1),
      Edge(101, 102, 2),
      Edge(101, 103, 3),
    ])
  let g =
    Graph(
      nodes: list.append(a.nodes, b.nodes),
      edges: list.append(a.edges, b.edges),
    )
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim =
    sim
    |> add_link(Edge(2, 3, 0))
    |> fail_link(101, 103)
    |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
}

// --- helpers -----------------------------------------------------------------

fn shift(g: graph.Graph, by: Int) -> graph.Graph {
  graph.Graph(
    nodes: list.map(g.nodes, fn(n) { n + by }),
    edges: list.map(g.edges, fn(e) { Edge(e.u + by, e.v + by, e.weight) }),
  )
}

/// Any pair of distinct nodes in `g` with no edge between them yet.
fn non_adjacent_pair(
  g: graph.Graph,
) -> Result(#(graph.NodeId, graph.NodeId), Nil) {
  list.flat_map(g.nodes, fn(u) {
    list.filter_map(g.nodes, fn(v) {
      case u < v && !graph.has_edge(g, graph.edge_id(u, v)) {
        True -> Ok(#(u, v))
        False -> Error(Nil)
      }
    })
  })
  |> list.first
}

fn tree_edge_ids(sim: Sim) -> List(graph.EdgeId) {
  list.flatten(list.map(summaries(sim), fn(s) { s.tree_edges }))
}

/// Verifies that a rejected, non-pruning edge addition (should_prune: False) correctly
/// clears its via_addition state so it remains eligible as a Minimum Outgoing Edge (MOE).
/// When a critical tree edge later fails, the algorithm successfully discovers and
/// selects this previously rejected edge to reconnect the disconnected graph fragments.
pub fn noop_addition_edge_remains_eligible_as_moe_after_failure_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
      Edge(0, 4, 100),
    ])
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Cycle 0-1-2: max existing tree edge in it is edge(1, 2) (weight 2).
  // The new edge (0, 2, 1000) is heavier, so this is a no-op: it must stay
  // Undecided, unselected, and eligible for future MOE search.
  let sim = add_link(sim, Edge(0, 2, 1000)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(0, 2)) |> should.be_false

  // Fail edge(1, 2): the only remaining edge left connecting {2, 3} to the
  // rest of the graph is the just-rejected (0, 2).
  let sim = fail_link(sim, 1, 2) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(0, 2)) |> should.be_true
}

/// Pending additions of older fragments must be ignored.
pub fn stale_pending_addition_ignored_after_fragment_change_test() {
  let edge_id = graph.edge_id(0, 2)
  let old_fragment = fragment.Singleton(100)
  let new_fragment = fragment.Singleton(200)

  // Construct initial node state at new_fragment.
  let initial_state =
    node.State(
      ..node.init(1, [Edge(0, 1, 10), Edge(1, 2, 20)]),
      fragment: new_fragment,
    )

  // Simulate a stale addition entry stored under old_fragment.
  let stale_msg =
    message.Addition(
      event_id: edge_id,
      new_weight: 50,
      origin: 0,
      running_max: 50,
      max_edge: edge_id,
    )

  let state_with_stale_entry =
    node.State(
      ..initial_state,
      pending_additions: dict.from_list([
        #(edge_id, #(stale_msg, edge_id, old_fragment)),
      ]),
    )

  // Trigger on_addition with a live message arriving under new_fragment.
  let #(updated_state, _effects) =
    addition.on_addition(
      state_with_stale_entry,
      graph.edge_id(1, 2),
      edge_id,
      50,
      2,
      30,
      graph.edge_id(0, 1),
    )

  // The stale entry is discarded, not treated as the LCA's second branch
  // (which would have deleted it instead): the new message is stored fresh
  // in pending_additions, tagged with the current fragment.
  let assert Ok(#(_msg, _from_edge, stored_fragment)) =
    dict.get(updated_state.pending_additions, edge_id)
  stored_fragment |> should.equal(new_fragment)
}
