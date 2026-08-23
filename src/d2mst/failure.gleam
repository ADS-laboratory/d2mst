import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId}
import d2mst/message.{
  type D2MMsg, Connect, D2MMsg, SignalConnect, fail_is_intra_fragment,
}
import d2mst/node.{
  type EdgeInfo, type Effect, type State, BinarySearch, D2MNodeState, EdgeInfo,
  MOESearch, Merge, Naive, Reiden, Rejected, Selected, Send, Sleeping, State,
  Undecided, branch_edges_except, bump_failure_count, clear_addition_state,
  defer, failure_count, min_undecided_edge, opt_less, sample_k, set_confirmed,
  set_status,
}
import gleam/crypto
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// Dispatches a D2M message to the appropriate handler
pub fn handle_failure_message(
  state: State,
  on: EdgeId,
  msg: D2MMsg,
  message_fragment_id: FragmentId,
) -> #(State, List(Effect)) {
  case fail_is_intra_fragment(msg) && message_fragment_id != state.fragment {
    // A superseded round gets silently discarded
    True -> #(state, [])
    False ->
      case msg {
        // Phase 1: Failure detection and split
        message.ReportFailure(new_fragment:) ->
          on_report_failure(state, new_fragment)
        // Phase 2: Re-identification
        message.ReIden -> on_reiden(state, on, message_fragment_id)
        message.ReIdenAck -> on_reiden_ack(state, on)
        // Phase 3: Minimum outgoing edge search - Naive
        message.ProbeEdge -> on_probe_edge(state, on, message_fragment_id)
        message.ProbeMoe -> on_probe_moe(state, on)
        message.ProbeReply(is_outgoing:, probed:) ->
          on_probe_reply(state, on, is_outgoing, probed)
        message.ReportMoe(best:) -> on_report_moe(state, on, best)
        // Phase 3: Minimum outgoing edge search - Binary search
        message.BsRound -> on_bs_round(state, on)
        message.BsRoundReport(scan:) -> on_bs_round_report(state, on, scan)
        message.BsSplit(lo:, pivot:, hi:) ->
          on_bs_split(state, on, lo, pivot, hi)
        message.BsSplitReport(left:, right:) ->
          on_bs_split_report(state, on, left, right)
        message.BsMoeFound(target:) -> on_bs_moe_found(state, on, target)
        // Phase 4: Fragment merge
        message.SignalConnect -> on_signal_connect(state)
        message.Connect -> on_connect(state, on, message_fragment_id)
        message.GoSleep -> on_go_sleep(state, on)
      }
  }
}

// --------------------------------------------------------- //
//               Phase 1: Detection and split.               //
// --------------------------------------------------------- //

/// FAILURE ENTRYPOINT
/// 
/// A link died. Drop every reference this node still holds to the
/// edge and, only if it was a tree edge, re-identify the fragment and start
/// the failure response protocol.
pub fn remove_edge(state: State, on: EdgeId) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, on)
  let was_probing = state.test_edge == Some(on)

  // Remove edge from the current state
  let forget = fn(held: Option(EdgeId)) {
    case held == Some(on) {
      True -> None
      False -> held
    }
  }
  let #(best_edge, best_wt) = case state.best_edge == Some(on) {
    True -> #(None, None)
    False -> #(state.best_edge, state.best_wt)
  }
  let state =
    State(
      ..state,
      edges: dict.delete(state.edges, on),
      parent_edge: forget(state.parent_edge),
      test_edge: forget(state.test_edge),
      best_edge:,
      best_wt:,
      // Invalidate the BinarySearch candidate cache
      bs_candidates: None,
    )

  // Increment the failure count for this edge
  let #(state, k) = bump_failure_count(state, on)

  case info.status {
    // Tree edge: the fragment is split in two. Take the new identity
    // and propagate the failure up to the root.
    Selected ->
      on_report_failure(
        state,
        fragment.D2MCore(edge: on, node: Some(state.id), failures_counter: k),
      )

    // Non-tree edge: the fragment is untouched.
    // If this was the edge we were probing the reply will never come: move
    // on to the next candidate so the MOE search does not stall.
    _ ->
      case was_probing {
        True -> test_next_non_tree_edge(state)
        False -> #(state, [])
      }
  }
}

