//// Message-complexity benchmark for the dynamic repair protocols.
////
//// Not a gleeunit test: Run it directly against the built beams:
////
////   gleam build --target erlang
////   erl -pa build/dev/erlang/*/ebin -noshell -eval "bench_report:run(), halt()."
////
//// Produces one table per scenario: rows are graph sizes, columns are how
//// many topology events fire concurrently (unsettled) before the network
//// is allowed to re-converge. Each cell is a mean over several seeds. Failure
//// scenarios are run at two densities

import d2mst/graph.{type Graph}
import d2mst/node
import engine/generator
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/set
import gleam/string
import sim/oracle
import sim/runner.{type Sim}

// --- tunable sweep parameters ------------------------------------------------

const sizes = [10, 20, 40, 80, 160]

const concurrencies = [1, 2, 4, 8]

const seed_count = 15

const sparse_pct = 15

const dense_pct = 85

const addition_pct = 40

fn seeds() -> List(Int) {
  generator.ints(1, seed_count)
}

// --- entry point --------------------------------------------------------

pub fn run() -> Nil {
  io.println("d2mst message-complexity benchmark")
  io.println(
    "sizes="
    <> int.to_string(list.length(sizes))
    <> " concurrencies="
    <> string.inspect(concurrencies)
    <> " seeds/cell="
    <> int.to_string(seed_count),
  )

  failure_table(
    "Failure - naive Phase 3, sparse (edge_pct="
      <> int.to_string(sparse_pct)
      <> ")",
    node.Naive,
    sparse_pct,
  )
  failure_table(
    "Failure - naive Phase 3, dense (edge_pct="
      <> int.to_string(dense_pct)
      <> ")",
    node.Naive,
    dense_pct,
  )
  failure_table(
    "Failure - binary search Phase 3, sparse (edge_pct="
      <> int.to_string(sparse_pct)
      <> ")",
    node.BinarySearch(sample_k: 3),
    sparse_pct,
  )
  failure_table(
    "Failure - binary search Phase 3, dense (edge_pct="
      <> int.to_string(dense_pct)
      <> ")",
    node.BinarySearch(sample_k: 3),
    dense_pct,
  )
  addition_table(
    "Addition, edge_pct=" <> int.to_string(addition_pct),
    addition_pct,
  )
}

// --- per-cell measurement -------------------------------------------------

type Cell {
  Cell(messages: Int, edges: Int, components: Int)
}

