//// Addition response protocol (Tier 3).

import d2mst/fragment.{type FragmentId}
import d2mst/graph.{type Edge, type EdgeId, type NodeId}
import d2mst/message.{type AddMsg, add_is_intra_fragment}
import d2mst/node.{
  type EdgeInfo, type Effect, type State, EdgeInfo, Selected, Send, State,
  Undecided, defer,
}
import gleam/dict
import gleam/option.{type Option, None, Some}

/// Register a newly added edge and trigger the addition response protocol.
pub fn add_edge(state: State, edge: Edge) -> #(State, List(Effect)) {
  let peer = graph.other_node(edge, state.id)
  let eid = graph.edge_id(edge.u, edge.v)
  let state =
    State(
      ..state,
      edges: dict.insert(
        state.edges,
        eid,
        EdgeInfo(peer:, edge:, status: Undecided),
      ),
    )

  let effect =
    Send(eid, message.AddMsg(message.AddTest, fragment: state.fragment))
  #(state, [effect])
}

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
        ) ->
          on_replace(
            state,
            on,
            event_id,
            target_origin,
            max_weight,
            max_edge,
            reversing,
          )
        message.Privilege(event_id:) -> on_privilege(state, on, event_id)
        message.AddConfirm(event_id:) -> on_add_confirm(state, event_id)
      }
  }
}

fn on_edge_test(
  state: State,
  eid: EdgeId,
  reported: FragmentId,
) -> #(State, List(Effect)) {
  let assert Ok(info) = dict.get(state.edges, eid)

  case state.fragment == reported {
    True -> {
      // SAME FRAGMENT: the new edge forms a cycle. The max weight edge on the cycle must
      // be removed.
      case state.parent_edge {
        None -> {
          // If this node is already the root, handle the Addition locally.
          process_addition(state, eid, eid, info.edge.weight, state.id, 0, eid)
        }
        Some(parent_edge) -> {
          let add_msg =
            message.Addition(
              event_id: eid,
              new_weight: info.edge.weight,
              origin: state.id,
              running_max: 0,
              max_edge: eid,
            )
          let envelope = message.AddMsg(add_msg, fragment: state.fragment)
          #(state, [node.Send(parent_edge, envelope)])
        }
      }
    }
    False -> {
      // DIFFERENT FRAGMENTS
      case state.halted {
        True -> {
          // Case 1: no operation in progress, the network is partitioned.
          case state.parent_edge {
            // If we are the root, we can merge the two fragments directly.
            None -> merge(state, eid, info, [])
            // Otherwise, we ask the root to authorize the merge.
            Some(parent_edge) -> {
              // Send a request to the root to merge using this new link.
              let request_msg = message.AddRequestMergePartition(eid)
              let envelope =
                message.AddMsg(request_msg, fragment: state.fragment)
              #(state, [node.Send(parent_edge, envelope)])
            }
          }
        }
        False -> {
          // Case 2: A failure response is in progress, defer the message. Some time in
          // the future we will be in the True branch above.
          #(
            defer(
              state,
              eid,
              message.AddMsg(message.AddTest, fragment: state.fragment),
            ),
            [],
          )
        }
      }
    }
  }
}

fn on_request_merge(
  state: State,
  on: EdgeId,
  add_edge: EdgeId,
) -> #(State, List(Effect)) {
  let is_root = state.parent_edge == option.None
  case is_root {
    True -> {
      // NOT FIXED (needs new State field): a second AddRequestMergePartition
      // arriving here while an earlier merge is still being approved should
      // be rejected or queued, not approved outright. Doing this properly
      // needs the root to track "is a merge currently pending?" somewhere
      // in State -- not defined anywhere I have visibility into.
      let msg = message.AddApproveMergePartition(add_edge)
      let envelope = message.AddMsg(msg, fragment: state.fragment)
      #(state, broadcast_to_tree(state, option.None, envelope))
    }
    False -> {
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
    Ok(info) -> merge(state, add_edge, info, effects)
    Error(_) -> #(state, effects)
  }
}

fn merge(
  state: State,
  edge_id: EdgeId,
  edge_info: EdgeInfo,
  effects: List(Effect),
) -> #(State, List(Effect)) {
  // We own the edge! Execute the merge.
  let updated_info = EdgeInfo(..edge_info, status: Selected)
  let state =
    State(..state, edges: dict.insert(state.edges, edge_id, updated_info))

  // TODO: execute merge
  todo()
}

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
    in_info.edge.weight > running_max
  {
    True -> #(in_info.edge.weight, from_edge)
    False -> #(running_max, max_edge)
  }
  process_addition(
    state,
    from_edge,
    event_id,
    new_weight,
    origin,
    updated_max,
    updated_max_edge,
  )
}