/// Forward failure upward until it hits the fragment root.
/// The root adopts the new identity and starts Phase 2 (ReIden) down the tree.
fn on_report_failure(
  state: State,
  reported: FragmentId,
) -> #(State, List(Effect)) {
  case state.parent_edge {
    // Reached the root of the fragment: start Phase 2.
    None -> start_reiden_phase(State(..state, fragment: reported))

    // Forward notification upward to parent.
    Some(parent_edge) -> #(state, [
      Send(
        parent_edge,
        D2MMsg(
          msg: message.ReportFailure(new_fragment: reported),
          fragment: state.fragment,
        ),
      ),
    ])
  }
}

// --------------------------------------------------------- //
//                Phase 2. RE-IDENtification.                //
// --------------------------------------------------------- //

/// Root or intermediate node initiates/propagates RE-IDEN down tree branches.
fn start_reiden_phase(state: State) -> #(State, List(Effect)) {
  let children = branch_children(state)
  // The fragment identity is about to change, so every addition message in
  // flight under the old one will be silently discarded wherever it lands
  // (see `message.add_is_intra_fragment`) -- any coordination state tied to
  // it is dead. Clear it now (`clear_addition_state`) rather than leaving
  // it stale.
  let state = clear_addition_state(state)
  let state =
    State(
      ..state,
      ns: D2MNodeState(Reiden),
      repair_countdown: list.length(children),
      // A repair is now in progress: `addition.on_edge_test` reads this to
      // tell a stable fragment from one mid-recovery.
      halted: False,
    )

  case children {
    // Leaf node or single-node root
    [] ->
      case state.parent_edge {
        // Root with no children: Phase 2 is immediately done; start Phase 3!
        None -> start_repair_search(state)

        // Leaf node: send Ack immediately up to parent.
        Some(parent_edge) -> #(state, [
          Send(
            parent_edge,
            D2MMsg(msg: message.ReIdenAck, fragment: state.fragment),
          ),
        ])
      }

    // Internal node: broadcast ReIden down to children.
    _ -> {
      let effects =
        list.map(children, fn(child_eid) {
          Send(child_eid, D2MMsg(msg: message.ReIden, fragment: state.fragment))
        })
      #(state, effects)
    }
  }
}

/// Node receives ReIden from parent: adopt the identity it carries
/// and continue the wave.
fn on_reiden(
  state: State,
  from: EdgeId,
  new_fragment: FragmentId,
) -> #(State, List(Effect)) {
  let state = State(..state, fragment: new_fragment, parent_edge: Some(from))
  start_reiden_phase(state)
}

/// Convergecast acknowledgment from a child.
fn on_reiden_ack(state: State, _from: EdgeId) -> #(State, List(Effect)) {
  let state = State(..state, repair_countdown: state.repair_countdown - 1)

  case state.repair_countdown == 0 {
    False -> #(state, [])
    True ->
      case state.parent_edge {
        // Root collected all ACKs: Phase 2 complete! Proceed to Phase 3.
        None -> start_repair_search(state)

        // Internal node collected all ACKs: reply ACK to parent.
        Some(parent_edge) -> #(state, [
          Send(
            parent_edge,
            D2MMsg(msg: message.ReIdenAck, fragment: state.fragment),
          ),
        ])
      }
  }
}

// --------------------------------------------------------- //
//           Phase 3. Minimum outgoing edge search           //
// --------------------------------------------------------- //

/// Root or node starts searching for the Minimum Outgoing Edge (MOE).
fn start_repair_search(state: State) -> #(State, List(Effect)) {
  // Reset the MOE search state (edges status)
  let edges =
    dict.map_values(state.edges, fn(_, info) {
      case info.status {
        Rejected -> EdgeInfo(..info, status: Undecided)
        _ -> info
      }
    })
  // A fresh search must not reuse a cache built for a previous one.
  let state =
    State(..state, edges:, ns: D2MNodeState(MOESearch), bs_candidates: None)
  case state.moe_strategy {
    Naive -> start_repair_search_naive(state)
    BinarySearch(..) -> start_bs_round(state)
  }
}

