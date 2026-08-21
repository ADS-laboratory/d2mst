//// End-to-end integration tests: the same protocol runs on the real actor
//// runtime (one process per node, one per link) and must converge to the
//// unique MST computed by the Kruskal oracle.

import d2mst/graph.{type Graph, Edge, Graph}
import engine/generator
import engine/logger
import engine/network
import gleam/dict
import gleam/erlang/process
import gleam/list
import sim/oracle

fn run_and_check(g: Graph) -> Nil {
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(summaries) = logger.await_halt(lg, net.graph.nodes, 200, 10)
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

// --- topology event plumbing (protocol reaction lands in tiers 2/3) --------

pub fn delete_non_tree_link_test() {
  let g =
    Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(1, 2, 2), Edge(0, 2, 3)])
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  // Deleting the non-tree edge kills its link process; both endpoints
  // observe LinkDown. The MST of the remaining graph is unchanged, so the
  // system must still be consistent.
  let net = network.fail_link(net, 0, 2)
  process.sleep(50)
  let summaries = logger.reconstruct(logger.history(lg, 1000), net.graph.nodes)
  assert oracle.check(net.graph, summaries) == Ok(Nil)
}

pub fn delete_tree_link_liveness_test() {
  // Repairing a broken tree is tier 2; today the endpoints must observe the
  // death without crashing and keep answering the logger.
  let g =
    Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(1, 2, 2), Edge(0, 2, 3)])
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  let net = network.fail_link(net, 0, 1)
  process.sleep(50)
  let summaries = logger.reconstruct(logger.history(lg, 1000), net.graph.nodes)
  assert list.length(summaries) == 3
}

pub fn node_crash_cascades_to_links_test() {
  let g =
    Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(0, 2, 2), Edge(1, 2, 3)])
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  let assert Ok(l01) = dict.get(net.links, graph.edge_id(0, 1))
  let assert Ok(l02) = dict.get(net.links, graph.edge_id(0, 2))
  // Killing node 0 must take both of its links down with it (the links
  // monitor their endpoints), while the survivors keep responding.
  let net = network.crash_node(net, 0)
  process.sleep(100)
  assert !process.is_alive(l01.pid)
  assert !process.is_alive(l02.pid)
  let summaries = logger.reconstruct(logger.history(lg, 1000), net.graph.nodes)
  assert list.length(summaries) == 2
}

pub fn add_link_test() {
  let g = Graph(nodes: [0, 1, 2], edges: [Edge(0, 1, 1), Edge(1, 2, 2)])
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  // A new heavy edge does not change the MST; the endpoints learn it
  // (AttachEdge) and the system stays consistent. The addition response
  // protocol itself is tier 3.
  let net = network.add_link(net, Edge(0, 2, 10))
  process.sleep(50)
  let summaries = logger.reconstruct(logger.history(lg, 1000), net.graph.nodes)
  assert oracle.check(net.graph, summaries) == Ok(Nil)
}

pub fn add_node_test() {
  let g = Graph(nodes: [0, 1], edges: [Edge(0, 1, 1)])
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  // A joining node is spawned isolated and only becomes reachable once a
  // link is added; its process must be alive and wired to the same logger.
  let net = network.add_node(net, 2)
  let net = network.add_link(net, Edge(1, 2, 3))
  process.sleep(50)
  let assert Ok(h) = dict.get(net.nodes, 2)
  assert process.is_alive(h.pid)
  assert dict.has_key(net.links, graph.edge_id(1, 2))
  assert net.graph.nodes == [2, 0, 1]
  assert list.length(logger.reconstruct(logger.history(lg, 1000), [2])) == 1
}

pub fn message_complexity_is_recorded_test() {
  // The logger (interface component) must observe the traffic of a run.
  let g = generator.connected(7, 12, 30)
  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)
  let assert Ok(_) = logger.await_halt(lg, net.graph.nodes, 200, 10)
  assert logger.total(logger.counts(logger.history(lg, 1000))) > 0
}
