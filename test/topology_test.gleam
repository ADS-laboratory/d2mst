//// Structural tests of the four topology events — a node joins or dies, a
//// link is added or fails — on the deterministic runtime. They assert what
//// the *structure* guarantees

import d2mst/graph.{type EdgeId, type Graph, Edge, EdgeId, Graph}
import d2mst/message
import d2mst/node
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import sim/runner

fn triangle() -> Graph {
  Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(1, 2, 2), Edge(0, 2, 3)])
}

fn knows(sim: runner.Sim, n: Int, e: EdgeId) -> Bool {
  let assert Ok(st) = runner.state(sim, n)
  case node.edge(st, e) {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- nodes ------------------------------------------------------------------

pub fn add_node_joins_isolated_test() {
  let sim = runner.converge(triangle()) |> runner.add_node(7)
  let assert Ok(st) = runner.state(sim, 7)
  assert dict.size(st.edges) == 0
  // Adding a node that is already there must not reset it.
  let sim = runner.add_node(sim, 0)
  assert list.length(sim.graph.nodes) == 4
}

pub fn add_node_then_link_makes_it_reachable_test() {
  let sim =
    runner.converge(triangle())
    |> runner.add_node(3)
    |> runner.add_link(Edge(2, 3, 4))
    |> runner.settle
  assert graph.has_edge(sim.graph, EdgeId(2, 3))
  assert knows(sim, 3, EdgeId(2, 3))
  assert knows(sim, 2, EdgeId(2, 3))
}

pub fn crash_node_removes_it_and_its_edges_test() {
  let sim = runner.converge(triangle()) |> runner.crash_node(1)
  assert sim.graph.edges == [Edge(0, 2, 3)]
  assert runner.state(sim, 1) == Error(Nil)
  // The survivors have not been told yet: the LinkDown events are in flight.
  assert list.length(sim.queue) == 2
  let sim = runner.settle(sim)
  assert !knows(sim, 0, EdgeId(0, 1))
  assert !knows(sim, 2, EdgeId(1, 2))
  assert knows(sim, 0, EdgeId(0, 2))
}

// --- links ------------------------------------------------------------------

pub fn add_link_introduces_it_to_both_endpoints_test() {
  let g = Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(1, 2, 2)])
  let sim = runner.converge(g) |> runner.add_link(Edge(0, 2, 9))
  assert graph.find_edge(sim.graph, EdgeId(0, 2)) == Ok(Edge(0, 2, 9))
  assert sim.queue
    == [#(0, node.LinkUp(Edge(0, 2, 9))), #(2, node.LinkUp(Edge(0, 2, 9)))]
  let sim = runner.settle(sim)
  assert knows(sim, 0, EdgeId(0, 2))
  assert knows(sim, 2, EdgeId(0, 2))
}

pub fn re_added_link_replaces_the_old_one_test() {
  // A link that comes back is a new edge, and may come back heavier.
  let sim =
    runner.converge(triangle())
    |> runner.fail_link(0, 2)
    |> runner.settle
    |> runner.add_link(Edge(0, 2, 30))
    |> runner.settle
  assert graph.find_edge(sim.graph, EdgeId(0, 2)) == Ok(Edge(0, 2, 30))
  assert list.length(sim.graph.edges) == 3
  let assert Ok(st) = runner.state(sim, 0)
  let assert Ok(info) = node.edge(st, EdgeId(0, 2))
  assert info.edge.weight == 30
  assert info.status == node.Undecided
}

pub fn fail_link_notifies_both_endpoints_test() {
  let sim = runner.converge(triangle()) |> runner.fail_link(1, 2)
  assert !graph.has_edge(sim.graph, EdgeId(1, 2))
  assert sim.queue
    == [#(1, node.LinkDown(EdgeId(1, 2))), #(2, node.LinkDown(EdgeId(1, 2)))]
  let sim = runner.settle(sim)
  assert !knows(sim, 1, EdgeId(1, 2))
  assert !knows(sim, 2, EdgeId(1, 2))
}

pub fn failing_an_unknown_link_is_a_no_op_test() {
  let sim = runner.converge(triangle())
  assert runner.fail_link(sim, 0, 42) == sim
}

pub fn messages_in_flight_on_a_dead_link_are_lost_test() {
  // Node 0 wakes and puts a Merge on edge (0,1); killing the link must drop
  // it, exactly as the dying link process would.
  let sim =
    runner.new(triangle())
    |> runner.wake(0)
    |> runner.step_one
  assert sim.queue
    == [#(1, node.Receive(EdgeId(0, 1), message.GHSMsg(message.Merge(0))))]
  let sim = runner.fail_link(sim, 0, 1)
  assert sim.queue
    == [#(0, node.LinkDown(EdgeId(0, 1))), #(1, node.LinkDown(EdgeId(0, 1)))]
}

// --- what the pure state does with a lost edge -------------------------------

pub fn losing_the_branch_edge_clears_the_parent_test() {
  // Node 1's parent pointer must not survive the death of the edge it
  // points at, and the failure response protocol reconnects the two
  // resulting fragments: isolated node 0 and node 1's old subtree merge back
  // together over the surviving edge (0,2), with node 0 elected the new root
  // (the merge tie-break favors the smaller node id).
  let sim = runner.converge(triangle())
  let assert Ok(before) = runner.state(sim, 1)
  assert before.parent_edge == Some(EdgeId(0, 1))

  let sim = runner.fail_link(sim, 0, 1) |> runner.settle
  let assert Ok(after) = runner.state(sim, 1)
  assert after.parent_edge == Some(EdgeId(1, 2))
  assert node.branch_edges_except(after, Some(EdgeId(1, 2))) == []

  let assert Ok(root) = runner.state(sim, 0)
  assert root.parent_edge == None
}
