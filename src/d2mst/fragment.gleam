//// Fragment identity.
////
//// During GHS construction a fragment is either a single sleeping/level-0
//// node or is named after its core edge. Later tiers extend this with the
//// (weight, node, counter) identities used by the dynamic repair protocols.

import d2mst/graph.{type EdgeId, type NodeId}

pub type FragmentId {
  /// A level-0 fragment containing only the given node.
  Singleton(node: NodeId)
  /// A fragment formed by merging, named after its core edge.
  Core(edge: EdgeId)
}