// ------------------------- naive ------------------------- //

/// Broadcast ProbeMoe down the tree and start probing local non-tree edges one
/// at a time.
fn start_repair_search_naive(state: State) -> #(State, List(Effect)) {
  let state = State(..state, best_wt: None, best_edge: None, test_edge: None)
  let children = branch_children(state)
  let state = State(..state, find_countdown: list.length(children))

  // Broadcast ProbeMoe down tree branches.
  let child_effects =
    list.map(children, fn(child_eid) {
      Send(child_eid, D2MMsg(msg: message.ProbeMoe, fragment: state.fragment))
    })

  // Start testing local non-tree edges.
  let #(state, test_effects) = test_next_non_tree_edge(state)
  #(state, list.append(child_effects, test_effects))
}

/// Handles ProbeMoe broadcast from parent.
fn on_probe_moe(state: State, from: EdgeId) -> #(State, List(Effect)) {
  let state = State(..state, parent_edge: Some(from))
  start_repair_search(state)
}

/// Tests the next undecided non-tree edge.
fn test_next_non_tree_edge(state: State) -> #(State, List(Effect)) {
  case min_undecided_edge(state) {
    Some(eid) -> {
      let state = State(..state, test_edge: Some(eid))
      #(state, [
        Send(eid, D2MMsg(msg: message.ProbeEdge, fragment: state.fragment)),
      ])
    }
    None -> {
      let state = State(..state, test_edge: None)
      check_and_report_moe(state)
    }
  }
}

/// Child reported its local candidate MOE up via convergecast.
fn on_report_moe(
  state: State,
  from: EdgeId,
  best: Option(Edge),
) -> #(State, List(Effect)) {
  let state = State(..state, find_countdown: state.find_countdown - 1)
  let state = case opt_less(best, state.best_wt) {
    True -> State(..state, best_wt: best, best_edge: Some(from))
    False -> state
  }
  check_and_report_moe(state)
}

/// When local testing and all child reports complete, report up or finish Phase 3.
fn check_and_report_moe(state: State) -> #(State, List(Effect)) {
  case state.find_countdown == 0 && state.test_edge == None {
    False -> #(state, [])
    True -> {
      case state.parent_edge {
        // Internal node: report subtree's best MOE up to parent
        Some(parent_edge) -> #(state, [
          Send(
            parent_edge,
            D2MMsg(
              msg: message.ReportMoe(best: state.best_wt),
              fragment: state.fragment,
            ),
          ),
        ])

        // Root: Phase 3 complete! Proceed to Phase 4 (Merge).
        None -> start_merge_phase(state)
      }
    }
  }
}

/// A neighbor is testing the edge between us. The identity carried by the 
/// probe is the sender's, so a mismatch means the edge leaves our fragment
/// (the same comparison GHS makes in `ghs.on_test`).
fn on_probe_edge(
  state: State,
  from: EdgeId,
  message_fragment: FragmentId,
) -> #(State, List(Effect)) {
  let is_outgoing = message_fragment != state.fragment
  #(state, [
    Send(
      from,
      D2MMsg(
        msg: message.ProbeReply(is_outgoing:, probed: message_fragment),
        fragment: state.fragment,
      ),
    ),
  ])
}

/// A neighbor replied to our probe. If the edge is outgoing, it is a 
/// candidate for the MOE. If it is not, we can mark it as Rejected and 
/// continue testing the next edge.
fn on_probe_reply(
  state: State,
  from: EdgeId,
  is_outgoing: Bool,
  probed: FragmentId,
) -> #(State, List(Effect)) {
  case probed == state.fragment {
    // The reply answers a probe we sent under a previous identity, ignore it.
    False -> #(state, [])

    True ->
      case is_outgoing {
        True -> {
          let assert Ok(info) = dict.get(state.edges, from)
          let candidate_edge = Some(info.edge)

          // Update best local weight if smaller
          let state = case opt_less(candidate_edge, state.best_wt) {
            True ->
              State(..state, best_wt: candidate_edge, best_edge: Some(from))
            False -> state
          }

          // Done testing local edges (since we test them from the smaller to
          // larger); proceed to check if convergecast can finish.
          let state = State(..state, test_edge: None)
          check_and_report_moe(state)
        }
        False -> {
          let state =
            set_status(state, from, Rejected)
            |> fn(s) { State(..s, test_edge: None) }

          // Continue testing remaining non-tree edges.
          test_next_non_tree_edge(state)
        }
      }
  }
}

