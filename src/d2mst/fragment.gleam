//// Fragment identity.
////
//// During GHS construction a fragment is either a single sleeping/level-0
//// node or is named after its core edge. Later tiers extend this with the
//// (weight, node, counter) identities used by the dynamic repair protocols.

import d2mst/graph.{type EdgeId, type NodeId}
import gleam/option.{type Option}

pub type FragmentId {
  /// A level-0 fragment containing only the given node.
  Singleton(node: NodeId)
  /// A fragment containing multiple nodes is identified by its core edge.
  /// 
  /// - If the fragment is formed after an edge addition, the node Option is None.
  /// - If the fragment is formed after an edge removal, the node field is used to
  ///   break the symmetry between the two endpoints of the core edge: each formed
  ///   fragment will hold the node id of the endpoint that is in the fragment.
  /// 
  /// The counter is used to distinguish between old and new failures / additions of the
  /// same edge: the counter is incremented each time the edge is removed.
  D2MCore(edge: EdgeId, node: Option(NodeId), counter: Int)
  GHSCore(edge: EdgeId)
}
