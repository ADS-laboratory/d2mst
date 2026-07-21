//// Convergence oracle: checks a set of node summaries against the unique
//// MST of the graph (Kruskal reference) and the rooted-tree invariants.

import d2mst/graph.{type Graph}
import engine/logger
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set

pub fn check(g: Graph, summaries: List(logger.Summary)) -> Result(Nil, String) {
  let all_halted = list.all(summaries, fn(s) { s.halted })
  let branch =
    list.fold(summaries, set.new(), fn(acc, s) {
      list.fold(s.tree_edges, acc, set.insert)
    })
  let reference =
    graph.kruskal(g)
    |> list.fold(set.new(), fn(acc, e) {
      set.insert(acc, graph.edge_id(e.u, e.v))
    })
  let roots = list.filter(summaries, fn(s) { s.parent == None }) |> list.length
  let components = graph.components(g)
  let parents_ok =
    list.all(summaries, fn(s) {
      case s.parent {
        None -> True
        Some(p) -> set.contains(branch, graph.edge_id(s.id, p))
      }
    })

  use <- bool.guard(!all_halted, Error("not all nodes halted"))
  use <- bool.guard(
    branch != reference,
    Error("tree edges differ from the unique MST"),
  )
  use <- bool.guard(
    roots != components,
    Error(
      "expected "
      <> int.to_string(components)
      <> " root(s), found "
      <> int.to_string(roots),
    ),
  )
  use <- bool.guard(!parents_ok, Error("a parent pointer is not a tree edge"))
  Ok(Nil)
}
