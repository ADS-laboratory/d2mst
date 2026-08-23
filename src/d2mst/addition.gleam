//// Addition response protocol (Tier 3).

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId, type NodeId}
import d2mst/message.{type AddMsg, add_is_intra_fragment}
import d2mst/node.{
  type EdgeInfo, type Effect, type ReplaceDecision, type State, EdgeInfo,
  ReplaceDecision, Selected, Send, Sleeping, State, Undecided,
}
import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}

/// Dispatches a Add message to the appropriate handler.
pub fn handle_add_message(
  state: State,
  on: EdgeId,
  msg: AddMsg,
  message_fragment_id: FragmentId,
) -> #(State, List(Effect)) {
  case add_is_intra_fragment(msg) && message_fragment_id != state.fragment {
    True -> #(state, [])
    False ->
      case msg {
        message.AddTest -> on_edge_test(state, on, message_fragment_id)
        message.AddRequestMergePartition(add_edge) ->
          on_request_merge(state, on, add_edge)
        message.AddApproveMergePartition(add_edge) ->
          on_approve_merge(state, on, add_edge)
        message.Addition(event_id, new_weight, origin, running_max, max_edge) ->
          on_addition(
            state,
            on,
            event_id,
            new_weight,
            origin,
            running_max,
            max_edge,
          )
        message.Replace(
          event_id:,
          target_origin:,
          max_weight:,
          max_edge:,
          reversing:,
          should_prune:,
        ) ->
          on_replace(
            state,
            on,
            event_id,
            target_origin,
            max_weight,
            max_edge,
            reversing,
            should_prune,
          )
        message.AddRequestTurn(event_id:) ->
          on_request_turn(state, on, event_id)
        message.Privilege(event_id:) -> on_privilege(state, on, event_id)
        message.AddDone(event_id:) -> on_add_done(state, on, event_id)
      }
  }
}

// --------------------------------------------------------- //
//            Endpoints' Fragments Discrimination            //
// --------------------------------------------------------- //

/// Register a newly added edge and trigger the addition response protocol (i.e. ask to 
/// the neighbor if it is in the same fragment or not and wait for a response).
pub fn add_edge(state: State, edge: Edge) -> #(State, List(Effect)) {
  let peer = graph.other_node(edge, state.id)
  let eid = graph.edge_id(edge.u, edge.v)
  let state =
    State(
      ..state,
      edges: dict.insert(
        state.edges,
        eid,
        EdgeInfo(
          peer:,
          edge:,
          status: Undecided,
          via_addition: True,
          confirmed: False,
        ),
      ),
    )

  let effect =
    Send(eid, message.AddMsg(message.AddTest, fragment: state.fragment))
  #(state, [effect])
}

