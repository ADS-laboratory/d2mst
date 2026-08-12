import d2mst/fragment
import d2mst/graph
import gleam/option.{None}

pub fn identity_test() {
  // Both endpoints derive the same core name for the same edge, regardless
  // of the order they see the endpoints in.
  assert fragment.GHSCore(graph.edge_id(3, 1))
    == fragment.GHSCore(graph.edge_id(1, 3))
  assert fragment.GHSCore(graph.edge_id(1, 3))
    != fragment.GHSCore(graph.edge_id(1, 2))
  assert fragment.D2MCore(graph.edge_id(3, 1), None, 1)
    == fragment.D2MCore(graph.edge_id(1, 3), None, 1)
}