// --------------------- binary search --------------------- //

/// Root or node starts the search's initial round: an unfiltered scan of
/// the whole fragment, to establish the first (lo, hi) and sample.
fn start_bs_round(state: State) -> #(State, List(Effect)) {
  let #(state, edges) = ensure_bs_candidates(state)
  let scan = bs_scan_all_sorted(edges, sample_k(state))
  let state = State(..state, ns: D2MNodeState(MOESearch), bs_scan: scan)
  let children = branch_children(state)
  let state = State(..state, find_countdown: list.length(children))
  let broadcast =
    list.map(children, fn(eid) {
      Send(eid, D2MMsg(msg: message.BsRound, fragment: state.fragment))
    })
  let #(state, more) = check_bs_round(state)
  #(state, list.append(broadcast, more))
}

/// Handles a BsRound broadcast from the parent.
fn on_bs_round(state: State, from: EdgeId) -> #(State, List(Effect)) {
  let state = State(..state, parent_edge: Some(from))
  start_bs_round(state)
}

/// Convergecast reply from a child: fold it into this node's accumulator
/// for the round in progress.
fn on_bs_round_report(
  state: State,
  _from: EdgeId,
  scan: message.BsScan,
) -> #(State, List(Effect)) {
  let state =
    State(
      ..state,
      find_countdown: state.find_countdown - 1,
      bs_scan: merge_scan(state.bs_scan, scan, sample_k(state)),
    )
  check_bs_round(state)
}

/// When all messages arrived from the children report to the parent or
/// continue the protocol if you are the root
fn check_bs_round(state: State) -> #(State, List(Effect)) {
  case state.find_countdown == 0 {
    // Wait for all children
    False -> #(state, [])
    // All children reported
    True ->
      case state.parent_edge {
        // Internal node: report the round's accumulator up to the parent
        Some(parent_edge) -> #(state, [
          Send(
            parent_edge,
            D2MMsg(
              msg: message.BsRoundReport(scan: state.bs_scan),
              fragment: state.fragment,
            ),
          ),
        ])
        // Root: all reports in
        None -> {
          let message.BsScan(xor:, bounds:, sample:) = state.bs_scan
          case xor == 0 {
            // No outgoing edge found, network is split
            True -> enter_sleep(state)
            False -> {
              let assert Some(#(lo, hi)) = bounds
              advance_bs(state, lo, hi, sample)
            }
          }
        }
      }
  }
}

/// The interval has narrowed to `[lo, hi]`.
/// Either it has already collapsed to one edge, or split it at a pivot and
/// test both halves.
fn advance_bs(
  state: State,
  lo: Edge,
  hi: Edge,
  sample: List(#(EdgeId, Edge)),
) -> #(State, List(Effect)) {
  case lo == hi {
    True -> start_bs_merge(state, graph.edge_id(lo.u, lo.v))
    False -> start_bs_split(state, lo, pick_pivot(sample, lo, hi), hi)
  }
}

/// Starts a round testing both halves of `[lo, hi]` split at `pivot`
fn start_bs_split(
  state: State,
  lo: Edge,
  pivot: Edge,
  hi: Edge,
) -> #(State, List(Effect)) {
  let #(state, edges) = ensure_bs_candidates(state)
  let k = sample_k(state)
  let left = bs_scan_range_sorted(edges, k, Incl(lo), pivot)
  let right = bs_scan_range_sorted(edges, k, Excl(pivot), hi)
  let state =
    State(..state, ns: D2MNodeState(MOESearch), bs_left: left, bs_right: right)
  let children = branch_children(state)
  let state = State(..state, find_countdown: list.length(children))
  let broadcast =
    list.map(children, fn(eid) {
      Send(
        eid,
        D2MMsg(msg: message.BsSplit(lo:, pivot:, hi:), fragment: state.fragment),
      )
    })
  let #(state, more) = check_bs_split(state)
  #(state, list.append(broadcast, more))
}

