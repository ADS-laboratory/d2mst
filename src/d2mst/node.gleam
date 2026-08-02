//// Protocol node: the pure GHS state machine.
////
//// `handle(state, event)` returns the new state plus the messages to send
//// (`Effect`s).
////
//// The algorithm is the classic asynchronous Gallager-Humblet-Spira MST
//// construction, with two adaptations:
////   - edges are totally ordered by `graph.compare_edge` (weight, then edge
////     id), so no tie-break rules are needed anywhere;
////   - when the core detects termination it broadcasts `Halt` down the tree
////     so every node (and any observer) can observe completion.
////
//// Messages that GHS must delay (Merge from a lower level not yet
//// mergeable, Test from a higher level, Notify while still finding) are kept
//// in `pending` and re-examined after every processed event, which is
//// equivalent to the paper's "place message at end of queue".

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId, type NodeId}
import d2mst/message
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type GHSNodeState {
  Searching
  Found
}

pub type D2MNodeState {
  Reiden
  MOESearch
  Merge
}

pub type NodeState {
  Sleeping
  GHS(state: GHSNodeState)
  D2M(state: D2MNodeState)
}

pub type EdgeStatus {
  Undecided
  Selected
  Rejected
}

pub type EdgeInfo {
  EdgeInfo(peer: NodeId, edge: Edge, status: EdgeStatus, failures_counter: Int)
}

/// The node state machine.
pub type State {
  State(
    id: NodeId,
    edges: Dict(EdgeId, EdgeInfo),
    ns: NodeState,
    fragment: FragmentId,
    level: Int,
    // rename to parent_edge?
    in_branch: Option(EdgeId),
    // rename to edge_to_best? (is the local edge towards the best outgoing weight found so far)
    best_edge: Option(EdgeId),
    best_wt: Option(Edge),
    test_edge: Option(EdgeId),
    // Children coundowns:
    // - `find_countdown` counts how many children have not yet reported their best
    //   outgoing weight.
    // - `repair_countdown` counts how many children have not yet reported during repair.
    // Potentially a single countdown could be used for both, but I think it is clearer to
    // keep them separate.
    find_countdown: Int,
    repair_countdown: Int,
    halted: Bool,
    pending: List(#(EdgeId, message.Msg)),
  )
}

pub type Event {
  Wakeup
  Receive(on: EdgeId, msg: message.Msg)
  /// A link carrying this edge was created: the edge was added to the
  /// network. Both endpoints of the link observe this event.
  LinkUp(edge: Edge)
  /// The link carrying this edge died: the edge was deleted, or the peer
  /// node crashed. Both endpoints of the link observe this event.
  LinkDown(on: EdgeId)
}

pub type Effect {
  Send(on: EdgeId, msg: message.Msg)
}

/// `incident` lists the graph edges this node is an endpoint of.
pub fn init(id: NodeId, incident: List(Edge)) -> State {
  let edges =
    list.fold(incident, dict.new(), fn(d, e) {
      let peer = graph.other_node(e, id)
      dict.insert(
        d,
        graph.edge_id(e.u, e.v),
        EdgeInfo(peer:, edge: e, status: Undecided, failures_counter: 0),
      )
    })
  State(
    id:,
    edges:,
    ns: Sleeping,
    fragment: fragment.Singleton(id),
    level: 0,
    in_branch: None,
    best_edge: None,
    best_wt: None,
    test_edge: None,
    find_countdown: 0,
    repair_countdown: 0,
    halted: False,
    pending: [],
  )
}

/// What this node knows about one of its incident edges.
pub fn edge(state: State, on: EdgeId) -> Result(EdgeInfo, Nil) {
  dict.get(state.edges, on)
}

/// Register a newly added incident edge.
fn add_edge(state: State, edge: Edge) -> State {
  let peer = graph.other_node(edge, state.id)
  State(
    ..state,
    edges: dict.insert(
      state.edges,
      graph.edge_id(edge.u, edge.v),
      EdgeInfo(peer:, edge:, status: Undecided),
    ),
  )
}

/// Forget an incident edge that no longer exists, dropping every reference
/// the node still holds to it
fn remove_edge(state: State, on: EdgeId) -> State {
  let forget = fn(held: Option(EdgeId)) {
    case held == Some(on) {
      True -> None
      False -> held
    }
  }
  let #(best_edge, best_wt) = case state.best_edge == Some(on) {
    True -> #(None, None)
    False -> #(state.best_edge, state.best_wt)
  }
  State(
    ..state,
    edges: dict.delete(state.edges, on),
    in_branch: forget(state.in_branch),
    test_edge: forget(state.test_edge),
    best_edge:,
    best_wt:,
  )
}

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
    // TODO: the addition response protocol starts here.
    LinkUp(edge) -> #(add_edge(state, edge), [])
    // TODO: the failure response protocol starts here
    LinkDown(on) -> #(remove_edge(state, on), [])
    Receive(on, msg) ->
      case dict.has_key(state.edges, on) {
        False -> #(state, [])
        True ->
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
  }
}

