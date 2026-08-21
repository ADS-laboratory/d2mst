//// Central logging service.
////
//// This is an *interface* component: the protocol never depends on it and
//// the system keeps working if it crashes. 

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

pub type Msg {
  Sent(by: NodeId)
  StateChanged(summary: Summary)
  GetLatest(reply: Subject(Dict(NodeId, Summary)))
  GetCounts(reply: Subject(Dict(NodeId, Int)))
  Reset
}

type State {
  State(latest: Dict(NodeId, Summary), counts: Dict(NodeId, Int))
}

fn empty() -> State {
  State(latest: dict.new(), counts: dict.new())
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
    Sent(by) -> {
      let counts =
        dict.upsert(state.counts, by, fn(n) {
          case n {
            Some(n) -> n + 1
            None -> 1
          }
        })
      actor.continue(State(..state, counts:))
    }
    StateChanged(summary) -> {
      let latest = dict.insert(state.latest, summary.id, summary)
      actor.continue(State(..state, latest:))
    }
    GetLatest(reply) -> {
      process.send(reply, state.latest)
      actor.continue(state)
    }
    GetCounts(reply) -> {
      process.send(reply, state.counts)
      actor.continue(state)
    }
    Reset -> actor.continue(empty())
  }
}

/// The call timeout used to poll the logger actor.
const query_timeout_ms = 10_000

/// Fetch the latest reported `Summary` per node.
pub fn latest(lg: Subject(Msg), timeout: Int) -> Dict(NodeId, Summary) {
  process.call(lg, timeout, GetLatest)
}

/// `latest`'s entries restricted to `ids`, sorted by node id. Nodes with no
/// `StateChanged` report yet (or no longer part of the network, e.g.
/// crashed) are not in the result.
pub fn reconstruct(
  latest: Dict(NodeId, Summary),
  ids: List(NodeId),
) -> List(Summary) {
  ids
  |> list.filter_map(fn(id) { dict.get(latest, id) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

/// Fetch the running per-node message counts.
pub fn counts(lg: Subject(Msg), timeout: Int) -> Dict(NodeId, Int) {
  process.call(lg, timeout, GetCounts)
}

/// Total number of protocol messages recorded.
pub fn total(counts: Dict(NodeId, Int)) -> Int {
  dict.fold(counts, 0, fn(acc, _, n) { acc + n })
}

pub fn format_counts(counts: Dict(NodeId, Int)) -> String {
  "messages sent: " <> int.to_string(total(counts))
}

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
      let s = reconstruct(latest(lg, query_timeout_ms), ids)
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