/// LCA-detection and forwarding logic.
fn process_addition(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
  new_weight: Int,
  origin: NodeId,
  running_max: Int,
  max_edge: EdgeId,
) -> #(State, List(Effect)) {
  let updated_msg =
    message.Addition(event_id:, new_weight:, origin:, running_max:, max_edge:)

  // Check if we already received an Addition for this event (LCA check).
  case dict.get(state.pending_additions, event_id) {
    Ok(#(first_msg, first_msg_from_edge)) -> {
      let assert message.Addition(..) = first_msg
      // We are the LCA. Now we update the topology.
      let overall_max = case first_msg.running_max > running_max {
        True -> #(
          first_msg.running_max,
          first_msg.max_edge,
          first_msg.origin,
          first_msg_from_edge,
        )
        False -> #(running_max, max_edge, origin, from_edge)
      }

      case new_weight < overall_max.0 {
        True -> {
          // The new edge is lighter: prune the heaviest edge.
          let replace_msg =
            message.Replace(
              event_id:,
              target_origin: overall_max.2,
              max_weight: overall_max.0,
              max_edge: overall_max.1,
              reversing: False,
            )
          let envelope = message.AddMsg(replace_msg, fragment: state.fragment)
          #(state, [node.Send(overall_max.3, envelope)])
        }
        False -> {
          // New edge is equal or heavier: MST remains unchanged.
          #(state, [])
        }
      }
    }
    Error(_) -> {
      // First Addition to arrive at this node: save it and forward upward.
      let state =
        State(
          ..state,
          pending_additions: dict.insert(state.pending_additions, event_id, #(
            updated_msg,
            from_edge,
          )),
        )

      case state.parent_edge {
        Some(parent_edge) -> {
          let envelope = message.AddMsg(updated_msg, fragment: state.fragment)
          #(state, [node.Send(parent_edge, envelope)])
        }
        None -> {
          // We are the Root: wait for the second half to arrive.
          #(state, [])
        }
      }
    }
  }
}

fn on_replace(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
  target_origin: NodeId,
  max_weight: Int,
  max_edge: EdgeId,
  reversing: Bool,
) -> #(State, List(Effect)) {
  // Are we reversing? If we just crossed the max_edge, or were already reversing.
  let now_reversing = reversing || from_edge == max_edge

  // Find the next hop towards the origin.
  let next_hop = case state.id == target_origin {
    True -> option.None
    False ->
      case dict.get(state.pending_additions, event_id) {
        Ok(#(_msg, child_edge)) -> option.Some(child_edge)
        Error(_) -> option.None
      }
  }

  // Reverse the parent pointer if we are on the disconnected side.
  let state = case now_reversing {
    True -> {
      let new_parent = case state.id == target_origin {
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
        )
      let envelope = message.AddMsg(msg, fragment: state.fragment)
      [node.Send(child_edge, envelope)]
    }
    None -> []
  }

  // If the max_edge is connected to us, drop it.
  let state = case dict.get(state.edges, max_edge) {
    Ok(info) -> {
      let updated_info = EdgeInfo(..info, status: Undecided)
      State(..state, edges: dict.insert(state.edges, max_edge, updated_info))
    }
    Error(_) -> state
  }

  // If we are the target_origin, promote the new edge to the tree and tell the peer
  // across it to do the same (the Replace only ever reaches this one side).
  case state.id == target_origin {
    True ->
      case dict.get(state.edges, event_id) {
        Ok(info) -> {
          let updated_info = EdgeInfo(..info, status: Selected)
          let state =
            State(
              ..state,
              edges: dict.insert(state.edges, event_id, updated_info),
            )
          let confirm =
            message.AddMsg(
              message.AddConfirm(event_id:),
              fragment: state.fragment,
            )
          #(state, [node.Send(event_id, confirm), ..effects])
        }
        Error(_) -> #(state, effects)
      }
    False -> #(state, effects)
  }
}

/// Forcefully promote to Selected the edge from which this AddConfirm arrived. Used by
/// on_replace to notify the non-target_origin endpoint of a newly added edge that it is
/// now part of the MST.
fn on_add_confirm(state: State, event_id: EdgeId) -> #(State, List(Effect)) {
  case dict.get(state.edges, event_id) {
    Ok(info) -> {
      let updated_info = EdgeInfo(..info, status: Selected)
      #(
        State(..state, edges: dict.insert(state.edges, event_id, updated_info)),
        [],
      )
    }
    Error(_) -> #(state, [])
  }
}

fn on_privilege(
  state: State,
  from_edge: EdgeId,
  event_id: EdgeId,
) -> #(State, List(Effect)) {
  // The Privilege token serializes overlapping additions.
  // TODO: use the token to serialize.
  let msg = message.Privilege(event_id:)
  let envelope = message.AddMsg(msg, fragment: state.fragment)
  #(state, broadcast_to_tree(state, option.Some(from_edge), envelope))
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
