//// Link actor: the communication channel between two neighboring nodes.
////
//// Every edge of the graph is one of these processes. Nodes never hold each
//// other's subjects — they only talk to links — so this is the single place
//// where failures are injected and, in later tiers, where message
//// drop/delay/reorder chaos and endpoint-crash detection (BEAM monitors
//// turning a node crash into link failures for the neighbors) will live.

import d2mst/graph.{type EdgeId, type NodeId}
import d2mst/message.{type Delivery, Delivery}
import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub type Msg {
  /// Relay a protocol message from one endpoint to the other.
  Transmit(from: NodeId, payload: message.Msg)
  /// Take the link down: messages are silently dropped (tier 2+).
  Fail
  /// Bring the link back up (tier 2+).
  Restore
}

type State {
  State(
    id: EdgeId,
    a_node: NodeId,
    a: Subject(Delivery),
    b_node: NodeId,
    b: Subject(Delivery),
    up: Bool,
  )
}

pub fn start(
  id: EdgeId,
  a_node: NodeId,
  a: Subject(Delivery),
  b_node: NodeId,
  b: Subject(Delivery),
) -> Subject(Msg) {
  let assert Ok(started) =
    actor.new(State(id:, a_node:, a:, b_node:, b:, up: True))
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Transmit(from, payload) -> {
      case state.up {
        True -> {
          let target = case from == state.a_node {
            True -> state.b
            False -> state.a
          }
          process.send(target, Delivery(state.id, payload))
        }
        False -> Nil
      }
      actor.continue(state)
    }
    Fail -> actor.continue(State(..state, up: False))
    Restore -> actor.continue(State(..state, up: True))
  }
}