fn on_edge_test(
  state: State,
  eid: EdgeId,
  reported: FragmentId,
) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, eid)

  case info.confirmed {
    // Already confirmed: ignore.
    True -> #(state, [])
    False ->
      case info.status == Selected {
        // Decided on this side, but not yet mutually confirmed: just forward the test to
        // the other side.
        True -> #(state, [
          node.Send(
            eid,
            message.AddMsg(message.AddTest, fragment: state.fragment),
          ),
        ])
        False ->
          case state.fragment == reported {
            True -> {
              // SAME FRAGMENT: the new edge forms a cycle. The max weight edge on the
              // cycle must be removed.
              on_addition(state, eid, eid, info.edge.weight, state.id, 0, eid)
            }
            False -> {
              // DIFFERENT FRAGMENTS
              case state.ns == Sleeping || state.halted {
                True -> {
                  // Case 1: no operation in progress, the network is partitioned.
                  case state.parent_edge {
                    // The root can authorize the merge directly, possibly queueing it.
                    None ->
                      preempt_or_keep(state, eid, fn(s) {
                        approve_merge(s, eid)
                      })
                    // Otherwise, request authorization from the root.
                    Some(parent_edge) -> {
                      // Send a request to the root to merge using this new
                      // link.
                      let request_msg = message.AddRequestMergePartition(eid)
                      let envelope =
                        message.AddMsg(request_msg, fragment: state.fragment)
                      #(state, [node.Send(parent_edge, envelope)])
                    }
                  }
                }
                False -> {
                  // Case 2: A failure response is in progress. Drop this `AddTest`
                  // instead of deferring it.
                  // 
                  // 1. Deferring saves a stale snapshot of the sender's `reported`
                  //    fragment ID.
                  // 2. Because topologies and fragment IDs shift during active repairs,
                  //    evaluating this stale ID later can cause a false "different
                  //    fragment" detection.
                  // 3. This false detection can trick the algorithm into authorizing a
                  //    cross-fragment merge between nodes that have already converged
                  //    elsewhere, creating illegal cycles and infinite routing loops.
                  //
                  // By dropping the message entirely, we guarantee safety. Once this node 
                  // finishes its repair and enters the `Sleeping` state,
                  // `retry_abandoned_additions` will automatically send a new `AddTest`.
                  // This ensures the fragment comparison always happens using up-to-date
                  // state on both sides.
                  #(state, [])
                }
              }
            }
          }
      }
  }
}

// --------------------------------------------------------- //
//                        LCA Search                         //
// --------------------------------------------------------- //
// Endpoints are in the same fragment, so the new edge forms a cycle. We search for the
// LCA by propagating the `Addition` message up the tree from both endpoints, carrying the
// running maximum weight along the path. The first node to receive both messages is the
// LCA, which decides which edge to remove (the heaviest).

pub fn on_addition(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
  new_weight: Int,
  origin: NodeId,
  running_max: Int,
  max_edge: EdgeId,
) -> #(State, List(Effect)) {
  let assert Ok(in_info) = dict.get(state.edges, from_edge)

  // Update running maximum weight along this branch.
  let #(updated_max, updated_max_edge) = case
    graph.edge_less(
      graph.Edge(max_edge.low, max_edge.high, running_max),
      graph.Edge(from_edge.low, from_edge.high, in_info.edge.weight),
    )
  {
    True -> #(in_info.edge.weight, from_edge)
    False -> #(running_max, max_edge)
  }

  let updated_msg =
    message.Addition(
      event_id:,
      new_weight:,
      origin:,
      running_max: updated_max,
      max_edge: updated_max_edge,
    )

  // Check if we already received an Addition for this event.
  case dict.get(state.pending_additions, event_id) {
    Ok(#(first_msg, first_msg_from_edge, stored_fragment))
      if stored_fragment == state.fragment
    -> {
      let assert message.Addition(..) = first_msg
      // We are the LCA. Now we update the topology. `winner` is the branch that reported
      // the larger running max (the one that holds the cycle's heaviest edge); `other_*`
      // is the losing branch's own origin/routing edge, needed below to attach *its* side
      // of the new edge too. TODO: other_ is needed for what?
      let winner_is_first =
        graph.edge_less(
          graph.Edge(updated_max_edge.low, updated_max_edge.high, updated_max),
          graph.Edge(
            first_msg.max_edge.low,
            first_msg.max_edge.high,
            first_msg.running_max,
          ),
        )
      let max_weight = case winner_is_first {
        True -> first_msg.running_max
        False -> updated_max
      }
      let max_edge = case winner_is_first {
        True -> first_msg.max_edge
        False -> updated_max_edge
      }
      let #(target_origin, other_origin) = case winner_is_first {
        True -> #(first_msg.origin, origin)
        False -> #(origin, first_msg.origin)
      }
      let #(next_edge, other_next_edge) = case winner_is_first {
        True -> #(first_msg_from_edge, from_edge)
        False -> #(from_edge, first_msg_from_edge)
      }

      let already_at_max_edge = next_edge == max_edge
      let state =
        State(
          ..state,
          pending_additions: dict.delete(state.pending_additions, event_id),
        )

      let decision =
        ReplaceDecision(
          should_prune: graph.edge_less(
            graph.Edge(event_id.low, event_id.high, new_weight),
            graph.Edge(max_edge.low, max_edge.high, max_weight),
          ),
          target_origin:,
          next_edge:,
          other_origin:,
          other_next_edge:,
          max_weight:,
          max_edge:,
          already_at_max_edge:,
        )
      let state =
        State(
          ..state,
          ready_replace: dict.insert(state.ready_replace, event_id, decision),
        )

      // We have a decision, but must not act on it yet: another concurrently-converging
      // LCA elsewhere in the fragment might have its own decision pending too, and if the
      // cycles overlap, running both at once could remove/reverse the same edge twice.
      // Ask the root for a turn.
      relay_or_root(state, event_id)
    }
    _ -> {
      // First Addition to arrive at this node: save it and forward upward.
      let state =
        State(
          ..state,
          pending_additions: dict.insert(state.pending_additions, event_id, #(
            updated_msg,
            from_edge,
            state.fragment,
          )),
        )

      case state.parent_edge {
        Some(parent_edge) -> {
          let envelope = message.AddMsg(updated_msg, fragment: state.fragment)
          #(state, [node.Send(parent_edge, envelope)])
        }
        None -> {
          // We are the root, still waiting for a sibling branch.
          #(state, [])
        }
      }
    }
  }
}

