//// Demo entrypoint: build a small network, run the distributed GHS
//// construction, and print the resulting tree next to the Kruskal reference.

import d2mst/graph.{Edge, Graph}
import d2mst/logger
import d2mst/network
import gleam/int
import gleam/io
import gleam/list
import gleam/order
import gleam/set
import gleam/string

pub fn main() {
  let g =
    Graph(nodes: [0, 1, 2, 3, 4, 5, 6], edges: [
      Edge(0, 1, 7),
      Edge(0, 3, 5),
      Edge(1, 2, 8),
      Edge(1, 3, 9),
      Edge(1, 4, 7),
      Edge(2, 4, 5),
      Edge(3, 4, 15),
      Edge(3, 5, 6),
      Edge(4, 5, 8),
      Edge(4, 6, 9),
      Edge(5, 6, 11),
    ])

  let lg = logger.start()
  let net = network.start(g, lg)
  network.wake_all(net)

  case logger.await_halt(lg, g.nodes, 100, 20) {
    Error(_) -> io.println("did not converge in time")
    Ok(summaries) -> {
      io.println("-- converged --")
      io.println(logger.format(summaries))
      io.println(
        "tree edges:      "
        <> edges_to_string(logger.tree_edges(summaries) |> set.to_list),
      )
      io.println(
        "kruskal (oracle): "
        <> edges_to_string(
          graph.kruskal(g) |> list.map(fn(e) { graph.edge_id(e.u, e.v) }),
        ),
      )
      io.println(logger.format_counts(logger.counts(logger.history(lg, 1000))))
    }
  }
}

fn edges_to_string(edges: List(graph.EdgeId)) -> String {
  edges
  |> list.sort(fn(a, b) {
    case int.compare(a.low, b.low) {
      order.Eq -> int.compare(a.high, b.high)
      o -> o
    }
  })
  |> list.map(fn(e) {
    "(" <> int.to_string(e.low) <> "," <> int.to_string(e.high) <> ")"
  })
  |> string.join(" ")
}
