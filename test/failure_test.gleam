import d2mst/graph
import gleam/list
import gleeunit/should
import sim/generator.{connected}
import sim/oracle.{check}
import sim/runner.{converge, fail_link, settle, summaries}

pub fn single_link_failure_recovery_test() {
  let g = connected(123, 5, 50)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Remove a Selected edge from the graph.
  let selected_edges =
    list.flatten(list.map(summaries(sim), fn(summary) { summary.tree_edges }))

  // Topology change: drop the first edge in the graph.
  let assert [target_edge_id, ..] = selected_edges
  let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

  let sim_failed = fail_link(sim, target_edge.u, target_edge.v)

  // Let the protocol converge again.
  let sim_recovered = settle(sim_failed)

  // Verify the protocol found the new MST for the degraded graph.
  check(sim_recovered.graph, summaries(sim_recovered))
  |> should.be_ok
}

pub fn sequential_link_failures_recovery_test() {
  let g = connected(101, 6, 60)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Failure 1.
  let assert [edge1_id, ..] =
    list.flatten(list.map(summaries(sim), fn(s) { s.tree_edges }))
  let assert Ok(edge1) = graph.find_edge(sim.graph, edge1_id)

  let sim1 = fail_link(sim, edge1.u, edge1.v) |> settle
  check(sim1.graph, summaries(sim1)) |> should.be_ok

  // Failure 2 (on the newly formed MST).
  let assert [edge2_id, ..] =
    list.flatten(list.map(summaries(sim1), fn(s) { s.tree_edges }))
  let assert Ok(edge2) = graph.find_edge(sim1.graph, edge2_id)

  let sim2 = fail_link(sim1, edge2.u, edge2.v) |> settle
  check(sim2.graph, summaries(sim2)) |> should.be_ok
}

pub fn fuzz_multiple_topologies_test() {
  // Test seeds 1 through 50.
  let seeds = generator.ints(1, 50)

  list.each(seeds, fn(seed) {
    let g = connected(seed, 10, 30)
    let sim = converge(g)

    // Failure: remove a random edge from the MST.
    let assert [target_edge_id, ..] =
      list.flatten(list.map(summaries(sim), fn(summary) { summary.tree_edges }))
    let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

    let sim = fail_link(sim, target_edge.u, target_edge.v) |> settle

    check(sim.graph, summaries(sim))
    |> should.be_ok
  })
}
