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

/// Which Phase 3 (minimum outgoing edge search) procedure a node runs.
pub type MoeStrategy {
  Naive
  /// `sample_k`: number of edges sampled at each round in order to estimate
  /// the median
  BinarySearch(sample_k: Int)
}

pub fn sample_k(state: State) -> Int {
  let assert BinarySearch(k) = state.moe_strategy
  k
}

pub type NodeState {
  Sleeping
  GHSNodeState(state: GHSNodeState)
  D2MNodeState(state: D2MNodeState)
}

pub type EdgeStatus {
  Undecided
  Selected
  Rejected
}

pub type EdgeInfo {
  EdgeInfo(peer: NodeId, edge: Edge, status: EdgeStatus)
}

/// The node state machine.
pub type State {
  State(
    id: NodeId,
    edges: Dict(EdgeId, EdgeInfo),
    /// `k(e)`: how many times each incident edge has failed so far
    failure_counts: Dict(EdgeId, Int),
    ns: NodeState,
    fragment: FragmentId,
    level: Int,
    parent_edge: Option(EdgeId),
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
    /// Which Phase 3 procedure this node runs; fixed at `init`.
    moe_strategy: MoeStrategy,
    /// Scratch space for the `BinarySearch` strategy only, reset at the
    /// start of every round. `bs_scan` accumulates replies to the search's
    /// initial whole-fragment `BsRound`; `bs_left`/`bs_right` accumulate
    /// the two halves of a `BsSplit` round.
    bs_scan: message.BsScan,
    bs_left: message.BsScan,
    bs_right: message.BsScan,
  )
}

pub fn min_undecided_edge(state: State) -> Option(EdgeId) {
  min_edge(state, fn(info) { info.status == Undecided })
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

/// `incident` lists the graph edges this node is an endpoint of. Runs
/// Phase 3's naive MOE search; use `init_with_strategy` to opt into the
/// binary search variant.
pub fn init(id: NodeId, incident: List(Edge)) -> State {
  init_with_strategy(id, incident, Naive)
}

/// Like `init`, but picks which Phase 3 procedure the node runs.
pub fn init_with_strategy(
  id: NodeId,
  incident: List(Edge),
  moe_strategy: MoeStrategy,
) -> State {
  let edges =
    list.fold(incident, dict.new(), fn(d, e) {
      let peer = graph.other_node(e, id)
      dict.insert(
        d,
        graph.edge_id(e.u, e.v),
        EdgeInfo(peer:, edge: e, status: Undecided),
      )
    })
  State(
    id:,
    edges:,
    failure_counts: dict.new(),
    ns: Sleeping,
    fragment: fragment.Singleton(id),
    level: 0,
    parent_edge: None,
    best_edge: None,
    best_wt: None,
    test_edge: None,
    find_countdown: 0,
    repair_countdown: 0,
    halted: False,
    pending: [],
    moe_strategy:,
    bs_scan: message.bs_scan_zero,
    bs_left: message.bs_scan_zero,
    bs_right: message.bs_scan_zero,
  )
}

/// What this node knows about one of its incident edges.
pub fn edge(state: State, on: EdgeId) -> Result(EdgeInfo, Nil) {
  dict.get(state.edges, on)
}

/// Register a newly added incident edge.
pub fn add_edge(state: State, edge: Edge) -> State {
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

/// how many times this edge has failed so far.
pub fn failure_count(state: State, on: EdgeId) -> Int {
  case dict.get(state.failure_counts, on) {
    Ok(k) -> k
    Error(_) -> 0
  }
}

/// Record one more failure of `on` and return the new count
pub fn bump_failure_count(state: State, on: EdgeId) -> #(State, Int) {
  let k = failure_count(state, on) + 1
  #(State(..state, failure_counts: dict.insert(state.failure_counts, on, k)), k)
}

// --- helpers ---------------------------------------------------------------

// Put a message in the pending queue to be retried later. The message is
// not sent now, so the caller must not send it either.
pub fn defer(state: State, on: EdgeId, msg: message.Msg) -> State {
  State(..state, pending: [#(on, msg), ..state.pending])
}

pub fn set_status(state: State, eid: EdgeId, status: EdgeStatus) -> State {
  let assert Ok(info) = dict.get(state.edges, eid)
  State(
    ..state,
    edges: dict.insert(state.edges, eid, EdgeInfo(..info, status:)),
  )
}

pub fn min_edge(state: State, keep: fn(EdgeInfo) -> Bool) -> Option(EdgeId) {
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
pub fn opt_less(a: Option(Edge), b: Option(Edge)) -> Bool {
  case a, b {
    Some(x), Some(y) -> graph.edge_less(x, y)
    Some(_), None -> True
    None, _ -> False
  }
}
