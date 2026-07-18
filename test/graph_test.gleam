import d2mst/graph.{Edge, EdgeId, Graph}
import gleam/list

pub fn edge_id_test() {
  assert graph.edge_id(5, 2) == EdgeId(2, 5)
  assert graph.edge_id(2, 5) == EdgeId(2, 5)
}

pub fn edge_order_test() {
  assert graph.edge_less(Edge(0, 1, 3), Edge(0, 1, 4))
  // Equal raw weights are tie-broken by edge id, giving a total order.
  assert graph.edge_less(Edge(0, 1, 3), Edge(0, 2, 3))
  assert !graph.edge_less(Edge(0, 2, 3), Edge(0, 1, 3))
  assert !graph.edge_less(Edge(0, 1, 3), Edge(0, 1, 3))
}

pub fn kruskal_test() {
  let g =
    Graph(nodes: [0, 1, 2, 3], edges: [
      Edge(0, 1, 1),
      Edge(1, 2, 2),
      Edge(2, 3, 3),
      Edge(0, 3, 4),
      Edge(0, 2, 5),
    ])
  assert list.sort(graph.kruskal(g), graph.compare_edge)
    == [Edge(0, 1, 1), Edge(1, 2, 2), Edge(2, 3, 3)]
}

pub fn kruskal_ties_test() {
  // All weights equal: the MST is still unique thanks to the id tie-break,
  // and Kruskal must pick the id-smallest edges.
  let g =
    Graph(nodes: [0, 1, 2], edges: [
      Edge(0, 1, 7),
      Edge(1, 2, 7),
      Edge(0, 2, 7),
    ])
  assert list.sort(graph.kruskal(g), graph.compare_edge)
    == [Edge(0, 1, 7), Edge(0, 2, 7)]
}

pub fn components_test() {
  let g = Graph(nodes: [0, 1, 2, 3, 4], edges: [Edge(0, 1, 1), Edge(2, 3, 1)])
  assert graph.components(g) == 3
  assert list.length(graph.kruskal(g)) == 2
}