fn wakeup(state: State) -> #(State, List(Effect)) {
  case state.ns {
    Sleeping ->
      case min_edge(state, fn(_) { True }) {
        // No edges at all: this node is a complete (and completed) MST.
        None -> #(State(..state, ns: Found, halted: True), [])
        Some(eid) -> {
          let state = set_status(state, eid, Selected)
          let state = State(..state, ns: Found, level: 0, find_count: 0)
          #(state, [Send(eid, message.Merge(0))])
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
      let find = state.ns == Searching
      let state = case find {
        True -> State(..state, find_count: state.find_count + 1)
        False -> state
      }
      #(
        state,
        list.append(woke, [
          Send(j, message.Initiate(state.level, state.fragment, find)),
        ]),
      )
    }
    False ->
      case info.status {
        // Same/higher level over an undecided edge: wait until our fragment
        // catches up or the edge becomes selected.
        Undecided -> #(defer(state, j, message.Merge(l)), woke)
        // Both fragments chose this edge: merge, j becomes the new core.
        _ -> #(
          state,
          list.append(woke, [
            Send(j, message.Initiate(state.level + 1, fragment.Core(j), True)),
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
  let ns = case find {
    True -> Searching
    False -> Found
  }
  let state =
    State(
      ..state,
      level: l,
      fragment: f,
      ns:,
      in_branch: Some(j),
      best_edge: None,
      best_wt: None,
      test_edge: None,
      find_count: 0,
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
    list.map(children, fn(eid) { Send(eid, message.Initiate(l, f, find)) })
  case find {
    True -> {
      let state = State(..state, find_count: list.length(children))
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
      #(state, [Send(eid, message.Test(state.level, state.fragment))])
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
    True -> #(defer(state, j, message.Test(level, f)), woke)
    False ->
      case f == state.fragment {
        // Different fragments: the edge is a candidate for the MOE.
        False -> #(state, list.append(woke, [Send(j, message.Accept)]))
        // Same fragment: the edge is internal, not a candidate for the MOE.
        True -> {
          let assert Ok(info) = dict.get(state.edges, j)
          let state = case info.status {
            Undecided -> set_status(state, j, Rejected)
            _ -> state
          }
          case state.test_edge == Some(j) {
            False -> #(state, list.append(woke, [Send(j, message.Reject)]))
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
  case state.find_count == 0 && state.test_edge == None {
    True -> {
      let state = State(..state, ns: Found)
      case state.in_branch {
        Some(j) -> #(state, [Send(j, message.Notify(state.best_wt))])
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
  case Some(j) != state.in_branch {
    // Notify from a child.
    True -> {
      let state = State(..state, find_count: state.find_count - 1)
      let state = case opt_less(w, state.best_wt) {
        True -> State(..state, best_wt: w, best_edge: Some(j))
        False -> state
      }
      report(state)
    }
    // Notify from the other side of the core.
    False ->
      case state.ns {
        Searching -> #(defer(state, j, message.Notify(w)), [])
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
    Selected -> #(state, [Send(b, message.ChangeRoot)])
    _ -> {
      let state = set_status(state, b, Selected)
      #(state, [Send(b, message.Merge(state.level))])
    }
  }
}

fn halt(state: State) -> #(State, List(Effect)) {
  let state = State(..state, halted: True)
  let effects =
    branch_edges_except(state, state.in_branch)
    |> list.map(fn(eid) { Send(eid, message.Halt) })
  #(state, effects)
}

fn on_halt(state: State, j: EdgeId) -> #(State, List(Effect)) {
  case state.halted {
    True -> #(state, [])
    False -> {
      let state = State(..state, halted: True)
      let effects =
        branch_edges_except(state, Some(j))
        |> list.map(fn(eid) { Send(eid, message.Halt) })
      #(state, effects)
    }
  }
}

// --- helpers ---------------------------------------------------------------

// Put a message in the pending queue to be retried later. The message is
// not sent now, so the caller must not send it either.
fn defer(state: State, on: EdgeId, msg: message.Msg) -> State {
  State(..state, pending: [#(on, msg), ..state.pending])
}

fn set_status(state: State, eid: EdgeId, status: EdgeStatus) -> State {
  let assert Ok(info) = dict.get(state.edges, eid)
  State(
    ..state,
    edges: dict.insert(state.edges, eid, EdgeInfo(..info, status:)),
  )
}

fn min_edge(state: State, keep: fn(EdgeInfo) -> Bool) -> Option(EdgeId) {
  dict.fold(state.edges, None, fn(best, eid, info) {
    case keep(info) {
      False -> best
      True ->
        case best {
          None -> Some(#(eid, info.edge))
          Some(#(_, bw)) ->
            case graph.edge_less(info.edge, bw) {
              True -> Some(#(eid, info.edge))
              False -> best
            }
        }
    }
  })
  |> option.map(fn(p) { p.0 })
}

/// Exposed for `logger.summarise`: the branch edges a node currently knows
/// about, excluding `except` (the edge a Halt/Notify arrived on, so it is
/// not echoed back where it came from).
pub fn branch_edges_except(
  state: State,
  except: Option(EdgeId),
) -> List(EdgeId) {
  dict.to_list(state.edges)
  |> list.filter_map(fn(p) {
    let #(eid, info) = p
    case info.status == Selected && Some(eid) != except {
      True -> Ok(eid)
      False -> Error(Nil)
    }
  })
}

/// None means infinity.
fn opt_less(a: Option(Edge), b: Option(Edge)) -> Bool {
  case a, b {
    Some(x), Some(y) -> graph.edge_less(x, y)
    Some(_), None -> True
    None, _ -> False
  }
}
