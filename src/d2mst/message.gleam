//// Wire-level protocol messages exchanged between nodes over links.

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId, type NodeId}
import gleam/option.{type Option, None}

/// GHS protocol messages. `Notify(None)` means "no outgoing edge found"
/// (infinite weight in the original paper). `Halt` is our addition: once the
/// core detects termination it broadcasts it down the tree so every node
/// (and the tests) can observe completion.
pub type GHSMsg {
  Merge(level: Int)
  Initiate(level: Int, fragment: FragmentId, find: Bool)
  Test(level: Int, fragment: FragmentId)
  Accept
  Reject
  Notify(best: Option(Edge))
  ChangeRoot
  Halt
}

/// One node's contribution to a binary-search round (Phase 3,
/// `BinarySearch` strategy): the XOR of a hash of `id(e)` over the tested
/// range (TestOut — hashed rather than the raw id so that two *different*
/// outgoing edges landing in the same range essentially never cancel each
/// other out by coincidence; same-fragment edges still cancel exactly,
/// since both endpoints hash the same id), the (min, max) edge, and a
/// priority-sampled subset of the non-tree edges seen in that range
/// (`None`/`[]` if none were found). Convergecast replies merge these
/// pointwise (see `d2m.merge_scan`); `bs_scan_zero` is the empty one.
pub type BsScan {
  BsScan(xor: Int, bounds: Option(#(Edge, Edge)), sample: List(#(EdgeId, Edge)))
}

pub const bs_scan_zero = BsScan(xor: 0, bounds: None, sample: [])

pub type D2MMsg {
  /// Phase 1: Carry the new identity to the root, so it can start the re-identification
  ReportFailure(new_fragment: FragmentId)
  /// Phase 2: the new identity rides in the enclosing `D2MMsg.fragment`.
  ReIden
  ReIdenAck
  /// Phase 3 Naive:
  ProbeMoe
  ProbeEdge
  ProbeReply(is_outgoing: Bool, probed: FragmentId)
  ReportMoe(best: Option(Edge))
  /// Phase 3 Binary search: scans the whole fragment, unfiltered. Sent
  /// only once, to start a search — nothing is known yet, so there is no
  /// range to narrow to.
  BsRound
  /// Convergecast reply to `BsRound`.
  BsRoundReport(scan: BsScan)
  /// Phase 3 Binary search: tests both halves of a known range `[lo, hi]`
  /// split at `pivot` — `[lo, pivot]` and `(pivot, hi]` — in the same
  /// round, so whichever half turns out to hold the edge already has
  /// fresh bounds/sample to pick the next pivot from; no extra round
  /// needed to go back and scan it.
  BsSplit(lo: Edge, pivot: Edge, hi: Edge)
  /// Convergecast reply to `BsSplit`: one `BsScan` per half.
  BsSplitReport(left: BsScan, right: BsScan)
  /// Root -> all: the search converged on a single edge (comparison order
  /// has no ties, so this identifies exactly one) — broadcast that edge's
  /// id down the whole tree so its owning endpoint can claim it. See
  /// `d2m.start_bs_merge`.
  BsMoeFound(target: EdgeId)
  /// Phase 4
  SignalConnect
  Connect
  GoSleep
}

pub type AddMsg {
  AddTest

  /// Sent to the root to request merging a partitioned network.
  AddRequestMergePartition(add_edge: EdgeId)
  /// Sent by the root to authorize the endpoint to execute the merge.
  AddApproveMergePartition(add_edge: EdgeId)

  /// Sent upward by both endpoints u and v toward the root.
  Addition(
    event_id: EdgeId,
    new_weight: Int,
    origin: NodeId,
    running_max: Int,
    max_edge: EdgeId,
  )

  /// Dispatched by LCA to prune the heaviest edge and update tree direction[cite: 20].
  /// `should_prune: False` still travels the full routing path (every
  /// intermediate node clears its `pending_additions` entry for
  /// `event_id`, same as the pruning case) but touches no edge status and
  /// never reverses a parent pointer: a no-op decision still needs its
  /// stale routing state cleaned up, or a later re-probe of the same edge
  /// id could mistake a leftover entry for an in-progress round.
  Replace(
    event_id: EdgeId,
    target_origin: NodeId,
    max_weight: Int,
    max_edge: EdgeId,
    reversing: Bool,
    should_prune: Bool,
  )

  /// Sent by an LCA once both `Addition` branches converged on it, up
  /// toward the root, so the root can serialize it against other
  /// concurrently-converging additions (report ch. 3, "Overlapping cycles
  /// serialization"). Deliberately a distinct message from `Addition`
  /// rather than a continuation of it: from a relaying node's own local
  /// view, "first `Addition` for this event, forward it up" is
  /// indistinguishable between "I might be the LCA, wait for a sibling"
  /// and "the LCA further down already resolved this, I'm just relaying
  /// its request" -- the message type is what tells them apart.
  AddRequestTurn(event_id: EdgeId)

  /// Token sent by the root down to the LCA (and only the LCA -- routing
  /// stops there, see `addition.execute_or_route`) authorizing it to act
  /// on the decision it already computed.
  Privilege(event_id: EdgeId)

  /// Sent by whichever node finishes a `Replace` chain (winning or losing
  /// branch), up the standing (possibly just-reversed) parent chain. The
  /// LCA that coordinated the event counts these down to know when to
  /// report completion to the root; every other node just relays it
  /// upward.
  AddDone(event_id: EdgeId)
}

pub type Msg {
  // Plain GHS messages used to build the initial MST.
  GHSMsg(msg: GHSMsg)
  // TODO: if messages are not delivered in order, the receiver must keep 
  // a monotonic round counter and discard messages with a lower round than
  // the last one it received.
  D2MMsg(msg: D2MMsg, fragment: FragmentId)

  AddMsg(msg: AddMsg, fragment: FragmentId)
}

/// What a link delivers to an endpoint node: the protocol message together
/// with the edge it arrived on.
pub type Delivery {
  Delivery(on: EdgeId, msg: Msg)
}

/// - `ReportFailure` reports a physical topology change, it is not a 
///   protocol round, it must always reach the root
/// - `ReIden` is what carries the identity, so it cannot be validated against 
///   the receiver old identity
/// - `ProbeEdge` / `ProbeReply` / `Connect` cross the fragment boundary by
///   design
pub fn fail_is_intra_fragment(msg: D2MMsg) -> Bool {
  case msg {
    ReIdenAck
    | ProbeMoe
    | ReportMoe(..)
    | BsRound
    | BsRoundReport(..)
    | BsSplit(..)
    | BsSplitReport(..)
    | BsMoeFound(..)
    | SignalConnect
    | GoSleep -> True

    ReportFailure(..) | ReIden | ProbeEdge | ProbeReply(..) | Connect -> False
  }
}

pub fn add_is_intra_fragment(msg: AddMsg) -> Bool {
  case msg {
    AddRequestMergePartition(..)
    | AddApproveMergePartition(..)
    | Addition(..)
    | Replace(..)
    | AddRequestTurn(..)
    | Privilege(..)
    | AddDone(..) -> True
    AddTest -> False
  }
}
