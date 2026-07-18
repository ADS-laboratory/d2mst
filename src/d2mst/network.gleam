//// Builds and controls a running network: one node actor per graph vertex,
//// one link actor per edge. This is the API used by the tests and the
//// simulator to apply topology events.

import d2mst/graph.{type EdgeId, type Graph, type NodeId}
import d2mst/link
import d2mst/logger
import d2mst/node
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}

pub type Network {
  Network(
    graph: Graph,
    nodes: Dict(NodeId, node.Handle),
    links: Dict(EdgeId, Subject(link.Msg)),
  )
}

pub fn start(g: Graph, lg: Option(Subject(logger.Msg))) -> Network {
  let nodes =
    list.fold(g.nodes, dict.new(), fn(d, n) {
      let incident =
        graph.incident(g, n)
        |> list.map(fn(e) {
          let peer = case e.u == n {
            True -> e.v
            False -> e.u
          }
          #(graph.edge_id(e.u, e.v), peer, e.weight)
        })
      dict.insert(d, n, node.start(n, incident, lg))
    })
  let links =
    list.fold(g.edges, dict.new(), fn(d, e) {
      let eid = graph.edge_id(e.u, e.v)
      let assert Ok(ha) = dict.get(nodes, e.u)
      let assert Ok(hb) = dict.get(nodes, e.v)
      dict.insert(d, eid, link.start(eid, e.u, ha.delivery, e.v, hb.delivery))
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
    process.send(h.control, node.Attach(mine))
  })
  Network(graph: g, nodes:, links:)
}

/// Wake every node. GHS allows any subset of nodes to start spontaneously.
pub fn wake_all(net: Network) -> Nil {
  dict.to_list(net.nodes)
  |> list.each(fn(p) { process.send({ p.1 }.control, node.Wake) })
}

// --- topology events (failure injection grows here in later tiers) ---------

pub fn fail_link(net: Network, u: NodeId, v: NodeId) -> Nil {
  case dict.get(net.links, graph.edge_id(u, v)) {
    Ok(l) -> process.send(l, link.Fail)
    Error(_) -> Nil
  }
}

pub fn restore_link(net: Network, u: NodeId, v: NodeId) -> Nil {
  case dict.get(net.links, graph.edge_id(u, v)) {
    Ok(l) -> process.send(l, link.Restore)
    Error(_) -> Nil
  }
}

/// Brutally kill a node process (tier 2+: neighbors will observe the crash
/// as link failures via the link actors' monitors).
pub fn crash_node(net: Network, n: NodeId) -> Nil {
  case dict.get(net.nodes, n) {
    Ok(h) -> process.kill(h.pid)
    Error(_) -> Nil
  }
}