// --------------------------------------------------------- //
//                  Addition Serialization                   //
// --------------------------------------------------------- //

/// Send our request for a turn to our parent, or enqueue it ourselves if we are the root.
fn relay_or_root(state: State, event_id: EdgeId) -> #(State, List(Effect)) {
  case state.parent_edge {
    Some(parent_edge) -> {
      let msg = message.AddRequestTurn(event_id:)
      #(state, [
        node.Send(parent_edge, message.AddMsg(msg, fragment: state.fragment)),
      ])
    }
    None -> root_enqueue(state, event_id)
  }
}

/// Root only: queue an event and try to start it (or whatever is next in line).
fn root_enqueue(state: State, event_id: EdgeId) -> #(State, List(Effect)) {
  let state =
    State(
      ..state,
      addition_queue: list.append(state.addition_queue, [event_id]),
    )
  root_try_start(state)
}

// TODO: finish to move stuff here and shorten comments

/// Root only: if free, pop the head of the same-fragment LCA queue and grant it a turn;
/// if that's empty, fall back to a queued cross-fragment
/// merge request instead (see `preempt_or_keep`'s `pending_merges` doc).
fn root_try_start(state: State) -> #(State, List(Effect)) {
  case state.addition_active {
    Some(_) -> #(state, [])
    None ->
      case state.addition_queue {
        [event_id, ..rest] -> {
          let state =
            State(
              ..state,
              addition_queue: rest,
              addition_active: Some(event_id),
            )
          execute_or_route(state, event_id)
        }
        [] ->
          case state.pending_merges {
            [] -> #(state, [])
            [add_edge, ..rest] -> {
              let state = State(..state, pending_merges: rest)
              approve_merge(state, add_edge)
            }
          }
      }
  }
}

// --------------------------------------------------------- //
//                      Update Topology                      //
// --------------------------------------------------------- //
// A Replace message is sent down the cycle to remove the heaviest edge.

