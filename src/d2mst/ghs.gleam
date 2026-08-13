import d2mst/fragment.{type FragmentId, GHSCore}
import d2mst/graph.{type Edge, type EdgeId}
import d2mst/message.{
  Accept, ChangeRoot, GHSMsg, Halt, Initiate, Merge, Notify, Reject, Test,
}
import d2mst/node.{
  type Effect, type State, Found, GHSNodeState, Rejected, Searching, Selected,
  Send, Sleeping, State, Undecided, branch_edges_except, defer, min_edge,
  opt_less, set_status,
}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}

pub fn handle_ghs_message(
  state: State,
  on: EdgeId,
  msg: message.GHSMsg,
) -> #(State, List(Effect)) {
  case msg {
    message.Merge(l) -> on_connect(state, on, l)
    message.Initiate(l, f, find) -> on_initiate(state, on, l, f, find)
    message.Test(l, f) -> on_test(state, on, l, f)
    message.Accept -> on_accept(state, on)
    message.Reject -> on_reject(state, on)
    message.Notify(w) -> on_notification(state, on, w)
    message.ChangeRoot -> change_root(state)
    message.Halt -> on_halt(state, on)
  }
}

pub fn wakeup(state: State) -> #(State, List(Effect)) {
  case state.ns {
    Sleeping ->
      case min_edge(state, fn(_) { True }) {
        // No edges at all: this node is a complete (and completed) MST.
        None -> #(State(..state, ns: GHSNodeState(Found), halted: True), [])
        Some(eid) -> {
          let state = set_status(state, eid, Selected)
          let state =
            State(..state, ns: GHSNodeState(Found), level: 0, find_countdown: 0)
          #(state, [Send(eid, message.GHSMsg(message.Merge(0)))])
        }
      }
    _ -> #(state, [])
  }
}

fn on_connect(state: State, j: EdgeId, l: Int) -> #(State, List(Effect)) {
  let #(state, woke) = wakeup(state)
  let assert Ok(info) = dict.get(state.edges, j)
  case l < state.level {
    // Absorb the lower-level fragment into ours.
    True -> {
      let state = set_status(state, j, Selected)
      let find = state.ns == GHSNodeState(Searching)
      let state = case find {
        True -> State(..state, find_countdown: state.find_countdown + 1)
        False -> state
      }
      #(
        state,
        list.append(woke, [
          Send(j, GHSMsg(Initiate(state.level, state.fragment, find))),
        ]),
      )
    }
    False ->
      case info.status {
        // Same/higher level over an undecided edge: wait until our fragment
        // catches up or the edge becomes selected.
        Undecided -> #(defer(state, j, GHSMsg(Merge(l))), woke)
        // Both fragments chose this edge: merge, j becomes the new core.
        _ -> #(
          state,
          list.append(woke, [
            Send(
              j,
              GHSMsg(Initiate(state.level + 1, fragment.GHSCore(j), True)),
            ),
          ]),
        )
      }
  }
}

// `Initiate` is a broadcast down the fragment tree that sets the fragment id and level,
// and tells each node whether it should start searching for the MOE or not.
fn on_initiate(
  state: State,
  j: EdgeId,
  l: Int,
  f: FragmentId,
  find: Bool,
) -> #(State, List(Effect)) {
  let ns =
    GHSNodeState(case find {
      True -> Searching
      False -> Found
    })
  let state =
    State(
      ..state,
      level: l,
      fragment: f,
      ns:,
      parent_edge: Some(j),
      best_edge: None,
      best_wt: None,
      test_edge: None,
      find_countdown: 0,
    )
  let children =
    dict.to_list(state.edges)
    |> list.filter_map(fn(p) {
      let #(eid, info) = p
      case eid != j && info.status == Selected {
        True -> Ok(eid)
        False -> Error(Nil)
      }
    })
  let effects =
    list.map(children, fn(eid) { Send(eid, GHSMsg(Initiate(l, f, find))) })
  case find {
    True -> {
      let state = State(..state, find_countdown: list.length(children))
      let #(state, more) = start_test(state)
      #(state, list.append(effects, more))
    }
    False -> #(state, effects)
  }
}

/// Probe the minimum-weight undecided edge, or report if none is left.
fn start_test(state: State) -> #(State, List(Effect)) {
  case min_edge(state, fn(i) { i.status == Undecided }) {
    Some(eid) -> {
      let state = State(..state, test_edge: Some(eid))
      #(state, [Send(eid, GHSMsg(Test(state.level, state.fragment)))])
    }
    None -> {
      let state = State(..state, test_edge: None)
      report(state)
    }
  }
}

