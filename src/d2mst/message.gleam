//// Wire-level protocol messages exchanged between nodes over links.

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId}
import gleam/option.{type Option}

/// GHS protocol messages. `Report(None)` means "no outgoing edge found"
/// (infinite weight in the original paper). `Halt` is our addition: once the
/// core detects termination it broadcasts it down the tree so every node
/// (and the tests) can observe completion.
pub type Msg {
  Connect(level: Int)
  Initiate(level: Int, fragment: FragmentId, find: Bool)
  Test(level: Int, fragment: FragmentId)
  Accept
  Reject
  Report(best: Option(Edge))
  ChangeRoot
  Halt
}

/// What a link delivers to an endpoint node: the protocol message together
/// with the edge it arrived on.
pub type Delivery {
  Delivery(on: EdgeId, msg: Msg)
}
