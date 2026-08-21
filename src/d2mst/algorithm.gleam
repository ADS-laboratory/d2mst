import d2mst/addition.{add_edge, handle_add_message}
import d2mst/failure.{handle_failure_message, remove_edge}
import d2mst/ghs.{handle_ghs_message, wakeup}
import d2mst/message
import d2mst/node.{
  type Effect, type Event, type State, LinkDown, LinkUp, Receive, State, Wakeup,
}
import gleam/dict
import gleam/list

/// The exposed function of the protocol, it handles an event and returns the new state and any
/// effects that should be executed.
pub fn handle(state: State, event: Event) -> #(State, List(Effect)) {
  let #(state, effects) = handle_event(state, event)
  let #(state, more) = drain(state)
  #(state, list.append(effects, more))
}

/// Retry deferred messages until none of them makes progress. Progress is
/// only ever unlocked by a state change, and state changes only happen on
/// events, so draining after each event is sufficient.
fn drain(state: State) -> #(State, List(Effect)) {
  let before = list.length(state.pending)
  case before {
    0 -> #(state, [])
    _ -> {
      let queued = list.reverse(state.pending)
      let state = State(..state, pending: [])
      let #(state, effects) =
        list.fold(queued, #(state, []), fn(acc, m) {
          let #(st, es) = acc
          let #(st, new) = handle_event(st, Receive(m.0, m.1))
          #(st, list.append(es, new))
        })
      case list.length(state.pending) < before {
        True -> {
          let #(state, more) = drain(state)
          #(state, list.append(effects, more))
        }
        False -> #(state, effects)
      }
    }
  }
}

fn handle_event(state: State, event: Event) -> #(State, List(Effect)) {
  case event {
    Wakeup -> wakeup(state)
    // TODO: wakeup should be shared between protocols?
    // TODO: the addition response protocol starts here.
    LinkUp(edge) -> add_edge(state, edge)
    // TODO: the failure response protocol starts here
    LinkDown(on) -> remove_edge(state, on)
    Receive(on, msg) ->
      case dict.has_key(state.edges, on) {
        False -> #(state, [])
        True ->
          case msg {
            message.GHSMsg(msg) -> handle_ghs_message(state, on, msg)
            message.D2MMsg(msg, fragment_id) ->
              handle_failure_message(state, on, msg, fragment_id)
            message.AddMsg(msg, fragment_id) ->
              handle_add_message(state, on, msg, fragment_id)
          }
      }
  }
}
