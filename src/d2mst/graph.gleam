//// Pure graph model shared by the protocol, the simulator and the tests.
////
//// Edge weights are made unique by ordering on the pair (weight, edge id),
//// so the MST of any graph is unique and `kruskal` can be used as an exact
//// oracle for the distributed algorithm.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order.{type Order}

pub type NodeId =
  Int

/// Symmetric edge identifier: both endpoints derive the same id.
pub type EdgeId {
  EdgeId(low: NodeId, high: NodeId)
}

pub fn edge_id(u: NodeId, v: NodeId) -> EdgeId {
  EdgeId(int.min(u, v), int.max(u, v))
}

pub type Edge {
  Edge(u: NodeId, v: NodeId, weight: Int)
}

fn compare_edge_id(a: EdgeId, b: EdgeId) -> Order {
  case int.compare(a.low, b.low) {
    order.Eq -> int.compare(a.high, b.high)
    o -> o
  }
}

pub fn edge_id_less(a: EdgeId, b: EdgeId) -> Bool {
  compare_edge_id(a, b) == order.Lt
}

/// Lexicographic order on (weight, edge id): total and unique per edge even
/// when raw weights collide.
pub fn compare_edge(a: Edge, b: Edge) -> Order {
  case int.compare(a.weight, b.weight) {
    order.Eq -> {
      compare_edge_id(edge_id(a.u, a.v), edge_id(b.u, b.v))
    }
    o -> o
  }
}

pub fn edge_less(a: Edge, b: Edge) -> Bool {
  compare_edge(a, b) == order.Lt
}

pub fn edge_min(a: Edge, b: Edge) -> Edge {
  case edge_less(a, b) {
    True -> a
    False -> b
  }
}

pub fn edge_max(a: Edge, b: Edge) -> Edge {
  case edge_less(a, b) {
    True -> b
    False -> a
  }
}

pub type Graph {
  Graph(nodes: List(NodeId), edges: List(Edge))
}

/// Edges incident to a node.
pub fn incident(g: Graph, n: NodeId) -> List(Edge) {
  list.filter(g.edges, fn(e) { e.u == n || e.v == n })
}

/// The endpoint of `e` that is not `n`.
pub fn other_node(e: Edge, n: NodeId) -> NodeId {
  case e.u == n {
    True -> e.v
    False -> e.u
  }
}

// --- topology mutation -----------------------------------------------------

pub fn find_edge(g: Graph, id: EdgeId) -> Result(Edge, Nil) {
  list.find(g.edges, fn(e) { edge_id(e.u, e.v) == id })
}

pub fn has_edge(g: Graph, id: EdgeId) -> Bool {
  case find_edge(g, id) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Add an isolated node.
pub fn add_node(g: Graph, n: NodeId) -> Graph {
  case list.contains(g.nodes, n) {
    True -> g
    False -> Graph(..g, nodes: [n, ..g.nodes])
  }
}

/// Remove a node together with every edge incident to it.
pub fn remove_node(g: Graph, n: NodeId) -> Graph {
  Graph(
    nodes: list.filter(g.nodes, fn(m) { m != n }),
    edges: list.filter(g.edges, fn(e) { e.u != n && e.v != n }),
  )
}

/// Add an edge, replacing any existing edge between the same endpoints (a
/// re-added edge may carry a different weight, and is a new edge protocol-wide).
/// Endpoints that are not in the graph yet are created.
pub fn add_edge(g: Graph, e: Edge) -> Graph {
  let g =
    g
    |> add_node(e.u)
    |> add_node(e.v)
    |> remove_edge(edge_id(e.u, e.v))
  Graph(..g, edges: [e, ..g.edges])
}

pub fn remove_edge(g: Graph, id: EdgeId) -> Graph {
  Graph(..g, edges: list.filter(g.edges, fn(e) { edge_id(e.u, e.v) != id }))
}

/// The unique MST forest of the graph (one tree per connected component),
/// used as the reference the distributed protocol is validated against.
///
/// Union-find with path compression and union by size
pub fn kruskal(g: Graph) -> List(Edge) {
  let sorted = list.sort(g.edges, compare_edge)
  let parents =
    list.fold(g.nodes, dict.new(), fn(d, n) { dict.insert(d, n, n) })
  let sizes = list.fold(g.nodes, dict.new(), fn(d, n) { dict.insert(d, n, 1) })
  let #(_, _, mst) =
    list.fold(sorted, #(parents, sizes, []), fn(acc, e) {
      let #(parents, sizes, mst) = acc
      let #(parents, ru) = find(parents, e.u)
      let #(parents, rv) = find(parents, e.v)
      case ru == rv {
        True -> #(parents, sizes, mst)
        False -> {
          let #(parents, sizes) = union(parents, sizes, ru, rv)
          #(parents, sizes, [e, ..mst])
        }
      }
    })
  mst
}

/// Number of connected components of the graph.
pub fn components(g: Graph) -> Int {
  list.length(g.nodes) - list.length(kruskal(g))
}

fn find(
  parents: Dict(NodeId, NodeId),
  n: NodeId,
) -> #(Dict(NodeId, NodeId), NodeId) {
  case dict.get(parents, n) {
    Ok(p) if p == n -> #(parents, n)
    Ok(p) -> {
      let #(parents, root) = find(parents, p)
      #(dict.insert(parents, n, root), root)
    }
    Error(_) -> #(parents, n)
  }
}

fn union(
  parents: Dict(NodeId, NodeId),
  sizes: Dict(NodeId, Int),
  ru: NodeId,
  rv: NodeId,
) -> #(Dict(NodeId, NodeId), Dict(NodeId, Int)) {
  let su = case dict.get(sizes, ru) {
    Ok(s) -> s
    Error(_) -> 1
  }
  let sv = case dict.get(sizes, rv) {
    Ok(s) -> s
    Error(_) -> 1
  }
  case su >= sv {
    True -> #(dict.insert(parents, rv, ru), dict.insert(sizes, ru, su + sv))
    False -> #(dict.insert(parents, ru, rv), dict.insert(sizes, rv, su + sv))
  }
}
