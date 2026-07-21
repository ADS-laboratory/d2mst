//// Builds and controls a running network: one node actor per graph vertex,
//// one link actor per edge. This is the API used by the tests and the
//// simulator to apply topology events.

import d2mst/graph.{type Edge, type EdgeId, type Graph, type NodeId, Graph}
import d2mst/link
import d2mst/logger
import d2mst/node_actor
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list

pub type Network {
  Network(
    graph: Graph,
    nodes: Dict(NodeId, node_actor.Handle),
    links: Dict(EdgeId, link.Handle),
  )
}

fn endpoint(h: node_actor.Handle) -> link.Endpoint {
  link.Endpoint(pid: h.pid, delivery: h.delivery)
}

pub fn start(g: Graph, lg: Subject(logger.Msg)) -> Network {
  let nodes =
    list.fold(g.nodes, dict.new(), fn(d, n) {
      dict.insert(d, n, node_actor.start(n, graph.incident(g, n), lg))
    })
  let links =
    list.fold(g.edges, dict.new(), fn(d, e) {
      let assert Ok(hu) = dict.get(nodes, e.u)
      let assert Ok(hv) = dict.get(nodes, e.v)
      dict.insert(
        d,
        graph.edge_id(e.u, e.v),
        link.start(e, endpoint(hu), endpoint(hv)),
      )
    })
  list.each(g.nodes, fn(n) {
    let assert Ok(h) = dict.get(nodes, n)
    let mine =
      graph.incident(g, n)
      |> list.fold(dict.new(), fn(d, e) {
        let eid = graph.edge_id(e.u, e.v)
        let assert Ok(l) = dict.get(links, eid)
        dict.insert(d, eid, l)
      })
    process.send(h.control, node_actor.Attach(mine))
  })
  Network(graph: g, nodes:, links:)
}

/// Wake every node. GHS allows any subset of nodes to start spontaneously.
pub fn wake_all(net: Network) -> Nil {
  dict.to_list(net.nodes)
  |> list.each(fn(p) { process.send({ p.1 }.control, node_actor.Wake) })
}

// --- topology events --------------------------------------------------------
//
// These mutate the running system (kill/spawn processes) and return the
// Network value describing the new topology, so tests can keep checking
// against the current graph.

/// Delete an edge: kill its link process. Both endpoint nodes observe the
/// death via their monitors as a `LinkDown` event.
pub fn fail_link(net: Network, u: NodeId, v: NodeId) -> Network {
  let eid = graph.edge_id(u, v)
  case dict.get(net.links, eid) {
    Ok(l) -> process.kill(l.pid)
    Error(_) -> Nil
  }
  Network(
    ..net,
    graph: Graph(
      ..net.graph,
      edges: list.filter(net.graph.edges, fn(e) {
        graph.edge_id(e.u, e.v) != eid
      }),
    ),
    links: dict.delete(net.links, eid),
  )
}

/// Add an edge to the running network: spawn its link and introduce it to
/// both endpoint nodes. A previously failed edge that comes back is simply
/// added again — at the protocol level it is a new edge.
pub fn add_link(net: Network, e: Edge) -> Network {
  let assert Ok(hu) = dict.get(net.nodes, e.u)
  let assert Ok(hv) = dict.get(net.nodes, e.v)
  let l = link.start(e, endpoint(hu), endpoint(hv))
  process.send(hu.control, node_actor.AttachEdge(e, l))
  process.send(hv.control, node_actor.AttachEdge(e, l))
  Network(
    ..net,
    graph: Graph(..net.graph, edges: [e, ..net.graph.edges]),
    links: dict.insert(net.links, graph.edge_id(e.u, e.v), l),
  )
}

/// Brutally kill a node process. Its links die with it (they monitor their
/// endpoints), so every neighbor observes ordinary link failures.
pub fn crash_node(net: Network, n: NodeId) -> Network {
  case dict.get(net.nodes, n) {
    Ok(h) -> process.kill(h.pid)
    Error(_) -> Nil
  }
  let gone = graph.incident(net.graph, n)
  Network(
    graph: Graph(
      nodes: list.filter(net.graph.nodes, fn(m) { m != n }),
      edges: list.filter(net.graph.edges, fn(e) { e.u != n && e.v != n }),
    ),
    nodes: dict.delete(net.nodes, n),
    links: dict.drop(
      net.links,
      list.map(gone, fn(e) { graph.edge_id(e.u, e.v) }),
    ),
  )
}
