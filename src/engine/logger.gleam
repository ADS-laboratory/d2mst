//// Central logging service.
////
//// This is an *interface* component: the protocol never depends on it and
//// the system keeps working if it crashes. It does not keep any
//// materialized view of the network — it only records what nodes report
//// (`Sent`, one per protocol message transmitted; `StateChanged`, a node's
//// latest `Summary`) as a single ordered `history`.

import d2mst/fragment
import d2mst/graph.{type EdgeId, type NodeId}
import d2mst/node.{type NodeState}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string

/// What a node exposes to observers. The root of a tree reports `parent: None`.
pub type Summary {
  Summary(
    id: NodeId,
    parent: Option(NodeId),
    fragment: fragment.FragmentId,
    level: Int,
    state: NodeState,
    halted: Bool,
    tree_edges: List(EdgeId),
  )
}

pub fn summarise(state: node.State) -> Summary {
  let parent = case state.parent_edge {
    None -> None
    Some(j) -> {
      let assert Ok(info) = dict.get(state.edges, j)
      Some(info.peer)
    }
  }
  Summary(
    id: state.id,
    parent:,
    fragment: state.fragment,
    level: state.level,
    state: state.ns,
    halted: state.halted,
    tree_edges: node.branch_edges_except(state, None),
  )
}

pub type Event {
  MessageSent(by: NodeId)
  StateUpdated(summary: Summary)
}

pub type Entry {
  Entry(seq: Int, event: Event)
}

pub type Msg {
  Sent(by: NodeId)
  StateChanged(summary: Summary)
  GetHistory(reply: Subject(List(Entry)))
  Reset
}

type State {
  State(log: List(Entry), seq: Int)
}

fn empty() -> State {
  State(log: [], seq: 0)
}

pub fn start() -> Subject(Msg) {
  let assert Ok(started) =
    actor.new(empty())
    |> actor.on_message(handle)
    |> actor.start
  // Interface component: it may crash (or be killed in tests) without
  // taking the rest of the system down.
  process.unlink(started.pid)
  started.data
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Sent(by) -> record(state, MessageSent(by))
    StateChanged(summary) -> record(state, StateUpdated(summary))
    GetHistory(reply) -> {
      process.send(reply, list.reverse(state.log))
      actor.continue(state)
    }
    Reset -> actor.continue(empty())
  }
}

fn record(state: State, event: Event) -> actor.Next(State, Msg) {
  let entry = Entry(state.seq, event)
  actor.continue(State(log: [entry, ..state.log], seq: state.seq + 1))
}

// ---------------------------------------------------------------------------
// Reconstruction: pure folds over a history, usable live or offline.
// ---------------------------------------------------------------------------

pub fn history(lg: Subject(Msg), timeout: Int) -> List(Entry) {
  process.call(lg, timeout, GetHistory)
}

/// Per-node message counts, folded from `history`.
pub fn counts(history: List(Entry)) -> Dict(NodeId, Int) {
  list.fold(history, dict.new(), fn(acc, e) {
    case e.event {
      MessageSent(by) ->
        dict.upsert(acc, by, fn(n) {
          case n {
            Some(n) -> n + 1
            None -> 1
          }
        })
      StateUpdated(_) -> acc
    }
  })
}

/// Total number of protocol messages recorded.
pub fn total(counts: Dict(NodeId, Int)) -> Int {
  dict.fold(counts, 0, fn(acc, _, n) { acc + n })
}

pub fn format_counts(counts: Dict(NodeId, Int)) -> String {
  "messages sent: " <> int.to_string(total(counts))
}

/// The latest known summary of every node in `ids`, folded from `history`.
/// Nodes with no `StateUpdated` entry (or no longer part of the network,
/// e.g. crashed) are not in the result.
pub fn reconstruct(history: List(Entry), ids: List(NodeId)) -> List(Summary) {
  let latest =
    list.fold(history, dict.new(), fn(acc, e) {
      case e.event {
        StateUpdated(s) -> dict.insert(acc, s.id, s)
        MessageSent(_) -> acc
      }
    })
  ids
  |> list.filter_map(fn(id) { dict.get(latest, id) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

/// `history`'s call timeout when polled by `await_halt`
const query_timeout_ms = 10_000

/// Poll until every node in `ids` has reported a halted summary, or give up
/// after `attempts`.
pub fn await_halt(
  lg: Subject(Msg),
  ids: List(NodeId),
  attempts: Int,
  interval_ms: Int,
) -> Result(List(Summary), Nil) {
  case attempts {
    0 -> Error(Nil)
    _ -> {
      let s = reconstruct(history(lg, query_timeout_ms), ids)
      case
        list.length(s) == list.length(ids) && list.all(s, fn(r) { r.halted })
      {
        True -> Ok(s)
        False -> {
          process.sleep(interval_ms)
          await_halt(lg, ids, attempts - 1, interval_ms)
        }
      }
    }
  }
}

/// Union of the tree (branch) edges reported by all nodes.
pub fn tree_edges(summaries: List(Summary)) -> Set(EdgeId) {
  list.fold(summaries, set.new(), fn(acc, s) {
    list.fold(s.tree_edges, acc, set.insert)
  })
}

pub fn format(summaries: List(Summary)) -> String {
  summaries
  |> list.map(fn(s) {
    let parent = case s.parent {
      None -> "root"
      Some(p) -> "parent " <> int.to_string(p)
    }
    "node " <> int.to_string(s.id) <> ": " <> parent
  })
  |> string.join("\n")
}