fn oracle_ok(sim: Sim) -> Bool {
  case oracle.check(sim.graph, runner.summaries(sim)) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Panic with which scenario/seed/params failed and why.
fn fail(
  scenario: String,
  seed: Int,
  n: Int,
  edge_pct: Int,
  k: Int,
  reason: String,
) -> a {
  panic as {
    scenario
    <> " seed="
    <> int.to_string(seed)
    <> " n="
    <> int.to_string(n)
    <> " edge_pct="
    <> int.to_string(edge_pct)
    <> " k="
    <> int.to_string(k)
    <> ": "
    <> reason
  }
}

/// Step budget for `settle_bounded`
const settle_budget = 400_000

fn settle_bounded(sim: Sim, budget: Int) -> Result(Sim, Nil) {
  case budget <= 0 {
    True -> Error(Nil)
    False ->
      case sim.queue {
        [] -> Ok(sim)
        _ -> settle_bounded(runner.step_one(sim), budget - 1)
      }
  }
}

/// Fail `k` distinct tree edges at once, then settle, and report the burst's message cost.
fn run_failure_cell(
  seed: Int,
  n: Int,
  edge_pct: Int,
  k: Int,
  strategy: node.MoeStrategy,
) -> Cell {
  let scenario = "failure(" <> string.inspect(strategy) <> ")"
  let g = generator.connected(seed, n, edge_pct)
  let sim0 =
    runner.new_with_strategy(g, strategy) |> runner.wake_all |> runner.settle
  case oracle_ok(sim0) {
    True -> Nil
    False ->
      fail(
        scenario,
        seed,
        n,
        edge_pct,
        k,
        "initial build did not converge to correct MST",
      )
  }

  let tree_edges =
    runner.summaries(sim0)
    |> list.flat_map(fn(s) { s.tree_edges })
    |> list.unique
  case list.length(tree_edges) < k {
    False -> Nil
    True ->
      fail(
        scenario,
        seed,
        n,
        edge_pct,
        k,
        "only "
          <> int.to_string(list.length(tree_edges))
          <> " distinct tree edges available, need "
          <> int.to_string(k),
      )
  }
  let #(picked, _) = pick_k(tree_edges, k, seed)

  let before = runner.sent(sim0)
  let sim1 =
    list.fold(picked, sim0, fn(sim, eid) {
      let assert Ok(e) = graph.find_edge(sim.graph, eid)
      runner.fail_link(sim, e.u, e.v)
    })
  let sim2 = case settle_bounded(sim1, settle_budget) {
    Ok(s) -> s
    Error(_) ->
      fail(scenario, seed, n, edge_pct, k, "did not settle within step budget")
  }
  let after = runner.sent(sim2)
  case oracle_ok(sim2) {
    True -> Nil
    False ->
      fail(
        scenario,
        seed,
        n,
        edge_pct,
        k,
        "repair did not converge to correct MST",
      )
  }

  Cell(
    messages: after - before,
    edges: list.length(g.edges),
    components: graph.components(sim2.graph),
  )
}

/// Add `k` edges between distinct non-adjacent pairs at once, then settle.
fn run_addition_cell(seed: Int, n: Int, edge_pct: Int, k: Int) -> Cell {
  let g = generator.connected(seed, n, edge_pct)
  let sim0 = runner.new(g) |> runner.wake_all |> runner.settle
  case oracle_ok(sim0) {
    True -> Nil
    False ->
      fail(
        "addition",
        seed,
        n,
        edge_pct,
        k,
        "initial build did not converge to correct MST",
      )
  }

  let pairs = non_adjacent_pairs(g)
  case list.length(pairs) < k {
    False -> Nil
    True ->
      fail(
        "addition",
        seed,
        n,
        edge_pct,
        k,
        "only "
          <> int.to_string(list.length(pairs))
          <> " non-adjacent pairs available, need "
          <> int.to_string(k),
      )
  }
  let #(picked, seed2) = pick_k(pairs, k, seed)
  let #(new_edges, _) =
    list.fold(picked, #([], seed2), fn(acc, pair) {
      let #(built, seed) = acc
      let #(u, v) = pair
      let #(w, seed) = generator.rand_below(seed, 100)
      #([graph.Edge(u, v, w + 1), ..built], seed)
    })

  let before = runner.sent(sim0)
  let sim1 = list.fold(new_edges, sim0, fn(sim, e) { runner.add_link(sim, e) })
  let sim2 = case settle_bounded(sim1, settle_budget) {
    Ok(s) -> s
    Error(_) ->
      fail(
        "addition",
        seed,
        n,
        edge_pct,
        k,
        "did not settle within step budget (possible livelock)",
      )
  }
  let after = runner.sent(sim2)
  case oracle_ok(sim2) {
    True -> Nil
    False ->
      fail(
        "addition",
        seed,
        n,
        edge_pct,
        k,
        "repair did not converge to correct MST",
      )
  }

  Cell(
    messages: after - before,
    edges: list.length(g.edges),
    components: graph.components(sim2.graph),
  )
}

/// Pick `k` distinct items out of `items`, order randomized by `seed`.
fn pick_k(items: List(a), k: Int, seed: Int) -> #(List(a), Int) {
  case k <= 0 {
    True -> #([], seed)
    False -> {
      let n = list.length(items)
      case n {
        0 -> #([], seed)
        _ -> {
          let #(idx, seed) = generator.rand_below(seed, n)
          let assert Ok(picked) = items |> list.drop(idx) |> list.first
          let rest =
            items
            |> list.index_map(fn(x, i) { #(x, i) })
            |> list.filter(fn(p) { p.1 != idx })
            |> list.map(fn(p) { p.0 })
          let #(more, seed) = pick_k(rest, k - 1, seed)
          #([picked, ..more], seed)
        }
      }
    }
  }
}

pub fn debug_addition_cell(
  seed: Int,
  n: Int,
  edge_pct: Int,
  k: Int,
) -> #(Int, Int, Int) {
  let c = run_addition_cell(seed, n, edge_pct, k)
  #(c.messages, c.edges, c.components)
}

pub fn debug_failure_cell(
  seed: Int,
  n: Int,
  edge_pct: Int,
  k: Int,
  strategy: node.MoeStrategy,
) -> #(Int, Int, Int) {
  let c = run_failure_cell(seed, n, edge_pct, k, strategy)
  #(c.messages, c.edges, c.components)
}

