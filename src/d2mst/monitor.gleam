//// Monitoring service: assembles a global snapshot of the tree by querying
//// every node. Like the logger this is an *interface* component — the
//// protocol nodes never depend on it, so its failure cannot harm the system.

import d2mst/graph.{type EdgeId}
import d2mst/network.{type Network}
import d2mst/node
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set.{type Set}
import gleam/string

pub fn snapshot(net: Network, timeout: Int) -> List(node.Summary) {
  dict.to_list(net.nodes)
  |> list.map(fn(p) { process.call({ p.1 }.control, timeout, node.GetSummary) })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

/// Poll until every node reports halted, or give up after `attempts`.
pub fn await_halt(
  net: Network,
  attempts: Int,
  interval_ms: Int,
) -> Result(List(node.Summary), Nil) {
  case attempts {
    0 -> Error(Nil)
    _ -> {
      let s = snapshot(net, 1000)
      case list.all(s, fn(r) { r.halted }) {
        True -> Ok(s)
        False -> {
          process.sleep(interval_ms)
          await_halt(net, attempts - 1, interval_ms)
        }
      }
    }
  }
}

/// Union of the tree (branch) edges reported by all nodes.
pub fn tree_edges(summaries: List(node.Summary)) -> Set(EdgeId) {
  list.fold(summaries, set.new(), fn(acc, s) {
    list.fold(s.tree_edges, acc, set.insert)
  })
}

pub fn format(summaries: List(node.Summary)) -> String {
  summaries
  |> list.map(fn(s) {
    let parent = case s.parent {
      None -> "root"
      Some(p) -> "parent " <> int.to_string(p)
    }
    "node " <> int.to_string(s.id) <> ": " <> parent
  })
  |> string.join("\n")
}
