//// Builds and controls a running network: one node actor per graph vertex,
//// one link actor per edge. This is the API used by the tests and the
//// simulator to apply topology events.

import d2mst/graph.{type Edge, type EdgeId, type Graph, type NodeId}
import engine/link
import engine/logger
import engine/node_actor
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list

pub type Network {
  Network(
    graph: Graph,
    nodes: Dict(NodeId, node_actor.Handle),
    links: Dict(EdgeId, link.Handle),
    logger: Subject(logger.Msg),
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
  Network(graph: g, nodes:, links:, logger: lg)
}

/// Wake every node. GHS allows any subset of nodes to start spontaneously.
pub fn wake_all(net: Network) -> Nil {
  dict.to_list(net.nodes)
  |> list.each(fn(p) { process.send({ p.1 }.control, node_actor.Wake) })
}

// --- topology events --------------------------------------------------------

/// Add an isolated node to the running network. It starts with no incident
/// edges and it is woken immediately.
pub fn add_node(net: Network, n: NodeId) -> Network {
  case dict.has_key(net.nodes, n) {
    True -> net
    False -> {
      let h = node_actor.start(n, [], net.logger)
      process.send(h.control, node_actor.Attach(dict.new()))
      process.send(h.control, node_actor.Wake)
      Network(
        ..net,
        graph: graph.add_node(net.graph, n),
        nodes: dict.insert(net.nodes, n, h),
      )
    }
  }
}

/// Kill a node process. Its links die with it (they monitor
/// their endpoints), so every neighbor observes ordinary link failures.
pub fn crash_node(net: Network, n: NodeId) -> Network {
  case dict.get(net.nodes, n) {
    Ok(h) -> process.kill(h.pid)
    Error(_) -> Nil
  }
  process.send(net.logger, logger.Forget(n))
  let gone = graph.incident(net.graph, n)
  // Every surviving neighbor is about to react to a LinkDown, so its cached
  // `latest` entry is invalidated.
  process.send(
    net.logger,
    logger.Invalidate(list.map(gone, fn(e) { graph.other_node(e, n) })),
  )
  Network(
    ..net,
    graph: graph.remove_node(net.graph, n),
    nodes: dict.delete(net.nodes, n),
    links: dict.drop(
      net.links,
      list.map(gone, fn(e) { graph.edge_id(e.u, e.v) }),
    ),
  )
}

/// Add an edge to the running network: spawn its link and introduce it to
/// both endpoint nodes. A previously failed edge that comes back is simply
/// added again. Both endpoints must already be in the network.
pub fn add_link(net: Network, e: Edge) -> Network {
  let eid = graph.edge_id(e.u, e.v)
  case dict.has_key(net.links, eid) {
    True -> net
    False -> {
      let assert Ok(hu) = dict.get(net.nodes, e.u)
      let assert Ok(hv) = dict.get(net.nodes, e.v)
      let l = link.start(e, endpoint(hu), endpoint(hv))
      process.send(hu.control, node_actor.AttachEdge(e, l))
      process.send(hv.control, node_actor.AttachEdge(e, l))
      // Both endpoints are about to react to a LinkUp; drop their cached
      // `latest` entries
      process.send(net.logger, logger.Invalidate([e.u, e.v]))
      Network(
        ..net,
        graph: graph.add_edge(net.graph, e),
        links: dict.insert(net.links, eid, l),
      )
    }
  }
}

/// Delete an edge: kill its link process. Both endpoint nodes observe the
/// death via their monitors as a `LinkDown` event.
pub fn fail_link(net: Network, u: NodeId, v: NodeId) -> Network {
  let eid = graph.edge_id(u, v)
  case dict.get(net.links, eid) {
    Ok(l) -> {
      process.kill(l.pid)
      // Both endpoints are about to react to a LinkDown; drop their cached
      // `latest` entries.
      process.send(net.logger, logger.Invalidate([u, v]))
    }
    Error(_) -> Nil
  }
  Network(
    ..net,
    graph: graph.remove_edge(net.graph, eid),
    links: dict.delete(net.links, eid),
  )
}