fn on_replace(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
  target_origin: NodeId,
  max_weight: Int,
  max_edge: EdgeId,
  reversing: Bool,
  should_prune: Bool,
) -> #(State, List(Effect)) {
  // Are we reversing? If we just crossed the max_edge, or were already reversing. Only
  // meaningful when should_prune: a no-op wave (i.e. when the new edge has the maximum
  // weight) never reverses anything.
  let now_reversing = should_prune && { reversing || from_edge == max_edge }

  // Find the next hop towards the origin. Always computed to clear the
  // `pending_additions` entry even if should_prune is false.
  let next_hop = case state.id == target_origin {
    True -> option.None
    False -> {
      case dict.get(state.pending_additions, event_id) {
        Ok(#(_msg, child_edge, _fragment)) -> option.Some(child_edge)
        Error(_) ->
          panic as "Unreachable: Replace wave arrived but pending_additions was wiped!"
      }
    }
  }

  // Reverse the parent pointer if we are on the disconnected side.
  let state = case now_reversing {
    True -> {
      // The new parent is the neighbor we are forwarding the message to.
      let new_parent = case state.id == target_origin {
        // If we are at the origin, the new parent is the newly added edge itself.
        True -> event_id
        False -> option.unwrap(next_hop, event_id)
      }
      State(..state, parent_edge: option.Some(new_parent))
    }
    False -> state
  }

  // Forward the message down the cycle.
  let effects = case next_hop {
    Some(child_edge) -> {
      let msg =
        message.Replace(
          event_id:,
          target_origin:,
          max_weight:,
          max_edge:,
          reversing: now_reversing,
          should_prune:,
        )
      let envelope = message.AddMsg(msg, fragment: state.fragment)
      [node.Send(child_edge, envelope)]
    }
    None -> []
  }

  // If the max_edge is connected to us, drop it.
  let state = case should_prune, dict.get(state.edges, max_edge) {
    True, Ok(info) -> {
      let updated_info =
        EdgeInfo(..info, status: Undecided, via_addition: False)
      State(..state, edges: dict.insert(state.edges, max_edge, updated_info))
    }
    _, _ -> state
  }

  // Clear the pending_additions entry for this event_id.
  let state =
    State(
      ..state,
      pending_additions: dict.delete(state.pending_additions, event_id),
    )

  // If we are the target_origin, promote the new edge to the tree and report completion
  // to the root.
  let #(state, done_effects) = case state.id == target_origin {
    True -> {
      let state = case dict.get(state.edges, event_id) {
        Ok(info) -> {
          let updated_info = case should_prune {
            True -> {
              // Confirm the new edge as a mst edge.
              EdgeInfo(
                ..info,
                status: Selected,
                confirmed: True,
                via_addition: False,
              )
            }
            // No-op: only clear via_addition.
            False -> EdgeInfo(..info, via_addition: False)
          }
          State(
            ..state,
            edges: dict.insert(state.edges, event_id, updated_info),
          )
        }
        Error(_) -> state
      }
      forward_or_finish(state, event_id)
    }
    False -> #(state, [])
  }

  #(state, list.append(effects, done_effects))
}

/// Report this event done to the root and handle it.
fn forward_or_finish(state: State, event_id: EdgeId) -> #(State, List(Effect)) {
  case state.parent_edge {
    Some(parent_edge) -> {
      let msg = message.AddDone(event_id:)
      #(state, [
        node.Send(parent_edge, message.AddMsg(msg, fragment: state.fragment)),
      ])
    }
    None -> handle_root_add_done(state, event_id)
  }
}

/// Root only, on receiving the aggregate `AddDone` for the event it currently has active:
/// free up the slot and try the next one.
fn handle_root_add_done(
  state: State,
  event_id: EdgeId,
) -> #(State, List(Effect)) {
  let state = case state.addition_active == Some(event_id) {
    True -> State(..state, addition_active: None)
    False -> state
  }
  root_try_start(state)
}

// --------------------------------------------------------- //
//                    Different Fragments                    //
// --------------------------------------------------------- //

