//// Deterministic, process-free execution of the pure GHS state machines:
//// a single FIFO event queue drives `node.handle` for every node until the
//// system quiesces. Complements the real actor runtime by making whole
//// protocol runs reproducible and debuggable step by step.

import d2mst/graph.{type Graph, type NodeId}
import d2mst/node
import gleam/dict.{type Dict}
import gleam/list

pub fn run(g: Graph) -> Dict(NodeId, node.State) {
  let states =
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
      dict.insert(d, n, node.init(n, incident))
    })
  let wakeups = list.map(g.nodes, fn(n) { #(n, node.Wakeup) })
  loop(states, wakeups)
}

pub fn summaries(states: Dict(NodeId, node.State)) -> List(node.Summary) {
  dict.to_list(states)
  |> list.map(fn(p) { node.summarise(p.1) })
}

fn loop(
  states: Dict(NodeId, node.State),
  queue: List(#(NodeId, node.Event)),
) -> Dict(NodeId, node.State) {
  case queue {
    [] -> states
    [#(target, event), ..rest] -> {
      let assert Ok(st) = dict.get(states, target)
      let #(st, effects) = node.handle(st, event)
      let states = dict.insert(states, target, st)
      let deliveries =
        list.map(effects, fn(effect) {
          let node.Send(on, m) = effect
          let peer = case on.low == target {
            True -> on.high
            False -> on.low
          }
          #(peer, node.Receive(on, m))
        })
      loop(states, list.append(rest, deliveries))
    }
  }
}
