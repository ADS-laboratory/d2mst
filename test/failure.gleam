import d2mst/graph
import engine/logger
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import gleeunit/should
import sim/generator.{connected}
import sim/oracle.{check}
import sim/runner.{converge, fail_link, settle, summaries}

pub fn single_link_failure_recovery_test() {
  let g = connected(123, 5, 50)

  // Initial convergence.
  let sim = converge(g)
  check(sim.graph, summaries(sim)) |> should.be_ok

  // Print all edges
  io.println("Edges:")
  list.each(sim.graph.edges, fn(e) {
    io.println(
      string.inspect(e.u)
      <> " <-> "
      <> string.inspect(e.v)
      <> " ("
      <> int.to_string(e.weight)
      <> ")",
    )
  })
  // Debug print the mst
  io.println("MST:")
  io.println(logger.format(summaries(sim)))

  // Remove a Selected edge from the graph by iterating on the edges and choosing the first selected one
  let selected_edges =
    list.flatten(
      list.map(summaries(sim), fn(summary) {
        list.map(summary.tree_edges, fn(edge_id) { edge_id })
      }),
    )

  // Topology change: drop the first edge in the graph.
  let assert [target_edge_id, ..] = selected_edges
  let assert Ok(target_edge) = graph.find_edge(sim.graph, target_edge_id)

  io.println(
    "Failing edge: "
    <> string.inspect(target_edge.u)
    <> " <-> "
    <> string.inspect(target_edge.v),
  )

  let sim_failed = fail_link(sim, target_edge.u, target_edge.v)

  // Let the protocol converge again.
  let sim_recovered = settle(sim_failed)

  io.println("MST after recovery:")
  io.println(logger.format(summaries(sim_recovered)))

  // Verify the protocol found the new MST for the degraded graph.
  check(sim_recovered.graph, summaries(sim_recovered))
  |> should.be_ok
}