/// Handles a BsSplit broadcast from the parent.
fn on_bs_split(
  state: State,
  from: EdgeId,
  lo: Edge,
  pivot: Edge,
  hi: Edge,
) -> #(State, List(Effect)) {
  let state = State(..state, parent_edge: Some(from))
  start_bs_split(state, lo, pivot, hi)
}

/// Convergecast reply from a child: fold it into this node's accumulators
fn on_bs_split_report(
  state: State,
  _from: EdgeId,
  left: message.BsScan,
  right: message.BsScan,
) -> #(State, List(Effect)) {
  let k = sample_k(state)
  let state =
    State(
      ..state,
      find_countdown: state.find_countdown - 1,
      bs_left: merge_scan(state.bs_left, left, k),
      bs_right: merge_scan(state.bs_right, right, k),
    )
  check_bs_split(state)
}

/// Once local scanning and all child reports for this round are in, report
/// up to the parent, or (root) resolve the round.
fn check_bs_split(state: State) -> #(State, List(Effect)) {
  case state.find_countdown == 0 {
    False -> #(state, [])
    True ->
      case state.parent_edge {
        Some(parent_edge) -> #(state, [
          Send(
            parent_edge,
            D2MMsg(
              msg: message.BsSplitReport(
                left: state.bs_left,
                right: state.bs_right,
              ),
              fragment: state.fragment,
            ),
          ),
        ])
        None -> resolve_bs_split(state)
      }
  }
}

