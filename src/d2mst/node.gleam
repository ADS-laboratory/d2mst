//// Protocol node.
////
//// The GHS logic is a pure state machine: `handle(state, event)` returns the
//// new state plus the messages to send (`Effect`s). The actor shell at the
//// bottom of this module is the only part that touches processes — it feeds
//// received messages into `handle` and performs the effects by sending to
//// link actors. This split keeps every protocol transition unit-testable and
//// is the seam that would let the same logic run on another transport
//// (e.g. distributed Erlang) later.
////
//// The algorithm is the classic asynchronous Gallager-Humblet-Spira MST
//// construction, with two adaptations:
////   - edges are totally ordered by `graph.compare_edge` (weight, then edge
////     id), so no tie-break rules are needed anywhere;
////   - when the core detects termination it broadcasts `Halt` down the tree
////     so every node (and the monitor) can observe completion.
////
//// Messages that GHS must delay (Connect from a lower level not yet
//// mergeable, Test from a higher level, Report while still finding) are kept
//// in `pending` and re-examined after every processed event, which is
//// equivalent to the paper's "place message at end of queue".

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId, type NodeId}
import d2mst/link
import d2mst/logger
import d2mst/message
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

// ---------------------------------------------------------------------------
// Pure state machine
// ---------------------------------------------------------------------------

pub type NodeState {
  Sleeping
  Find
  Found
}

pub type EdgeStatus {
  Basic
  Branch
  Rejected
}

pub type EdgeInfo {
  EdgeInfo(peer: NodeId, edge: Edge, status: EdgeStatus)
}