// An neighbour is testing us: if it is in a different fragment we are a candidate for the
// MOE, otherwise we are an internal edge and must not be chosen.
fn on_test(
  state: State,
  j: EdgeId,
  level: Int,
  f: FragmentId,
) -> #(State, List(Effect)) {
  let #(state, woke) = wakeup(state)
  case level > state.level {
    // The asker is ahead of us; answering now could wrongly Accept.
    True -> #(defer(state, j, GHSMsg(Test(level, f))), woke)
    False ->
      case f == state.fragment {
        // Different fragments: the edge is a candidate for the MOE.
        False -> #(state, list.append(woke, [Send(j, GHSMsg(Accept))]))
        // Same fragment: the edge is internal, not a candidate for the MOE.
        True -> {
          let assert Ok(info) = dict.get(state.edges, j)
          let state = case info.status {
            Undecided -> set_status(state, j, Rejected)
            _ -> state
          }
          case state.test_edge == Some(j) {
            False -> #(state, list.append(woke, [Send(j, GHSMsg(Reject))]))
            // We were testing the same internal edge: no reply needed,
            // both sides move on.
            True -> {
              let #(state, more) = start_test(state)
              #(state, list.append(woke, more))
            }
          }
        }
      }
  }
}

// The other side accepted our test: the edge is a candidate for the MOE if it is the best
// one we have seen so far. When all children have reported and our own probe finished, we
// report the best outgoing weight found in our subtree towards the core.
fn on_accept(state: State, j: EdgeId) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, j)
  let state = State(..state, test_edge: None)
  let state = case opt_less(Some(info.edge), state.best_wt) {
    True -> State(..state, best_wt: Some(info.edge), best_edge: Some(j))
    False -> state
  }
  report(state)
}

// The other side rejected our test: the edge is internal, not a candidate for the MOE.
// We set its status to Rejected and continue probing for the MOE.
fn on_reject(state: State, j: EdgeId) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, j)
  let state = case info.status {
    Undecided -> set_status(state, j, Rejected)
    _ -> state
  }
  start_test(state)
}

/// Once all children reported and our own probe finished, report the best
/// outgoing weight found in our subtree towards the core.
fn report(state: State) -> #(State, List(Effect)) {
  case state.find_countdown == 0 && state.test_edge == None {
    True -> {
      let state = State(..state, ns: GHSNodeState(Found))
      case state.parent_edge {
        Some(j) -> #(state, [Send(j, GHSMsg(Notify(state.best_wt)))])
        None -> #(state, [])
      }
    }
    False -> #(state, [])
  }
}

// A child reported its best outgoing weight.
fn on_notification(
  state: State,
  j: EdgeId,
  w: Option(Edge),
) -> #(State, List(Effect)) {
  case Some(j) != state.parent_edge {
    // Notify from a child.
    True -> {
      let state = State(..state, find_countdown: state.find_countdown - 1)
      let state = case opt_less(w, state.best_wt) {
        True -> State(..state, best_wt: w, best_edge: Some(j))
        False -> state
      }
      report(state)
    }
    // Notify from the other side of the core.
    False ->
      case state.ns {
        GHSNodeState(Searching) -> #(defer(state, j, GHSMsg(Notify(w))), [])
        _ ->
          case opt_less(state.best_wt, w) {
            // The fragment MOE is on our side: redirect the core here.
            True -> change_root(state)
            False ->
              case w == None && state.best_wt == None {
                // Neither side found an outgoing edge: the MST is complete.
                True -> halt(state)
                False -> #(state, [])
              }
          }
      }
  }
}

fn change_root(state: State) -> #(State, List(Effect)) {
  let assert Some(b) = state.best_edge
  let assert Ok(info) = dict.get(state.edges, b)
  case info.status {
    Selected -> #(state, [Send(b, GHSMsg(ChangeRoot))])
    _ -> {
      let state = set_status(state, b, Selected)
      #(state, [Send(b, GHSMsg(Merge(state.level)))])
    }
  }
}

/// Distinguish between the two sides of a core edge by setting its `parent_edge` to
/// `None` if it has the smaller node id, or leaving it pointing at the
/// other side if it has the larger node id.
fn resolve_root(state: State) -> State {
  case state.parent_edge, state.fragment {
    Some(j), GHSCore(edge) if edge == j -> {
      let assert Ok(info) = dict.get(state.edges, j)
      case state.id < info.peer {
        True -> State(..state, parent_edge: None)
        False -> state
      }
    }
    _, _ -> state
  }
}

fn halt(state: State) -> #(State, List(Effect)) {
  let broadcast_except = state.parent_edge
  let state = resolve_root(state)
  let state = State(..state, halted: True)
  let effects =
    branch_edges_except(state, broadcast_except)
    |> list.map(fn(eid) { Send(eid, GHSMsg(Halt)) })
  #(state, effects)
}

fn on_halt(state: State, j: EdgeId) -> #(State, List(Effect)) {
  case state.halted {
    True -> #(state, [])
    False -> {
      let state = State(..state, halted: True)
      let effects =
        branch_edges_except(state, Some(j))
        |> list.map(fn(eid) { Send(eid, GHSMsg(Halt)) })
      #(state, effects)
    }
  }
}