fn on_request_merge(
  state: State,
  _on: EdgeId,
  add_edge: EdgeId,
) -> #(State, List(Effect)) {
  let is_root = state.parent_edge == option.None
  case is_root {
    True -> {
      case state.ns == Sleeping || state.halted {
        True ->
          preempt_or_keep(state, add_edge, fn(s) { approve_merge(s, add_edge) })
        False -> {
          // A failure repair is in progress here, not just another addition: drop
          // request. When the current operation settles, retry_abandoned_additions will
          // re-probe all undecided via_addition edges.
          #(state, [])
        }
      }
    }
    False -> {
      // Not the root. Forward the request upward via the parent link.
      let assert option.Some(parent_edge) = state.parent_edge
      let msg = message.AddRequestMergePartition(add_edge)
      let envelope = message.AddMsg(msg, fragment: state.fragment)
      #(state, [node.Send(parent_edge, envelope)])
    }
  }
}

fn on_approve_merge(
  state: State,
  on: EdgeId,
  add_edge: EdgeId,
) -> #(State, List(Effect)) {
  // Forward the approval down the tree.
  let msg = message.AddApproveMergePartition(add_edge)
  let envelope = message.AddMsg(msg, fragment: state.fragment)
  let effects = broadcast_to_tree(state, option.Some(on), envelope)

  case dict.get(state.edges, add_edge) {
    Ok(info) -> {
      // Merge if we are the endpoint that requested the merge.
      merge(state, add_edge, info, effects)
    }
    Error(_) -> {
      // We do not own the target edge: forward the approval.
      #(state, effects)
    }
  }
}

/// Root-only: commit this root to `add_edge` (set `addition_active`) and
/// either merge immediately, if this root itself owns the edge (the Case-1
/// direct path in `on_edge_test`), or broadcast the approval down the tree
/// for whichever descendant does (the `AddRequestMergePartition` path).
/// Unifying both into one function is what lets `root_try_start` retry a
/// queued `pending_merges` entry without caring which of the two situations
/// originally queued it.
///
/// When this root owns `add_edge` itself, it must not claim the slot for an
/// edge that is no longer eligible (`via_addition` already cleared, or
/// already `Selected` from some other path -- both possible if this call
/// came from `pending_merges` and time passed between queuing and this
/// retry, e.g. the two fragments meanwhile merged some other way and
/// `retry_abandoned_additions` already resolved this exact edge as an
/// ordinary same-fragment cycle). `merge` itself would just silently no-op
/// on a `Selected` edge without ever sending `Connect` -- and with
/// `addition_active` already set, nothing would ever produce the `AddDone`
/// needed to free it again, wedging this root forever. Skip straight to the
/// next candidate instead. A remotely-owned edge can't be checked this way
/// (this root has no visibility into the owner's status); `merge`'s own
/// idempotency guard still protects that side from acting twice, at the
/// cost of the same root-wedge risk in that narrower, harder-to-hit case.
fn approve_merge(state: State, add_edge: EdgeId) -> #(State, List(Effect)) {
  case dict.get(state.edges, add_edge) {
    Ok(info) if info.status == Undecided && info.via_addition -> {
      let state = State(..state, addition_active: option.Some(add_edge))
      merge(state, add_edge, info, [])
    }
    Ok(_) -> root_try_start(state)
    Error(_) -> {
      let state = State(..state, addition_active: option.Some(add_edge))
      let msg = message.AddApproveMergePartition(add_edge)
      let envelope = message.AddMsg(msg, fragment: state.fragment)
      #(state, broadcast_to_tree(state, option.None, envelope))
    }
  }
}

