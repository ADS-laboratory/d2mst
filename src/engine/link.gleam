//// Link actor: the communication channel between two neighboring nodes.
////
//// Every edge of the graph is one of these processes, and the process *is*
//// the edge: deleting the edge means killing the process, there is no
//// polite "failed" state. Endpoint nodes monitor their links and observe
//// the death as a `LinkDown` event; a re-added edge is a brand new link
//// process (and, protocol-wise, a brand new edge).
////
//// The link also monitors both endpoint nodes and stops itself when either
//// dies. This cascade is what reduces node crashes to edge failures: a
//// crashed node takes all its links down, and every neighbor observes
//// ordinary link failures.

import d2mst/graph.{type Edge, type NodeId}
import d2mst/message.{type Delivery, Delivery}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor

/// One end of the link: the node's process (monitored) and the subject the
/// link delivers messages to.
pub type Endpoint {
  Endpoint(pid: Pid, delivery: Subject(Delivery))
}

pub type Handle {
  Handle(pid: Pid, subject: Subject(Msg))
}

pub type Msg {
  /// Relay a protocol message from one endpoint to the other.
  Transmit(from: NodeId, payload: message.Msg)
  /// One of the endpoint nodes died (monitor notification).
  EndpointDown
}

type State {
  State(edge: Edge, u: Endpoint, v: Endpoint)
}

/// `u` must be the endpoint of node `edge.u`, and `v` the one of node
/// `edge.v` — the pairing is what routes messages to the other endpoint.
pub fn start(edge: Edge, u: Endpoint, v: Endpoint) -> Handle {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      process.monitor(u.pid)
      process.monitor(v.pid)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(fn(_) { EndpointDown })
      actor.initialised(State(edge:, u:, v:))
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start
  // Free-standing process: deleting the edge means killing it, and that
  // death must not propagate to whoever built the network.
  process.unlink(started.pid)
  Handle(pid: started.pid, subject: started.data)
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Transmit(from, payload) -> {
      let target = case from == state.edge.u {
        True -> state.v.delivery
        False -> state.u.delivery
      }
      let edge_id = graph.edge_id(state.edge.u, state.edge.v)
      process.send(target, Delivery(edge_id, payload))
      actor.continue(state)
    }
    // A channel with one end is no channel: die, so the surviving endpoint
    // observes an ordinary link failure.
    EndpointDown -> actor.stop()
  }
}
