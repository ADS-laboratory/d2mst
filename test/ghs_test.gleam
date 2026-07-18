//// End-to-end integration tests: the same protocol runs on the real actor
//// runtime (one process per node, one per link) and must converge to the
//// unique MST computed by the Kruskal oracle.

import d2mst/graph.{type Graph, Edge, Graph}
import d2mst/logger
import d2mst/monitor
import d2mst/network
import gleam/list
import gleam/option.{None, Some}
import sim/generator
import sim/oracle

fn run_and_check(g: Graph) -> Nil {
  let net = network.start(g, None)
  network.wake_all(net)
  let assert Ok(summaries) = monitor.await_halt(net, 200, 10)
  assert oracle.check(g, summaries) == Ok(Nil)
}

pub fn two_nodes_test() {
  run_and_check(Graph(nodes: [0, 1], edges: [Edge(0, 1, 1)]))
}

pub fn line_test() {
  run_and_check(
    Graph(nodes: [0, 1, 2, 3, 4, 5], edges: [
      Edge(0, 1, 4),
      Edge(1, 2, 2),
      Edge(2, 3, 9),
      Edge(3, 4, 1),
      Edge(4, 5, 6),
    ]),
  )
}

pub fn cycle_test() {
  run_and_check(
    Graph(nodes: [0, 1, 2, 3, 4], edges: [
      Edge(0, 1, 3),
      Edge(1, 2, 5),
      Edge(2, 3, 2),
      Edge(3, 4, 8),
      Edge(0, 4, 4),
    ]),
  )
}

pub fn complete_k4_test() {
  run_and_check(
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 6),
      Edge(0, 2, 2),
      Edge(0, 3, 5),
      Edge(1, 2, 3),
      Edge(1, 3, 7),
      Edge(2, 3, 4),
    ]),
  )
}

pub fn equal_weights_actor_test() {
  run_and_check(
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 5),
      Edge(1, 2, 5),
      Edge(2, 3, 5),
      Edge(0, 3, 5),
      Edge(0, 2, 5),
      Edge(1, 3, 5),
    ]),
  )
}

pub fn random_small_actor_test() {
  generator.ints(1, 5)
  |> list.each(fn(seed) { run_and_check(generator.connected(seed, 10, 30)) })
}

pub fn random_medium_actor_test() {
  list.each([42, 43, 44], fn(seed) {
    run_and_check(generator.connected(seed, 25, 20))
  })
}

pub fn message_complexity_is_recorded_test() {
  // The logger (interface component) must observe the traffic of a run.
  let g = generator.connected(7, 12, 30)
  let lg = logger.start()
  let net = network.start(g, Some(lg))
  network.wake_all(net)
  let assert Ok(_) = monitor.await_halt(net, 200, 10)
  assert logger.total(logger.counts(lg)) > 0
}
