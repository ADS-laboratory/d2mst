//// Seeded pseudo-random connected graph generator. Pure and deterministic:
//// the same seed always yields the same graph, so failing tests are
//// reproducible by their seed.

import d2mst/graph.{type Graph, Edge, Graph}
import gleam/int
import gleam/list
import gleam/set

pub type Seed =
  Int

/// Inclusive integer range as a list (stdlib 1.x dropped `list.range`).
pub fn ints(from: Int, to_incl: Int) -> List(Int) {
  case from > to_incl {
    True -> []
    False ->
      int.range(from, to_incl + 1, [], fn(acc, i) { [i, ..acc] })
      |> list.reverse
  }
}

fn next(seed: Seed) -> Seed {
  let s = { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
  case s < 0 {
    True -> -s
    False -> s
  }
}

pub fn rand_below(seed: Seed, max: Int) -> #(Int, Seed) {
  let seed = next(seed)
  #(seed % max, seed)
}

/// Connected graph on `n` nodes: a random attachment tree, plus each
/// remaining pair as an extra edge with probability `pct`/100. Raw weights
/// are in 1..100 — duplicates are allowed on purpose, the tie-breaking
/// `graph.compare_edge` order keeps the MST unique anyway.
pub fn connected(seed: Seed, n: Int, pct: Int) -> Graph {
  let nodes = ints(0, n - 1)
  case n < 2 {
    True -> Graph(nodes:, edges: [])
    False -> {
      let #(tree, seed) =
        list.fold(ints(1, n - 1), #([], seed), fn(acc, i) {
          let #(edges, seed) = acc
          let #(j, seed) = rand_below(seed, i)
          let #(w, seed) = rand_below(seed, 100)
          #([Edge(j, i, w + 1), ..edges], seed)
        })
      let taken =
        list.fold(tree, set.new(), fn(s, e) {
          set.insert(s, graph.edge_id(e.u, e.v))
        })
      let pairs =
        list.flat_map(ints(0, n - 2), fn(i) {
          list.map(ints(i + 1, n - 1), fn(j) { #(i, j) })
        })
      let #(extra, _) =
        list.fold(pairs, #([], seed), fn(acc, pair) {
          let #(edges, seed) = acc
          let #(i, j) = pair
          case set.contains(taken, graph.edge_id(i, j)) {
            True -> acc
            False -> {
              let #(roll, seed) = rand_below(seed, 100)
              case roll < pct {
                False -> #(edges, seed)
                True -> {
                  let #(w, seed) = rand_below(seed, 100)
                  #([Edge(i, j, w + 1), ..edges], seed)
                }
              }
            }
          }
        })
      Graph(nodes:, edges: list.append(tree, extra))
    }
  }
}
