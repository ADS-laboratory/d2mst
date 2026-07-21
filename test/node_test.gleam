//// Tests of the pure GHS state machine: single transitions via
//// `node.handle`, and whole protocol runs through the deterministic
//// process-free runner.

import d2mst/graph.{Edge, EdgeId, Graph}
import d2mst/message
import engine/logger
import engine/node
import gleam/list
import gleam/option.{None, Some}
import sim/generator
import sim/oracle
import sim/runner

pub fn wakeup_connects_on_min_edge_test() {
  let st = node.init(0, [Edge(0, 1, 5), Edge(0, 2, 3)])
  let #(st, effects) = node.handle(st, node.Wakeup)
  assert effects == [node.Send(EdgeId(0, 2), message.Connect(0))]
  assert logger.summarise(st).tree_edges == [EdgeId(0, 2)]
  // A second wakeup is a no-op.
  let #(_, effects) = node.handle(st, node.Wakeup)
  assert effects == []
}

pub fn isolated_node_halts_test() {
  let st = node.init(7, [])
  let #(st, effects) = node.handle(st, node.Wakeup)
  assert effects == []
  let summary = logger.summarise(st)
  assert summary.halted
  assert summary.parent == None
}

pub fn connect_from_lower_level_is_deferred_on_basic_edge_test() {
  // Node 0 wakes and chooses edge (0,2); a Connect(0) arriving on the basic
  // edge (0,1) at the same level must wait, not be answered.
  let st = node.init(0, [Edge(0, 1, 5), Edge(0, 2, 3)])
  let #(st, _) = node.handle(st, node.Wakeup)
  let #(_, effects) =
    node.handle(st, node.Receive(EdgeId(0, 1), message.Connect(0)))
  assert effects == []
}

pub fn two_node_merge_test() {
  let g = Graph(nodes: [0, 1], edges: [Edge(0, 1, 4)])
  let states = runner.run(g)
  let summaries = runner.summaries(states)
  assert oracle.check(g, summaries) == Ok(Nil)
  // The smaller core endpoint is the root.
  let assert Ok(s0) = list.find(summaries, fn(s) { s.id == 0 })
  let assert Ok(s1) = list.find(summaries, fn(s) { s.id == 1 })
  assert s0.parent == None
  assert s1.parent == Some(0)
}

pub fn triangle_test() {
  let g =
    Graph(nodes: [0, 1, 2], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(0, 2, 3),
    ])
  let states = runner.run(g)
  assert oracle.check(g, runner.summaries(states)) == Ok(Nil)
}

pub fn line_graph_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4], edges: [
      Edge(0, 1, 9),
      Edge(1, 2, 3),
      Edge(2, 3, 7),
      Edge(3, 4, 1),
    ])
  let states = runner.run(g)
  assert oracle.check(g, runner.summaries(states)) == Ok(Nil)
}

pub fn equal_weights_test() {
  // Every weight identical: correctness must come from the id tie-break.
  let g =
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 5),
      Edge(1, 2, 5),
      Edge(2, 3, 5),
      Edge(0, 3, 5),
      Edge(0, 2, 5),
      Edge(1, 3, 5),
    ])
  let states = runner.run(g)
  assert oracle.check(g, runner.summaries(states)) == Ok(Nil)
}

pub fn random_graphs_pure_test() {
  // Whole protocol runs on seeded random graphs, deterministically.
  generator.ints(1, 20)
  |> list.each(fn(seed) {
    let g = generator.connected(seed, 15, 30)
    let states = runner.run(g)
    assert oracle.check(g, runner.summaries(states)) == Ok(Nil)
  })
}

pub fn random_graphs_pure_larger_test() {
  generator.ints(21, 25)
  |> list.each(fn(seed) {
    let g = generator.connected(seed, 40, 15)
    let states = runner.run(g)
    assert oracle.check(g, runner.summaries(states)) == Ok(Nil)
  })
}
