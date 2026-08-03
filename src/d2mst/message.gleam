//// Wire-level protocol messages exchanged between nodes over links.

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId}
import gleam/option.{type Option}

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

pub type D2MMsg {
  /// Phase 1:
  ReportFailure(failed_edge: EdgeId)
  /// Phase 2:
  ReIden
  ReIdenAck
  /// Phase 3 Naive:
  ProbeMoe
  ProbeReply(is_outgoing: Bool)
  ReportMoe(best: Option(Edge))
  /// Phase 4
  Connect
}

pub type Msg {
  // Plain GHS messages used to build the initial MST.
  GHSMsg(msg: GHSMsg)
  // D2M messages used to repair the MST after a failure or addition. Fragment identity is
  // included in every message to discard old messages from previous fragment versions.
  D2MMsg(msg: D2MMsg, fragment: FragmentId)
}

/// What a link delivers to an endpoint node: the protocol message together
/// with the edge it arrived on.
pub type Delivery {
  Delivery(on: EdgeId, msg: Msg)
}
