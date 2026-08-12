import gleam/list
import gleeunit/should
import sim/generator.{connected}
import sim/oracle.{check}
import sim/runner.{converge, fail_link, settle, summaries}

pub fn single_link_failure_recovery_test() {
  let g = connected(123, 20, 50)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Topology change: drop the first edge in the graph.
  let assert [target_edge, ..] = sim.graph.edges
  let sim_failed = fail_link(sim, target_edge.u, target_edge.v)

  // Let the protocol converge again.
  let sim_recovered = settle(sim_failed)

  // Verify the protocol found the new MST for the degraded graph.
  check(sim_recovered.graph, summaries(sim_recovered))
  |> should.be_ok
}