/// Root-only: either:
/// - run `execute` if the root is currently free, or if `candidate` outranks whatever is
///   already active; otherwise,
/// - queue `candidate` in `pending_merges` for its turn once the active one settles.
///
/// Two different new edges concurrently reconnecting the very same pair of
/// fragments get decided by each fragment's *own* root independently --
/// there is no message exchange between the two roots to agree on one, so
/// both must break the tie the same way without talking to each other.
/// Ordering on the bare `EdgeId` (not weight: a request arriving via
/// `AddRequestMergePartition` only carries the id, not the edge, and the
/// root does not necessarily own it) is enough: both roots see the same
/// pair of ids and pick the same winner.
///
/// Abandoning an already-active `candidate` must also retract the local
/// commitment it made: `state.edges[current]` was set `Selected` (and a
/// `Connect` sent) the moment it became active, via the Case-1 direct path
/// in `on_edge_test` where the root is necessarily the edge's own owner --
/// left in place, that stale `Selected` and the new winner's own `Selected`
/// together form an actual cycle in the tree (two edges both marked as
/// spanning the same fragment pair), and a `ReIden` wave started over the
/// new winner loops through it forever instead of terminating. Retracting
/// is safe: a mutual `Connect` would already have reassigned this root's own
/// fragment (clearing `addition_active` via `node.clear_addition_state`
/// before we'd ever get here), so `Selected`-but-unconfirmed is local-only
/// state nothing else depends on yet.
///
/// Queuing (rather than dropping outright) matters even when `candidate`
/// loses the tie-break: the operation currently occupying `addition_active`
/// may be an ordinary same-fragment cycle resolution with no relation to
/// `candidate`'s target fragment at all, and it *will* finish and free the
/// slot via `handle_root_add_done` -- but nothing else would ever come back
/// and re-ask on `candidate`'s behalf (confirmed reproducible: seed 4, i=20
/// of `fuzz_long_running_random_topology_test` -- a same-fragment cycle
/// event occupies the root exactly while a new singleton node's merge
/// request arrives, the request is dropped, and since no failure repair is
/// involved the requester never re-enters `Sleeping` to trigger
/// `retry_abandoned_additions` either, stranding the singleton as a
/// permanent extra root).
fn preempt_or_keep(
  state: State,
  candidate: EdgeId,
  execute: fn(State) -> #(State, List(Effect)),
) -> #(State, List(Effect)) {
  case state.addition_active {
    option.None -> execute(state)
    option.Some(current) ->
      case graph.edge_id_less(candidate, current) {
        True -> execute(retract(state, current))
        False -> #(
          State(
            ..state,
            pending_merges: list.append(state.pending_merges, [candidate]),
          ),
          [],
        )
      }
  }
}

/// Reset an edge this node itself decided (`Selected`, not yet `confirmed`)
/// back to `Undecided`, so it is reconsidered fresh instead of being left as
/// a dangling stale commitment. A no-op if this node isn't the edge's owner
/// or the edge was never locally decided.
fn retract(state: State, eid: EdgeId) -> State {
  case dict.get(state.edges, eid) {
    Ok(info) if info.status == Selected && !info.confirmed -> {
      let updated = EdgeInfo(..info, status: Undecided)
      State(..state, edges: dict.insert(state.edges, eid, updated))
    }
    _ -> state
  }
}

fn merge(
  state: State,
  edge_id: EdgeId,
  edge_info: EdgeInfo,
  effects: List(Effect),
) -> #(State, List(Effect)) {
  // Idempotency guard: `on_request_merge` has no dedup for concurrent
  // `AddRequestMergePartition`s on the same edge, and a dense burst of
  // unrelated repairs can make `retry_abandoned_additions` re-fire a fresh
  // `AddTest` for this edge before an earlier request/approval round has
  // finished landing everywhere -- so this can legitimately be called more
  // than once for the same `edge_id`. Only the first call may still send
  // `Connect`: a second one would make the peer's `on_connect` re-run its
  // mutual-merge reaction (fragment change, then either start a fresh
  // `ReIden` wave or re-attach as a child) for an edge it already merged,
  // which is what used to compound into an unbounded `ReIden` storm.
  case edge_info.status == Selected {
    True -> #(state, effects)
    False -> {
      // We own the edge and are authorized to reconnect over it. Promote it
      // to a tree edge and hand off to `d2m.on_connect`, exactly like a
      // GHS/D2M Merge: it waits (defers) until the peer has independently
      // done the same on its side, then breaks the tie by node id and
      // starts the ReIden wave on the smaller side. This is the same
      // rendezvous the failure repair protocol uses to fuse two fragments
      // back together, so there is no addition-specific merge logic to
      // write here.
      let updated_info = EdgeInfo(..edge_info, status: Selected)
      let state =
        State(..state, edges: dict.insert(state.edges, edge_id, updated_info))
      // TODO: is it ok to use the failure connect logic?
      let envelope =
        message.D2MMsg(msg: message.Connect, fragment: state.fragment)
      #(state, [Send(edge_id, envelope), ..effects])
    }
  }
}

