//// The node state data structure for the D2MST protocol and some helper 
//// functions to manipulate it.

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
  /// `via_addition`: this edge was registered through the Tier 3
  /// `addition.add_edge` entry point rather than present from `init`. Used
  /// purely to retry an addition round abandoned mid-flight by a
  /// concurrent failure (see `d2m.retry_abandoned_additions`): once this
  /// node is quiescent again, any incident edge that is still `Undecided`
  /// *and* came in this way gets re-probed with a fresh `AddTest`, since
  /// nothing else re-drives it after the fragment-mismatch discard.
  ///
  /// `confirmed`: this side has both sent *and received* a `Connect` for
  /// this edge (set by `d2m.on_connect`'s mutual branch). `status ==
  /// Selected` alone only means *this* side decided to merge -- the two
  /// sides of a cross-fragment merge can complete at very different times
  /// (a fragment's own root merges immediately, a non-root side has to ask
  /// its root first), so a `Selected`-but-not-`confirmed` edge means this
  /// side is still waiting to hear back. `addition.on_edge_test` uses that
  /// distinction to keep nudging a peer that is still stuck (see its
  /// top-level guard) instead of silently ignoring it, which used to
  /// strand the slower side forever whenever its one shot at asking its
  /// root got dropped during a concurrent repair.
  EdgeInfo(
    peer: NodeId,
    edge: Edge,
    status: EdgeStatus,
    via_addition: Bool,
    confirmed: Bool,
  )
}

/// What an LCA decided once both `Addition` branches converged on it,
/// stashed until the root's `Privilege` token authorizes acting on it.
/// `target_origin`/`next_edge` name the branch that reported the cycle's
/// heaviest edge (which gets pruned); `other_origin`/`other_next_edge` name
/// the other branch (which only needs its own side of the new edge
/// attached, no pruning or reversal).
pub type ReplaceDecision {
  ReplaceDecision(
    should_prune: Bool,
    target_origin: NodeId,
    next_edge: EdgeId,
    other_origin: NodeId,
    other_next_edge: EdgeId,
    max_weight: Int,
    max_edge: EdgeId,
    already_at_max_edge: Bool,
  )
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
    /// Pending additions, waiting for the other branch to arrive at the LCA.
    /// The third element is the fragment id this node had when the entry
    /// was stored: a re-identification (Phase 1/2, or `d2m.on_connect`'s
    /// merge) clears these outright (see `clear_addition_state`), but that
    /// only catches the entry if *this* node is the one that re-identifies.
    /// A relay node the abandoned round already passed through, sitting
    /// just outside the re-identifying region, keeps its entry -- the tag
    /// lets `addition.on_addition` recognize it as stale the next time a
    /// live round for the same event_id passes through, instead of
    /// wrongly treating it as a genuine sibling arrival.
    pending_additions: Dict(EdgeId, #(message.AddMsg, EdgeId, FragmentId)),
    /// Every node strictly between an LCA and the root, on the path an
    /// `AddRequestTurn` travelled: event id -> the child edge to route the
    /// matching `Privilege` back down to. Never populated at the LCA
    /// itself (it has `ready_replace` instead) nor below it.
    turn_routing: Dict(EdgeId, EdgeId),
    /// LCA-side: decisions computed once both `Addition` branches
    /// converged, waiting for their `Privilege` token before acting.
    ready_replace: Dict(EdgeId, ReplaceDecision),
    /// LCA-side: how many of the two branches' `AddDone` acks are still
    /// outstanding for an event currently being executed.
    replace_wait_countdown: Dict(EdgeId, Int),
    /// Root-side: addition events waiting their turn, in arrival order.
    addition_queue: List(EdgeId),
    /// Root-side: the event currently authorized to run, if any. The root
    /// only grants the next queued event once this clears.
    addition_active: Option(EdgeId),
    /// Root-side: cross-fragment merge requests that arrived while
    /// `addition_active` was already busy with something else and lost
    /// `preempt_or_keep`'s tie-break, in arrival order. Retried, one at a
    /// time, every time `addition_active` frees up
    pending_merges: List(EdgeId),
  )
}

/// Excludes `via_addition` edges: those are driven exclusively by the
/// addition protocol (`on_edge_test`/`on_addition`/`retry_abandoned_additions`),
/// never by the ordinary MOE search. Without this exclusion, an unrelated
/// concurrent repair's Phase 3 search can probe a `via_addition` edge still
/// mid-flight in the addition protocol, see it as transiently "outgoing"
/// (the two endpoints haven't converged on the same fragment identity yet),
/// and claim it via the plain GHS merge path (`on_connect`) -- which just
/// marks it Selected, bypassing the cycle max-weight prune that the
/// addition protocol's `on_replace`/`execute_decision` is responsible for.
pub fn min_undecided_edge(state: State) -> Option(EdgeId) {
  min_edge(state, fn(info) { info.status == Undecided && !info.via_addition })
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
        EdgeInfo(
          peer:,
          edge: e,
          status: Undecided,
          via_addition: False,
          confirmed: False,
        ),
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
    pending_additions: dict.new(),
    turn_routing: dict.new(),
    ready_replace: dict.new(),
    replace_wait_countdown: dict.new(),
    addition_queue: [],
    addition_active: None,
    pending_merges: [],
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
      EdgeInfo(
        peer:,
        edge:,
        status: Undecided,
        via_addition: False,
        confirmed: False,
      ),
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

/// Marks an edge's cross-fragment merge as mutually confirmed: this side
/// has both sent and received a `Connect` for it. See `EdgeInfo.confirmed`.
pub fn set_confirmed(state: State, eid: EdgeId) -> State {
  let assert Ok(info) = dict.get(state.edges, eid)
  State(
    ..state,
    edges: dict.insert(state.edges, eid, EdgeInfo(..info, confirmed: True)),
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

/// Clears every piece of addition-response bookkeeping tied to this node's
/// *current* fragment identity. Must be called anywhere `state.fragment` is
/// reassigned (see `d2m.start_reiden_phase`/`d2m.on_connect`): any
/// Addition/AddRequestTurn/Privilege/Replace/AddDone wave still travelling
/// under the old identity gets silently discarded the instant it crosses a
/// node that has already re-identified (`message.add_is_intra_fragment`),
/// so the local state it left behind is dead and nothing else revisits it.
/// Left uncleared, `addition_active` in particular can wedge a root
/// forever: it only ever clears on a matching `AddDone`, which an orphaned
/// event will never produce.
///
/// This only protects a node that itself re-identifies. A relay just
/// outside the re-identifying region can still be left holding a stale
/// `pending_additions` entry -- see that field's doc for the complementary,
/// self-defending fix in `addition.on_addition`.
pub fn clear_addition_state(state: State) -> State {
  State(
    ..state,
    pending_additions: dict.new(),
    turn_routing: dict.new(),
    ready_replace: dict.new(),
    replace_wait_countdown: dict.new(),
    addition_queue: [],
    addition_active: None,
    pending_merges: [],
  )
}

/// None means infinity.
pub fn opt_less(a: Option(Edge), b: Option(Edge)) -> Bool {
  case a, b {
    Some(x), Some(y) -> graph.edge_less(x, y)
    Some(_), None -> True
    None, _ -> False
  }
}
