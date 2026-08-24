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

/// One node's contribution to a binary-search round: the XOR of a hash of 
/// `id(e)` over the tested range, the (min, max) edge, and a priority-sampled
/// subset of the non-tree edges seen in that range (`None`/`[]` if none were 
/// found).
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
  /// only once, to start a search
  BsRound
  /// Convergecast reply to `BsRound`.
  BsRoundReport(scan: BsScan)
  /// Phase 3 Binary search: tests both halves of a known range `[lo, hi]`
  /// split at `pivot` in the same round
  BsSplit(lo: Edge, pivot: Edge, hi: Edge)
  /// Convergecast reply to `BsSplit`: one `BsScan` per half.
  BsSplitReport(left: BsScan, right: BsScan)
  /// Root -> all: the search converged on a single edge: broadcast that edge's
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

  /// Sent by whichever endpoint's `AddTest` first discovers `event_id`
  /// forms a same-fragment cycle, up toward the root, asking for the
  /// fragment's addition/merge turn *before* either endpoint starts
  /// climbing to find the cycle (report ch. 3, "Overlapping cycles
  /// serialization"). Both endpoints independently make this same
  /// discovery and may each send one; the root dedupes.
  AddRequestTurn(event_id: EdgeId)

  /// Root -> whole tree: `event_id` has the fragment's turn. Whichever two
  /// nodes are its endpoints (only they know) start climbing to find the
  /// cycle's heaviest edge on receipt; every other node just relays it.
  /// Broadcasting is what lets both endpoints' climbs start regardless of
  /// which of them originally asked -- see `addition.grant_addition`.
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
  // The current protocol assumes ordered delivery. Supporting reordering
  // would require a monotonic round counter and stale-message checks.
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
