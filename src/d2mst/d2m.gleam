import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId}
import d2mst/message.{type D2MMsg, Connect, D2MMsg, SignalConnect}
import d2mst/node.{
  type Effect, type State, D2MNodeState, EdgeInfo, MOESearch, Reiden, Rejected,
  Selected, Send, Sleeping, State, Undecided, bump_failure_count, failure_count,
  min_undecided_edge, opt_less, set_status,
}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}

/// Phase 1: a link died. Drop every reference this node still holds to the
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
    )

  // Increment the failure count for this edge
  let #(state, k) = bump_failure_count(state, on)

  case info.status {
    // Tree edge: the fragment is split in two. Take the new identity
    // and propagate the failure up to the root.
    Selected -> {
      let fragment_id = fragment.D2MCore(on, Some(state.id), k)
      on_report_failure(State(..state, fragment: fragment_id))
    }

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

pub fn handle_d2m_message(
  state: State,
  on: EdgeId,
  msg: D2MMsg,
  message_fragment_id: FragmentId,
) -> #(State, List(Effect)) {
  case msg {
    message.ReportFailure ->
      on_report_failure(State(..state, fragment: message_fragment_id))
    message.ReIden -> on_reiden(state, on, message_fragment_id)
    message.ReIdenAck -> on_reiden_ack(state, on)
    message.ProbeEdge -> on_probe_edge(state, on, message_fragment_id)
    message.ProbeMoe -> on_probe_moe(state, on)
    message.ProbeReply(is_outgoing:) -> on_probe_reply(state, on, is_outgoing)
    message.ReportMoe(best:) -> on_report_moe(state, on, best)
    message.SignalConnect -> on_signal_connect(state)
    message.Connect -> on_connect(state, on)
  }
}

/// Phase 1: Forward failure upward until it hits the fragment root.
fn on_report_failure(state: State) -> #(State, List(Effect)) {
  case state.parent_edge {
    // Reached the root of the fragment: start Phase 2.
    None -> start_reiden_phase(state)

    // Forward notification upward to parent.
    Some(parent_edge) -> #(state, [
      Send(
        parent_edge,
        D2MMsg(msg: message.ReportFailure, fragment: state.fragment),
      ),
    ])
  }
}

/// Phase 2: Root or intermediate node initiates/propagates RE-IDEN down tree branches.
fn start_reiden_phase(state: State) -> #(State, List(Effect)) {
  let children = branch_children(state)
  let state =
    State(
      ..state,
      ns: D2MNodeState(Reiden),
      repair_countdown: list.length(children),
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

/// Phase 2: Node receives ReIden from parent.
fn on_reiden(
  state: State,
  from: EdgeId,
  new_fragment: FragmentId,
) -> #(State, List(Effect)) {
  let state = State(..state, fragment: new_fragment, parent_edge: Some(from))
  start_reiden_phase(state)
}

/// Phase 2: Convergecast acknowledgment from a child.
fn on_reiden_ack(state: State, _from: EdgeId) -> #(State, List(Effect)) {
  // TODO: should we check for the correct fragment id here? (and for other messages)
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

/// Helper: returns tree edges connected to children (excludes parent_edge).
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

/// Phase 3: Root or node starts probing for the Minimum Outgoing Edge (MOE).
fn start_repair_search(state: State) -> #(State, List(Effect)) {
  // Reset the MOE search state (edges status)
  let edges =
    dict.map_values(state.edges, fn(_, info) {
      case info.status {
        Rejected -> EdgeInfo(..info, status: Undecided)
        _ -> info
      }
    })
  let state =
    State(
      ..state,
      edges:,
      ns: D2MNodeState(MOESearch),
      best_wt: None,
      best_edge: None,
      test_edge: None,
    )
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

/// Phase 3: Handles ProbeMoe broadcast from parent.
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

/// Phase 3: Child reported its local candidate MOE up via convergecast.
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

fn on_probe_edge(
  state: State,
  from: EdgeId,
  msg_fragment: FragmentId,
) -> #(State, List(Effect)) {
  case msg_fragment == state.fragment {
    // Same fragment: edge is internal.
    True -> #(state, [
      Send(
        from,
        D2MMsg(
          msg: message.ProbeReply(is_outgoing: False),
          fragment: state.fragment,
        ),
      ),
    ])
    // Different fragment: edge is outgoing.
    False -> #(state, [
      Send(
        from,
        D2MMsg(
          msg: message.ProbeReply(is_outgoing: True),
          fragment: state.fragment,
        ),
      ),
    ])
  }
}

fn on_probe_reply(
  state: State,
  from: EdgeId,
  is_outgoing: Bool,
) -> #(State, List(Effect)) {
  case is_outgoing {
    True -> {
      let assert Ok(info) = dict.get(state.edges, from)
      let candidate_edge = Some(info.edge)

      // Update best local weight if smaller
      let state = case opt_less(candidate_edge, state.best_wt) {
        True -> State(..state, best_wt: candidate_edge, best_edge: Some(from))
        False -> state
      }

      // Done testing local edges (since we test them from the smaller to larger); proceed to
      // check if convergecast can finish.
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

/// Phase 4: Root evaluates search results and initiates fragment reconnection.
fn start_merge_phase(state: State) -> #(State, List(Effect)) {
  case state.best_edge {
    // No outgoing edge found: network partition / isolated fragment.
    None -> #(State(..state, ns: Sleeping), [])

    // MOE found: direct connection request towards boundary endpoint.
    Some(moe_branch) -> propagate_signal_connect(state, moe_branch)
  }
}

/// Phase 4: Intermediate node routes SignalConnect towards boundary node.
fn on_signal_connect(state: State) -> #(State, List(Effect)) {
  case state.best_edge {
    Some(moe_branch) -> propagate_signal_connect(state, moe_branch)
    None -> #(state, [])
  }
}

/// Helper: routes SignalConnect down a tree branch or executes Merge across the MOE.
fn propagate_signal_connect(
  state: State,
  target_edge: EdgeId,
) -> #(State, List(Effect)) {
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

fn on_connect(state: State, from: EdgeId) -> #(State, List(Effect)) {
  // Mark the MOE as a tree edge.
  let state = set_status(state, from, Selected)

  // New FragmentId with MOE as the new core.
  let assert Ok(info) = dict.get(state.edges, from)
  let new_fragment =
    fragment.D2MCore(
      edge: from,
      node: None,
      failures_counter: failure_count(state, from),
    )
  let state = State(..state, fragment: new_fragment, parent_edge: None)

  // Deterministically elect a single root.
  let is_new_root = state.id == from.high

  case is_new_root {
    // Designated Root: parent_edge stays None
    True ->
      State(..state, fragment: new_fragment, parent_edge: None)
      |> start_reiden_phase
    // Non-Root Endpoint: point parent_edge across the MOE to the new root
    False -> #(State(..state, parent_edge: Some(from)), [])
  }
}
