//// Deterministic, process-free execution of the pure node state machines:
//// a single FIFO event queue drives `node.handle` for every node until the
//// system quiesces. Complements the real actor runtime by making whole
//// protocol runs reproducible and debuggable step by step.

import d2mst/algorithm
import d2mst/graph.{type Edge, type EdgeId, type Graph, type NodeId}
import d2mst/node
import engine/logger
import gleam/dict.{type Dict}
import gleam/list

pub type Sim {
  Sim(
    graph: Graph,
    states: Dict(NodeId, node.State),
    /// Events not yet delivered: the in-flight messages of the system.
    queue: List(#(NodeId, node.Event)),
  )
}

/// A network of sleeping nodes wired to `g`. Every node runs the naive
/// Phase 3 MOE search; use `new_with_strategy` to pick a different one.
pub fn new(g: Graph) -> Sim {
  new_with_strategy(g, node.Naive)
}

/// Like `new`, but every node runs `moe_strategy`'s Phase 3 procedure.
pub fn new_with_strategy(g: Graph, moe_strategy: node.MoeStrategy) -> Sim {
  let states =
    list.fold(g.nodes, dict.new(), fn(d, n) {
      dict.insert(
        d,
        n,
        node.init_with_strategy(n, graph.incident(g, n), moe_strategy),
      )
    })
  Sim(graph: g, states:, queue: [])
}

pub fn wake(sim: Sim, n: NodeId) -> Sim {
  enqueue(sim, [#(n, node.Wakeup)])
}

/// Wake every node. GHS allows any subset of nodes to start spontaneously.
pub fn wake_all(sim: Sim) -> Sim {
  enqueue(sim, list.map(sim.graph.nodes, fn(n) { #(n, node.Wakeup) }))
}

/// Deliver a single queued event: the unit `settle` is built from, and the
/// hook for stepping through a run one message at a time.
pub fn step_one(sim: Sim) -> Sim {
  case sim.queue {
    [] -> sim
    [#(target, event), ..rest] -> step(Sim(..sim, queue: rest), target, event)
  }
}

/// Deliver events until nothing is left in flight.
pub fn settle(sim: Sim) -> Sim {
  case sim.queue {
    [] -> sim
    _ -> settle(step_one(sim))
  }
}

/// The common case: build, wake everything, run until settled.
pub fn converge(g: Graph) -> Sim {
  new(g) |> wake_all |> settle
}

/// Like `converge`, but every node runs `moe_strategy`'s Phase 3 procedure.
pub fn converge_with_strategy(g: Graph, moe_strategy: node.MoeStrategy) -> Sim {
  new_with_strategy(g, moe_strategy) |> wake_all |> settle
}

pub fn state(sim: Sim, n: NodeId) -> Result(node.State, Nil) {
  dict.get(sim.states, n)
}

pub fn summaries(sim: Sim) -> List(logger.Summary) {
  dict.to_list(sim.states)
  |> list.map(fn(p) { logger.summarise(p.1) })
}

// --- topology events --------------------------------------------------------
//
// The process-free counterparts of `engine/network`'s events. Killing a
// process there means dropping the corresponding in-flight events here: a
// message travelling on a dead link, or addressed to a dead node, is never
// delivered.

/// Add an isolated node. `add_link` is what connects it to the network.
pub fn add_node(sim: Sim, n: NodeId) -> Sim {
  case dict.has_key(sim.states, n) {
    True -> sim
    False ->
      wake(
        Sim(
          ..sim,
          graph: graph.add_node(sim.graph, n),
          states: dict.insert(sim.states, n, node.init(n, [])),
        ),
        n,
      )
  }
}

/// Remove a node and every edge incident to it. Each surviving neighbor
/// observes an ordinary `LinkDown`, which is how a crash reaches the
/// protocol on the actor runtime as well.
pub fn crash_node(sim: Sim, n: NodeId) -> Sim {
  let gone =
    graph.incident(sim.graph, n)
    |> list.map(fn(e) { #(graph.edge_id(e.u, e.v), graph.other_node(e, n)) })
  let sim =
    Sim(
      graph: graph.remove_node(sim.graph, n),
      states: dict.delete(sim.states, n),
      queue: list.filter(sim.queue, fn(entry) {
        entry.0 != n && !travels_on(entry, list.map(gone, fn(p) { p.0 }))
      }),
    )
  enqueue(sim, list.map(gone, fn(p) { #(p.1, node.LinkDown(p.0)) }))
}

/// Add an edge and introduce it to both endpoints. Endpoints that do not
/// exist yet are created. A no-op if the edge already exists.
pub fn add_link(sim: Sim, e: Edge) -> Sim {
  case graph.has_edge(sim.graph, graph.edge_id(e.u, e.v)) {
    True -> sim
    False -> {
      let sim = sim |> add_node(e.u) |> add_node(e.v)
      enqueue(Sim(..sim, graph: graph.add_edge(sim.graph, e)), [
        #(e.u, node.LinkUp(e)),
        #(e.v, node.LinkUp(e)),
      ])
    }
  }
}

/// Delete an edge: both endpoints observe `LinkDown`, and anything still in
/// flight on it is lost.
pub fn fail_link(sim: Sim, u: NodeId, v: NodeId) -> Sim {
  let eid = graph.edge_id(u, v)
  case graph.has_edge(sim.graph, eid) {
    False -> sim
    True -> {
      let sim =
        Sim(
          ..sim,
          graph: graph.remove_edge(sim.graph, eid),
          queue: list.filter(sim.queue, fn(entry) { !travels_on(entry, [eid]) }),
        )
      enqueue(
        sim,
        [u, v]
          |> list.filter(fn(n) { dict.has_key(sim.states, n) })
          |> list.map(fn(n) { #(n, node.LinkDown(eid)) }),
      )
    }
  }
}

fn enqueue(sim: Sim, events: List(#(NodeId, node.Event))) -> Sim {
  Sim(..sim, queue: list.append(sim.queue, events))
}

/// Feed one event to one node and queue whatever it sends. Events addressed
/// to a node that is gone are dropped.
fn step(sim: Sim, target: NodeId, event: node.Event) -> Sim {
  case dict.get(sim.states, target) {
    Error(_) -> sim
    Ok(st) -> {
      let #(st, effects) = algorithm.handle(st, event)
      let sim = Sim(..sim, states: dict.insert(sim.states, target, st))
      enqueue(
        sim,
        list.map(effects, fn(effect) {
          let node.Send(on, m) = effect
          #(peer(on, target), node.Receive(on, m))
        }),
      )
    }
  }
}

fn peer(on: EdgeId, from: NodeId) -> NodeId {
  case on.low == from {
    True -> on.high
    False -> on.low
  }
}

/// Is this queued event a message travelling on one of `ids`?
fn travels_on(entry: #(NodeId, node.Event), ids: List(EdgeId)) -> Bool {
  case entry.1 {
    node.Receive(on, _) -> list.contains(ids, on)
    _ -> False
  }
}