fn on_privilege(
  state: State,
  _from_edge: EdgeId,
  event_id: EdgeId,
) -> #(State, List(Effect)) {
  execute_or_route(state, event_id)
}

/// An intermediate node between an LCA and the root, relaying its request
/// for a turn onward. Mirrors `on_addition`'s `Error` branch, but for
/// `AddRequestTurn` instead of `Addition`: remember which child it came
/// from (so a later `Privilege` for this event can be routed back down),
/// then keep going up.
fn on_request_turn(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
) -> #(State, List(Effect)) {
  let state =
    State(
      ..state,
      turn_routing: dict.insert(state.turn_routing, event_id, from_edge),
    )
  relay_or_root(state, event_id)
}

/// Forward `AddDone` up the standing parent chain, or handle it if we are
/// the root. The LCA that originally decided this event intercepts its
/// own two acks here (see `execute_decision`'s `replace_wait_countdown`)
/// and only lets a single, aggregate `AddDone` continue past itself; every
/// other node is just a relay and has no entry to intercept.
fn on_add_done(
  state: State,
  _from_edge: EdgeId,
  event_id: EdgeId,
) -> #(State, List(Effect)) {
  case dict.get(state.replace_wait_countdown, event_id) {
    Error(_) -> forward_or_finish(state, event_id)
    Ok(remaining) ->
      case remaining <= 1 {
        False -> #(
          State(
            ..state,
            replace_wait_countdown: dict.insert(
              state.replace_wait_countdown,
              event_id,
              remaining - 1,
            ),
          ),
          [],
        )
        True -> {
          let state =
            State(
              ..state,
              replace_wait_countdown: dict.delete(
                state.replace_wait_countdown,
                event_id,
              ),
            )
          forward_or_finish(state, event_id)
        }
      }
  }
}

/// Grant a turn: if this node is itself the LCA (has a stashed decision),
/// execute it now. Otherwise route the `Privilege` on down toward whoever
/// is, using the trail `on_request_turn` left in `turn_routing`.
fn execute_or_route(state: State, event_id: EdgeId) -> #(State, List(Effect)) {
  case dict.get(state.ready_replace, event_id) {
    Ok(decision) -> execute_decision(state, event_id, decision)
    Error(_) ->
      case dict.get(state.turn_routing, event_id) {
        Ok(child_edge) -> {
          let state =
            State(
              ..state,
              turn_routing: dict.delete(state.turn_routing, event_id),
            )
          let msg = message.Privilege(event_id:)
          #(state, [
            node.Send(child_edge, message.AddMsg(msg, fragment: state.fragment)),
          ])
        }
        Error(_) -> #(state, [])
      }
  }
}

