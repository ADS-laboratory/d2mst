//// Central logging/metrics service.
////
//// This is an *interface* component: the protocol never depends on it and
//// the system keeps working if it crashes. It collects per-node message
//// counters (used to validate the complexity claims of the report) and
//// free-form events.

import d2mst/graph.{type NodeId}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor

pub type Msg {
  /// A protocol message was sent by the given node.
  Sent(by: NodeId)
  /// Free-form event, kept in reverse chronological order.
  Event(text: String)
  GetCounts(reply: Subject(Dict(NodeId, Int)))
  GetEvents(reply: Subject(List(String)))
  Reset
}

type State {
  State(counts: Dict(NodeId, Int), events: List(String))
}

pub fn start() -> Subject(Msg) {
  let assert Ok(started) =
    actor.new(State(dict.new(), []))
    |> actor.on_message(handle)
    |> actor.start
  started.data
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Sent(by) -> {
      let counts =
        dict.upsert(state.counts, by, fn(n) {
          case n {
            option.Some(n) -> n + 1
            option.None -> 1
          }
        })
      actor.continue(State(..state, counts: counts))
    }
    Event(text) ->
      actor.continue(State(..state, events: [text, ..state.events]))
    GetCounts(reply) -> {
      process.send(reply, state.counts)
      actor.continue(state)
    }
    GetEvents(reply) -> {
      process.send(reply, list.reverse(state.events))
      actor.continue(state)
    }
    Reset -> actor.continue(State(dict.new(), []))
  }
}

/// Total number of protocol messages recorded.
pub fn total(counts: Dict(NodeId, Int)) -> Int {
  dict.fold(counts, 0, fn(acc, _, n) { acc + n })
}

pub fn counts(lg: Subject(Msg)) -> Dict(NodeId, Int) {
  process.call(lg, 1000, GetCounts)
}

pub fn format_counts(counts: Dict(NodeId, Int)) -> String {
  "messages sent: " <> int.to_string(total(counts))
}