fn non_adjacent_pairs(g: Graph) -> List(#(Int, Int)) {
  let existing =
    list.fold(g.edges, set.new(), fn(s, e) {
      set.insert(s, graph.edge_id(e.u, e.v))
    })
  list.flat_map(g.nodes, fn(i) {
    list.filter_map(g.nodes, fn(j) {
      case i < j && !set.contains(existing, graph.edge_id(i, j)) {
        True -> Ok(#(i, j))
        False -> Error(Nil)
      }
    })
  })
}

// --- averaging and rendering ----------------------------------------------

type CellStats {
  CellStats(mean_messages: Float, mean_edges: Float, mean_components: Float)
}

fn average_cell(
  n: Int,
  edge_pct: Int,
  k: Int,
  run: fn(Int, Int, Int, Int) -> Cell,
) -> CellStats {
  let results = list.map(seeds(), fn(seed) { run(seed, n, edge_pct, k) })
  let count = list.length(results)
  let sum_m = list.fold(results, 0, fn(a, c) { a + c.messages })
  let sum_e = list.fold(results, 0, fn(a, c) { a + c.edges })
  let sum_c = list.fold(results, 0, fn(a, c) { a + c.components })
  CellStats(
    mean_messages: int.to_float(sum_m) /. int.to_float(count),
    mean_edges: int.to_float(sum_e) /. int.to_float(count),
    mean_components: int.to_float(sum_c) /. int.to_float(count),
  )
}

fn log2(x: Int) -> Float {
  case x < 2 {
    True -> 1.0
    False -> {
      let assert Ok(l) = float.logarithm(int.to_float(x))
      let assert Ok(l2) = float.logarithm(2.0)
      l /. l2
    }
  }
}

fn f1(x: Float) -> String {
  let scaled = float.round(x *. 10.0)
  let whole = scaled / 10
  let frac = case scaled % 10 < 0 {
    True -> -{ scaled % 10 }
    False -> scaled % 10
  }
  int.to_string(whole) <> "." <> int.to_string(frac)
}

fn cell_text(s: CellStats, ratio: Float) -> String {
  f1(s.mean_messages) <> " (" <> f1(ratio) <> "x)"
}

fn print_header(cols: List(Int)) -> Nil {
  let header =
    string.pad_end("N", 8, " ")
    <> string.join(
      list.map(cols, fn(k) {
        string.pad_start("k=" <> int.to_string(k), 20, " ")
      }),
      "",
    )
  io.println(header)
  io.println(string.repeat("-", string.length(header)))
}

/// `bound` turns a cell's stats into the value the "(...x)" ratio is
/// relative to a theoretical message bound: `mean_edges` for the naive
/// O(|E|) claim, `n * log2(n)` for the binary-search O(N log N) claim.
fn failure_table(
  title: String,
  strategy: node.MoeStrategy,
  edge_pct: Int,
) -> Nil {
  io.println("")
  io.println(title)
  print_header(concurrencies)
  list.each(sizes, fn(n) {
    let row =
      list.map(concurrencies, fn(k) {
        case k > n - 1 {
          True -> string.pad_start("n/a", 20, " ")
          False -> {
            let s =
              average_cell(n, edge_pct, k, fn(seed, n, edge_pct, k) {
                run_failure_cell(seed, n, edge_pct, k, strategy)
              })
            let bound = case strategy {
              node.Naive -> s.mean_edges
              node.BinarySearch(_) -> int.to_float(n) *. log2(n)
            }
            let ratio = case bound >. 0.0 {
              True -> s.mean_messages /. bound
              False -> 0.0
            }
            string.pad_start(cell_text(s, ratio), 20, " ")
          }
        }
      })
      |> string.join("")
    io.println(string.pad_end("N=" <> int.to_string(n), 8, " ") <> row)
  })
}

fn addition_table(title: String, edge_pct: Int) -> Nil {
  io.println("")
  io.println(title)
  print_header(concurrencies)
  list.each(sizes, fn(n) {
    let row =
      list.map(concurrencies, fn(k) {
        let s = average_cell(n, edge_pct, k, run_addition_cell)
        let bound = int.to_float(n)
        let ratio = s.mean_messages /. bound
        string.pad_start(cell_text(s, ratio), 20, " ")
      })
      |> string.join("")
    io.println(string.pad_end("N=" <> int.to_string(n), 8, " ") <> row)
  })
}
