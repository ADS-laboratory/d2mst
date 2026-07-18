import d2mst/fragment
import d2mst/graph

pub fn identity_test() {
  // Both endpoints derive the same core name for the same edge, regardless
  // of the order they see the endpoints in.
  assert fragment.Core(graph.edge_id(3, 1))
    == fragment.Core(graph.edge_id(1, 3))
  assert fragment.Core(graph.edge_id(1, 3))
    != fragment.Core(graph.edge_id(1, 2))
}
