import d2mst/graph.{Edge, Graph}
import engine/generator.{connected}
import gleam/list
import gleeunit/should
import sim/oracle.{check}
import sim/runner.{type Sim, add_link, converge, fail_link, settle, summaries}

/// Adding a *light* edge between two nodes already in the same fragment
/// closes a cycle whose heaviest edge is now stale; the protocol must run
/// the LCA/Replace phases and prune it, adopting the new edge instead.
pub fn same_fragment_addition_prunes_cycle_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)
  let sim = add_link(sim, Edge(u, v, 0)) |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_true
}

/// Adding a *heavy* edge between two nodes already in the same fragment
/// still closes a cycle, but the new edge is not the lightest in it: the
/// LCA must recognise the no-op case and leave the MST untouched.
pub fn same_fragment_addition_is_no_op_when_heaviest_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)
  let sim = add_link(sim, Edge(u, v, 500)) |> settle

  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_false
}

/// Two disjoint, already-converged (and thus sleeping) components are
/// joined by a single new edge; the protocol must merge them into one MST
/// without either side having a failure repair in progress.
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

/// A link to a node that was never part of any GHS round (it starts
/// `Sleeping` by construction, having never been woken) must still be
/// absorbed into the tree instead of stalling forever.
pub fn new_node_join_test() {
  let g = connected(13, 6, 30)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(0, 1000, 7)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Two edges added concurrently (without settling in between), each closing
/// a cycle in a *different, disjoint* fragment, both lighter than anything
/// already in their cycle. Their cycles cannot share a tree edge by
/// construction, so this is the "concurrency of non-overlapping additions"
/// case the report says works without any serialization. (Overlapping
/// cycles are a known, documented gap — see `addition.on_privilege`.)
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
/// between. This is the "concurrency of non-overlapping additions" case
/// the report says works without any serialization. (Overlapping cycles
/// within one fragment are a known, documented gap — see
/// `addition.on_privilege`.)
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
/// *and* is itself the LCA. Regression test: `on_edge_test` used to only
/// forward a non-root origin's own message to its parent without ever
/// recording it locally, so a node could never recognise itself as the
/// LCA and the wave would run one hop too far.
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
/// (ReIden/GoSleep) to reach every node, including whatever hangs off the
/// endpoint that is *not* the Replace wave's `target_origin`. Regression
/// test: only the `target_origin` endpoint used to have its side of the
/// new edge promoted to `Selected`; the other endpoint's copy stayed
/// `Undecided` forever, so it never counted the edge as a tree edge and
/// could never forward a later broadcast across it.
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

  // Break something entirely unrelated and require the whole tree to
  // re-converge, including whatever is now reachable only through the
  // freshly attached edge.
  let sim = fail_link(sim, 0, 4) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
}

/// Regression test for the `pending_additions` leak on the no-op path
/// (`message.Replace`'s `should_prune: False` case): resolve an addition
/// as a no-op (new edge heavier than the cycle's current max, so nothing
/// is pruned), fail that same edge, then re-add the identical node pair.
/// `event_id` is derived purely from the node pair, so this reuses the
/// first round's id; before `on_replace` was made to always run its
/// routing/cleanup step regardless of `should_prune`, the intermediate
/// nodes on both origin-to-LCA paths from the first (no-op) round never
/// cleared their `pending_additions[event_id]` entry, so this second round
/// could hit a stale entry and misfire as a false LCA partway up the tree
/// instead of running this pair's actual cycle.
pub fn addition_no_op_then_refail_then_reprune_test() {
  let g = connected(5, 8, 0)
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  let assert Ok(#(u, v)) = non_adjacent_pair(sim.graph)

  // First round: heavy edge, no-op -- leaves pending_additions bookkeeping
  // behind at every node on the way up to the LCA if the leak is present.
  let sim = add_link(sim, Edge(u, v, 500)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_false

  // Remove it, then re-add the same pair -- same event_id -- this time
  // light enough that it must actually prune the cycle's heaviest edge.
  let sim = fail_link(sim, u, v) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok

  let sim = add_link(sim, Edge(u, v, 0)) |> settle
  check(sim.graph, summaries(sim)) |> should.be_ok
  list.contains(tree_edge_ids(sim), graph.edge_id(u, v)) |> should.be_true
}

/// Two cycles that genuinely overlap (both traverse edges 0-1 and 1-2),
/// added concurrently without settling in between. This is the exact race
/// the report's "Overlapping cycles serialization" section describes, and
/// used to corrupt the tree before the root-side Privilege token was
/// implemented.
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
/// tree-edge failure IN THE SAME FRAGMENT: the failure's ReIden broadcast
/// sweeps through every node in the fragment, including whichever ones are
/// mid-coordination for the addition (LCA, root), discarding their
/// in-flight `AddRequestTurn`/`Privilege`/`Replace` messages via the
/// fragment-mismatch check and resetting their bookkeeping. Both endpoints
/// (2 and 3) tag their side of the new edge `via_addition`, so once their
/// post-repair fragment goes quiescent again they re-probe it fresh.
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
/// and neither origin (3, 5, 6) is the LCA or the root: both branches of
/// both events are fully remote, exercising `on_request_turn`/
/// `turn_routing` and the `remote_branches: 2` countdown in
/// `execute_decision`/`on_add_done`, not just the endpoint-is-root
/// shortcut `overlapping_cycles_test` happens to take.
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

/// Addition and failure fired concurrently but in *different, disjoint*
/// fragments: each fragment's `ReIden`/root-serialization state is
/// entirely local, so the two events cannot interfere with each other.
/// This is what "concurrent addition and failure" can mean without
/// running into the same-fragment race above.
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

  // Same-fragment addition in component A (prune edge(1, 3)); unrelated
  // tree-edge failure in disjoint component B; fired without settling in
  // between.
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