pub type State {
  State(
    id: NodeId,
    edges: Dict(EdgeId, EdgeInfo),
    ns: NodeState,
    fragment: FragmentId,
    level: Int,
    in_branch: Option(EdgeId),
    best_edge: Option(EdgeId),
    best_wt: Option(Edge),
    test_edge: Option(EdgeId),
    find_count: Int,
    halted: Bool,
    pending: List(#(EdgeId, message.Msg)),
  )
}

pub type Event {
  Wakeup
  Receive(on: EdgeId, msg: message.Msg)
}

pub type Effect {
  Send(on: EdgeId, msg: message.Msg)
}

/// `incident` lists the node's edges as (edge id, peer node, raw weight).
pub fn init(id: NodeId, incident: List(#(EdgeId, NodeId, Int))) -> State {
  let edges =
    list.fold(incident, dict.new(), fn(d, e) {
      let #(eid, peer, w) = e
      dict.insert(
        d,
        eid,
        EdgeInfo(peer:, edge: graph.Edge(eid.low, eid.high, w), status: Basic),
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
    find_count: 0,
    halted: False,
    pending: [],
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
    Receive(on, msg) ->
      case dict.has_key(state.edges, on) {
        // Message on an edge we do not know: ignore (future tiers: removed edges).
        False -> #(state, [])
        True ->
          case msg {
            message.Connect(l) -> on_connect(state, on, l)
            message.Initiate(l, f, find) -> on_initiate(state, on, l, f, find)
            message.Test(l, f) -> on_test(state, on, l, f)
            message.Accept -> on_accept(state, on)
            message.Reject -> on_reject(state, on)
            message.Report(w) -> on_report(state, on, w)
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
          let state = set_status(state, eid, Branch)
          let state = State(..state, ns: Found, level: 0, find_count: 0)
          #(state, [Send(eid, message.Connect(0))])
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
      let state = set_status(state, j, Branch)
      let find = state.ns == Find
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
        // Same/higher level over a basic edge: wait until our fragment
        // catches up or the edge becomes a branch.
        Basic -> #(defer(state, j, message.Connect(l)), woke)
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

fn on_initiate(
  state: State,
  j: EdgeId,
  l: Int,
  f: FragmentId,
  find: Bool,
) -> #(State, List(Effect)) {
  let ns = case find {
    True -> Find
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
      case eid != j && info.status == Branch {
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

/// Probe the minimum-weight basic edge, or report if none is left.
fn start_test(state: State) -> #(State, List(Effect)) {
  case min_edge(state, fn(i) { i.status == Basic }) {
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

fn on_test(
  state: State,
  j: EdgeId,
  l: Int,
  f: FragmentId,
) -> #(State, List(Effect)) {
  let #(state, woke) = wakeup(state)
  case l > state.level {
    // The asker is ahead of us; answering now could wrongly Accept.
    True -> #(defer(state, j, message.Test(l, f)), woke)
    False ->
      case f == state.fragment {
        False -> #(state, list.append(woke, [Send(j, message.Accept)]))
        True -> {
          let assert Ok(info) = dict.get(state.edges, j)
          let state = case info.status {
            Basic -> set_status(state, j, Rejected)
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

fn on_accept(state: State, j: EdgeId) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, j)
  let state = State(..state, test_edge: None)
  let state = case opt_less(Some(info.edge), state.best_wt) {
    True -> State(..state, best_wt: Some(info.edge), best_edge: Some(j))
    False -> state
  }
  report(state)
}

fn on_reject(state: State, j: EdgeId) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, j)
  let state = case info.status {
    Basic -> set_status(state, j, Rejected)
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
        Some(j) -> #(state, [Send(j, message.Report(state.best_wt))])
        None -> #(state, [])
      }
    }
    False -> #(state, [])
  }
}

fn on_report(
  state: State,
  j: EdgeId,
  w: Option(Edge),
) -> #(State, List(Effect)) {
  case Some(j) != state.in_branch {
    // Report from a child.
    True -> {
      let state = State(..state, find_count: state.find_count - 1)
      let state = case opt_less(w, state.best_wt) {
        True -> State(..state, best_wt: w, best_edge: Some(j))
        False -> state
      }
      report(state)
    }
    // Report from the other side of the core.
    False ->
      case state.ns {
        Find -> #(defer(state, j, message.Report(w)), [])
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
    Branch -> #(state, [Send(b, message.ChangeRoot)])
    _ -> {
      let state = set_status(state, b, Branch)
      #(state, [Send(b, message.Connect(state.level))])
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

fn branch_edges_except(state: State, except: Option(EdgeId)) -> List(EdgeId) {
  dict.to_list(state.edges)
  |> list.filter_map(fn(p) {
    let #(eid, info) = p
    case info.status == Branch && Some(eid) != except {
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

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

/// What a node exposes to the monitor. The root of the finished tree is the
/// core endpoint with the smaller id; it reports `parent: None`.
pub type Summary {
  Summary(
    id: NodeId,
    parent: Option(NodeId),
    fragment: FragmentId,
    level: Int,
    state: NodeState,
    halted: Bool,
    tree_edges: List(EdgeId),
  )
}

pub fn summarise(state: State) -> Summary {
  let parent = case state.in_branch {
    None -> None
    Some(j) -> {
      let assert Ok(info) = dict.get(state.edges, j)
      case state.fragment == fragment.Core(j) && state.id < info.peer {
        True -> None
        False -> Some(info.peer)
      }
    }
  }
  Summary(
    id: state.id,
    parent:,
    fragment: state.fragment,
    level: state.level,
    state: state.ns,
    halted: state.halted,
    tree_edges: branch_edges_except(state, None),
  )
}

// ---------------------------------------------------------------------------
// Actor shell
// ---------------------------------------------------------------------------

pub type CtlMsg {
  /// Wire the node to its link actors. Sent once by the network before any
  /// wakeup.
  Attach(links: Dict(EdgeId, Subject(link.Msg)))
  Wake
  FromLink(on: EdgeId, msg: message.Msg)
  GetSummary(reply: Subject(Summary))
}

pub type Handle {
  Handle(
    pid: Pid,
    control: Subject(CtlMsg),
    delivery: Subject(message.Delivery),
  )
}

type Shell {
  Shell(
    core: State,
    links: Dict(EdgeId, Subject(link.Msg)),
    logger: Option(Subject(logger.Msg)),
  )
}

pub fn start(
  id: NodeId,
  incident: List(#(EdgeId, NodeId, Int)),
  lg: Option(Subject(logger.Msg)),
) -> Handle {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(control) {
      let delivery = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(control)
        |> process.select_map(delivery, fn(d: message.Delivery) {
          FromLink(d.on, d.msg)
        })
      actor.initialised(Shell(init(id, incident), dict.new(), lg))
      |> actor.selecting(selector)
      |> actor.returning(#(control, delivery))
      |> Ok
    })
    |> actor.on_message(shell_handle)
    |> actor.start
  let #(control, delivery) = started.data
  Handle(pid: started.pid, control:, delivery:)
}

fn shell_handle(shell: Shell, msg: CtlMsg) -> actor.Next(Shell, CtlMsg) {
  case msg {
    Attach(links) -> actor.continue(Shell(..shell, links:))
    Wake -> run(shell, Wakeup)
    FromLink(on, m) -> run(shell, Receive(on, m))
    GetSummary(reply) -> {
      process.send(reply, summarise(shell.core))
      actor.continue(shell)
    }
  }
}

fn run(shell: Shell, event: Event) -> actor.Next(Shell, CtlMsg) {
  let #(core, effects) = handle(shell.core, event)
  list.each(effects, fn(effect) {
    let Send(on, m) = effect
    case dict.get(shell.links, on) {
      Ok(l) -> {
        process.send(l, link.Transmit(core.id, m))
        case shell.logger {
          Some(lg) -> process.send(lg, logger.Sent(core.id))
          None -> Nil
        }
      }
      Error(_) -> Nil
    }
  })
  actor.continue(Shell(..shell, core:))
}