/// Root has received all the information from the fragment: keep whichever
/// half is non-empty.
fn resolve_bs_split(state: State) -> #(State, List(Effect)) {
  let message.BsScan(xor: xor_l, bounds: bounds_l, sample: sample_l) =
    state.bs_left
  case xor_l != 0 {
    True -> {
      let assert Some(#(lo, hi)) = bounds_l
      advance_bs(state, lo, hi, sample_l)
    }
    False -> {
      let message.BsScan(xor: xor_r, bounds: bounds_r, sample: sample_r) =
        state.bs_right
      case xor_r != 0 {
        True -> {
          let assert Some(#(lo, hi)) = bounds_r
          advance_bs(state, lo, hi, sample_r)
        }
        False -> enter_sleep(state)
      }
    }
  }
}

// ----------------- binary search helpers ----------------- //

type Bound {
  Incl(Edge)
  Excl(Edge)
}

/// Returns this node's incident edges, sorted by edge order and each
/// paired with its hash, from `state.bs_candidates` if a cache from an
/// earlier round in this same search is still valid, or freshly built (and
/// cached for the next round) otherwise.
fn ensure_bs_candidates(
  state: State,
) -> #(State, List(#(EdgeId, EdgeInfo, Int))) {
  case state.bs_candidates {
    Some(cached) -> #(state, cached)
    None -> {
      let sorted =
        dict.to_list(state.edges)
        |> list.map(fn(pair) { #(pair.0, pair.1, edge_hash(pair.0)) })
        |> list.sort(fn(a, b) { graph.compare_edge(a.1.edge, b.1.edge) })
      #(State(..state, bs_candidates: Some(sorted)), sorted)
    }
  }
}

/// A node's own contribution to one round: the XOR of a hash of `id(e)`
/// over every incident edge inside `in_range`, plus the (min, max) edge
/// and a sampled subset of the incident *non-tree* edges
fn bs_scan_result(
  kept: List(#(EdgeId, EdgeInfo, Int)),
  sample_k: Int,
) -> message.BsScan {
  let xor =
    list.fold(kept, 0, fn(acc, triple) {
      int.bitwise_exclusive_or(acc, triple.2)
    })

  // `via_addition` edges are excluded the same way `min_undecided_edge`
  // excludes them for the naive strategy: they are driven exclusively by
  // the addition protocol, and must not be claimed as an ordinary MOE
  // candidate by a concurrent, unrelated repair's scan.
  let candidates =
    list.filter(kept, fn(triple) {
      triple.1.status != Selected && !triple.1.via_addition
    })

  let bounds =
    list.fold(candidates, None, fn(acc, triple) {
      merge_bounds(acc, Some(#(triple.1.edge, triple.1.edge)))
    })

  let sample =
    candidates
    |> list.sort(fn(a, b) { int.compare(a.2, b.2) })
    |> list.take(sample_k)
    |> list.map(fn(triple) { #(triple.0, triple.1.edge) })

  message.BsScan(xor:, bounds:, sample:)
}

/// The initial, unfiltered round.
fn bs_scan_all_sorted(
  sorted_edges: List(#(EdgeId, EdgeInfo, Int)),
  sample_k: Int,
) -> message.BsScan {
  bs_scan_result(sorted_edges, sample_k)
}

/// A split round: slices `sorted_edges` (ascending by edge order) down to
/// `[lo, hi]`
fn bs_scan_range_sorted(
  sorted_edges: List(#(EdgeId, EdgeInfo, Int)),
  sample_k: Int,
  lo: Bound,
  hi: Edge,
) -> message.BsScan {
  let above_lo = fn(key: Edge) -> Bool {
    case lo {
      Incl(lo) -> !graph.edge_less(key, lo)
      Excl(lo) -> graph.edge_less(lo, key)
    }
  }
  let kept =
    sorted_edges
    |> list.drop_while(fn(triple) { !above_lo(triple.1.edge) })
    |> list.take_while(fn(triple) { !graph.edge_less(hi, triple.1.edge) })
  bs_scan_result(kept, sample_k)
}

/// Merge the information of a BsScan
fn merge_scan(
  a: message.BsScan,
  b: message.BsScan,
  sample_k: Int,
) -> message.BsScan {
  message.BsScan(
    xor: int.bitwise_exclusive_or(a.xor, b.xor),
    bounds: merge_bounds(a.bounds, b.bounds),
    sample: merge_samples(a.sample, b.sample, sample_k),
  )
}

fn merge_bounds(
  a: Option(#(Edge, Edge)),
  b: Option(#(Edge, Edge)),
) -> Option(#(Edge, Edge)) {
  case a, b {
    None, None -> None
    Some(_), None -> a
    None, Some(_) -> b
    Some(#(lo1, hi1)), Some(#(lo2, hi2)) ->
      Some(#(graph.edge_min(lo1, lo2), graph.edge_max(hi1, hi2)))
  }
}

/// Merges two samples: deduplicate shared edges and keep only the
/// `sample_k` smallest entries.
fn merge_samples(
  a: List(#(EdgeId, Edge)),
  b: List(#(EdgeId, Edge)),
  sample_k: Int,
) -> List(#(EdgeId, Edge)) {
  list.append(a, b)
  |> list.unique
  |> list.map(fn(p) { #(p, edge_hash(p.0)) })
  |> list.sort(fn(x, y) { int.compare(x.1, y.1) })
  |> list.take(sample_k)
  |> list.map(fn(x) { x.0 })
}

/// Compute the hash of an Edge
fn edge_hash(id: EdgeId) -> Int {
  let digest = crypto.hash(crypto.Sha256, <<id.low:64, id.high:64>>)
  let assert <<n:size(64), _:bits>> = digest
  n
}

/// Median of the sample restricted to entries strictly below `hi`
fn pick_pivot(sample: List(#(EdgeId, Edge)), lo: Edge, hi: Edge) -> Edge {
  let keys =
    list.map(sample, fn(p) { p.1 })
    |> list.filter(fn(k) { graph.edge_less(k, hi) })
    |> list.sort(graph.compare_edge)
  case list.drop(keys, list.length(keys) / 2) {
    [k, ..] -> graph.edge_max(lo, k)
    [] -> lo
  }
}

// --------------------------------------------------------- //
//                 Phase 4. Fragment merge.                  //
// --------------------------------------------------------- //

/// Naive: Root evaluates search results and initiates fragment reconnection.
fn start_merge_phase(state: State) -> #(State, List(Effect)) {
  case state.best_edge {
    // No outgoing edge found: network partition / isolated fragment. Put
    // every node into Sleep state.
    None -> enter_sleep(state)

    // MOE found: direct connection request towards boundary endpoint.
    Some(moe_branch) -> propagate_signal_connect(state, moe_branch)
  }
}

/// Naive: Intermediate node routes SignalConnect towards boundary node.
fn on_signal_connect(state: State) -> #(State, List(Effect)) {
  case state.best_edge {
    Some(moe_branch) -> propagate_signal_connect(state, moe_branch)
    None -> #(state, [])
  }
}

/// Naive: routes SignalConnect down a tree branch or executes Merge across the MOE.
fn propagate_signal_connect(
  state: State,
  target_edge: EdgeId,
) -> #(State, List(Effect)) {
  let state = State(..state, ns: D2MNodeState(Merge))
  let assert Ok(info) = dict.get(state.edges, target_edge)

  case info.status {
    // target_edge is a tree branch: forward SignalConnect down toward boundary node.
    Selected -> #(state, [
      Send(target_edge, D2MMsg(msg: SignalConnect, fragment: state.fragment)),
    ])

    // target_edge is non-tree: this node holds the MOE! Mark Selected and send Merge.
    _ -> {
      let state = set_status(state, target_edge, Selected)
      #(state, [
        Send(target_edge, D2MMsg(msg: Connect, fragment: state.fragment)),
      ])
    }
  }
}

/// BS: The search has converged on a single edge, Broadcasts the edge id down
/// the whole tree 
fn start_bs_merge(state: State, target: EdgeId) -> #(State, List(Effect)) {
  let state = State(..state, ns: D2MNodeState(Merge))
  let broadcast =
    branch_children(state)
    |> list.map(fn(eid) {
      Send(
        eid,
        D2MMsg(msg: message.BsMoeFound(target:), fragment: state.fragment),
      )
    })
  let #(state, more) = bs_claim_if_owner(state, target)
  #(state, list.append(broadcast, more))
}

/// BS: Handles the BsMoeFound broadcast from the parent.
fn on_bs_moe_found(
  state: State,
  from: EdgeId,
  target: EdgeId,
) -> #(State, List(Effect)) {
  let state = State(..state, parent_edge: Some(from))
  start_bs_merge(state, target)
}

/// BS: Check if the current node is the owner of the target edge, if it is
/// connect with the other fragment
fn bs_claim_if_owner(state: State, target: EdgeId) -> #(State, List(Effect)) {
  case dict.get(state.edges, target) {
    Error(_) -> #(state, [])
    Ok(_) -> {
      let state = set_status(state, target, Selected)
      #(state, [
        Send(target, D2MMsg(msg: Connect, fragment: state.fragment)),
      ])
    }
  }
}

/// A Connect arrived over an edge another fragment chose as its MOE.
fn on_connect(
  state: State,
  from: EdgeId,
  msg_fragment: FragmentId,
) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, from)
  // Both segments chose the same edge as their MOE
  let mutual = info.status == Selected

  case mutual {
    // Not (yet) mutual: wait until this side also chooses the edge, then merge.
    False -> #(
      defer(state, from, message.D2MMsg(msg: Connect, fragment: msg_fragment)),
      [],
    )

    // Both sides independently chose this edge: merge, tie-break by id. like
    // The smaller endpoint becomes the root and starts the ReIden wave; the 
    // larger endpoint records the MOE as its parent and waits for that wave 
    // like any other child.
    True -> {
      let new_fragment =
        fragment.D2MCore(
          edge: from,
          node: None,
          failures_counter: failure_count(state, from),
        )
      let state = set_status(state, from, Selected)
      // Both sides have now both sent *and* received a `Connect` for this
      // edge: mark it mutually confirmed (see `EdgeInfo.confirmed`). This
      // is what lets `addition.on_edge_test` tell "I've decided but am
      // still waiting to hear back" (status Selected, not yet confirmed --
      // keep nudging a peer that may have never gotten its own chance to
      // decide) apart from "fully done" (confirmed -- ignore stray retries).
      let state = set_confirmed(state, from)
      let state = State(..state, fragment: new_fragment)
      case state.id < info.peer {
        True -> start_reiden_phase(State(..state, parent_edge: None))
        // The smaller-id side clears addition bookkeeping as part of
        // `start_reiden_phase` above; this side's fragment just changed the
        // same way, so it needs the same clearing (`clear_addition_state`)
        // even though it won't call `start_reiden_phase` itself until the
        // ReIden wave reaches it a moment later -- otherwise there's a
        // window where a stale local entry and the new fragment id coexist.
        False -> #(
          clear_addition_state(State(..state, parent_edge: Some(from))),
          [],
        )
      }
    }
  }
}

/// Root broadcasts GoSleep down the tree: no outgoing edge exists anywhere
/// in the fragment, so there is nothing left to search for.
fn enter_sleep(state: State) -> #(State, List(Effect)) {
  let state = State(..state, ns: Sleeping, halted: True)
  let effects =
    branch_children(state)
    |> list.map(fn(eid) {
      Send(eid, D2MMsg(msg: message.GoSleep, fragment: state.fragment))
    })
  #(state, list.append(effects, retry_abandoned_additions(state)))
}

/// A GoSleep broadcast from the root: enter the terminal state, pass it on.
fn on_go_sleep(state: State, from: EdgeId) -> #(State, List(Effect)) {
  let state = State(..state, ns: Sleeping, halted: True)
  let effects =
    branch_edges_except(state, Some(from))
    |> list.map(fn(eid) {
      Send(eid, D2MMsg(msg: message.GoSleep, fragment: state.fragment))
    })
  #(state, list.append(effects, retry_abandoned_additions(state)))
}