/// The LCA acting on its own stashed decision, now that it has been
/// authorized. This is the direct continuation of `on_addition`'s old
/// (pre-serialization) immediate-execution path, just deferred until now.
pub fn execute_decision(
  state: State,
  event_id: EdgeId,
  decision: ReplaceDecision,
) -> #(State, List(Effect)) {
  let state =
    State(..state, ready_replace: dict.delete(state.ready_replace, event_id))

  // Both waves always go out, whether or not there is anything to prune:
  // every intermediate node on both origin-to-LCA paths is still holding a
  // `pending_additions` entry for `event_id` that only a Replace wave (see
  // `on_replace`) clears. Only the actual edge mutations below are gated
  // on `decision.should_prune`.
  {
    // We are the originator of the Replace wave(s), so `on_replace` never
    // runs for us. If we are ourselves adjacent to the heaviest edge (i.e.
    // it *is* the branch we are about to forward on), drop it here and
    // mark the message as already past the cut, mirroring what
    // `on_replace` does for every other node it passes through.
    let state = case decision.should_prune && decision.already_at_max_edge {
      True -> {
        let assert Ok(info) = dict.get(state.edges, decision.max_edge)
        State(
          ..state,
          edges: dict.insert(
            state.edges,
            decision.max_edge,
            EdgeInfo(..info, status: Undecided, via_addition: False),
          ),
        )
      }
      False -> state
    }

    // `on_replace` promotes the new edge to `Selected` only on whichever
    // origin *receives* the wave. If we are ourselves one of the two
    // origins, promote our own side locally instead, since we will
    // never receive our own message. `status`/`confirmed` only change when
    // there is something to prune -- a no-op leaves the new edge
    // unselected -- but `via_addition` clears either way, same reasoning as
    // `on_replace`'s matching fix: a no-op result must not permanently hide
    // this edge from `node.min_undecided_edge`'s Phase 3 search.
    let target_is_self = decision.target_origin == state.id
    let other_is_self = decision.other_origin == state.id
    let state = case target_is_self || other_is_self {
      True -> {
        let assert Ok(info) = dict.get(state.edges, event_id)
        let updated_info = case decision.should_prune {
          True ->
            // Same reasoning as `on_replace`: this is the self-origin case
            // of the same cycle-path resolution, so it is confirmed the
            // same way -- see the comment there.
            EdgeInfo(
              ..info,
              status: Selected,
              confirmed: True,
              via_addition: False,
            )
          False -> EdgeInfo(..info, via_addition: False)
        }
        State(..state, edges: dict.insert(state.edges, event_id, updated_info))
      }
      False -> state
    }

    let winner_effects = case target_is_self {
      True -> []
      False -> {
        let replace_msg =
          message.Replace(
            event_id:,
            target_origin: decision.target_origin,
            max_weight: decision.max_weight,
            max_edge: decision.max_edge,
            reversing: decision.should_prune && decision.already_at_max_edge,
            should_prune: decision.should_prune,
          )
        [
          node.Send(
            decision.next_edge,
            message.AddMsg(replace_msg, fragment: state.fragment),
          ),
        ]
      }
    }
    let loser_effects = case other_is_self {
      True -> []
      False -> {
        let attach_msg =
          message.Replace(
            event_id:,
            target_origin: decision.other_origin,
            max_weight: decision.max_weight,
            max_edge: decision.max_edge,
            reversing: False,
            should_prune: decision.should_prune,
          )
        [
          node.Send(
            decision.other_next_edge,
            message.AddMsg(attach_msg, fragment: state.fragment),
          ),
        ]
      }
    }

    // Wait for both branches to report done before letting the root
    // move on (a branch whose origin is us completed synchronously
    // above and never sends an `AddDone`, so it does not count here).
    let remote_branches =
      {
        case target_is_self {
          True -> 0
          False -> 1
        }
      }
      + {
        case other_is_self {
          True -> 0
          False -> 1
        }
      }
    let state =
      State(
        ..state,
        replace_wait_countdown: dict.insert(
          state.replace_wait_countdown,
          event_id,
          remote_branches,
        ),
      )

    #(state, list.append(winner_effects, loser_effects))
  }
}

// --- Helpers -----------------------------------------------------------------

/// Sends a message to all `Selected` edges, skipping the `ignore` edge.
fn broadcast_to_tree(
  state: State,
  ignore: Option(EdgeId),
  msg: message.Msg,
) -> List(Effect) {
  dict.fold(state.edges, [], fn(effects, eid, info) {
    let should_ignore = case ignore {
      Some(ignore_eid) -> eid == ignore_eid
      None -> False
    }
    case info.status == Selected && !should_ignore {
      True -> [Send(eid, msg), ..effects]
      False -> effects
    }
  })
}
