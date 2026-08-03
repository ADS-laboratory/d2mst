import d2mst/ghs.{handle_ghs_message}
import d2mst/graph.{type EdgeId}
import d2mst/message
import d2mst/node.{
  type Effect, type Event, type State, LinkDown, LinkUp, Receive, State, Wakeup,
  add_edge, remove_edge,
}
import gleam/dict
import gleam/list

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
    LinkUp(edge) -> #(add_edge(state, edge), [])
    // TODO: the failure response protocol starts here
    LinkDown(on) -> #(remove_edge(state, on), [])
    Receive(on, msg) ->
      case dict.has_key(state.edges, on) {
        False -> #(state, [])
        True ->
          case msg {
            message.GHSMsg(msg) -> handle_ghs_message(state, on, msg)
            message.D2MMsg(msg, _) -> handle_d2m_message(state, on, msg)
          }
      }
  }
}

fn handle_d2m_message(
  _state: State,
  _on: EdgeId,
  _msg: message.D2MMsg,
) -> #(State, List(Effect)) {
  todo("D2M protocol not yet implemented")
}