/// A concurrent failure can interrupt an addition round mid-flight: its
/// fragment identity changes underneath it, so every in-flight
/// `AddRequestTurn`/`Privilege`/`Replace` message for it gets silently
/// discarded by the mismatch check the moment it crosses a node that has
/// already re-identified, and nothing else re-drives it (see
/// `EdgeInfo.via_addition`). Once this node is quiescent again, re-probe
/// every such edge fresh.
///
/// Checking `status != Selected` rather than `== Undecided`: the repair
/// this node just went through also runs its own Phase 3 MOE search, which
/// treats an abandoned addition's edge as an ordinary candidate like any
/// other and, if both endpoints ended up in the same fragment again, marks
/// it `Rejected` before we ever get a chance to retry it -- which would
/// otherwise permanently hide it from this check. This also re-probes
/// additions that legitimately resolved as a no-op (status left as
/// whatever it was, not `Selected`, by design). That used to be able to
/// resurrect a stale `pending_additions[eid]` entry left behind by the
/// no-op path; `addition.on_replace` now clears that bookkeeping
/// unconditionally (see `message.Replace`'s `should_prune` field), which
/// closes that specific case. A related gap is still open, though: a round
/// abandoned *before* ever reaching its LCA (discarded mid-climb by a
/// concurrent re-identification, rather than resolved as a no-op) leaves
/// `pending_additions` entries stranded at whatever relay nodes it had
/// already passed through, and nothing currently revisits those -- only the
/// edge's own two endpoints get re-probed here. Confirmed reproducible
/// (`failure_test.fuzz_long_running_random_topology_test`, seed 1) but not
/// yet root-caused: the re-probe from this function does resolve the
/// retried edge correctly and no false-LCA match has been observed, so the
/// resulting wrong tree traces to something else in that path, still
/// uncharacterized.
fn retry_abandoned_additions(state: State) -> List(Effect) {
  dict.to_list(state.edges)
  |> list.filter_map(fn(pair) {
    let #(eid, info) = pair
    case info.via_addition && info.status != Selected {
      True ->
        Ok(Send(eid, message.AddMsg(message.AddTest, fragment: state.fragment)))
      False -> Error(Nil)
    }
  })
}

// --------------------------------------------- //
//                    Helpers                    //
// --------------------------------------------- //

/// Returns tree edges connected to children (excludes parent_edge).
fn branch_children(state: State) -> List(EdgeId) {
  dict.to_list(state.edges)
  |> list.filter_map(fn(pair) {
    let #(eid, info) = pair
    case info.status == Selected && Some(eid) != state.parent_edge {
      True -> Ok(eid)
      False -> Error(Nil)
    }
  })
}
