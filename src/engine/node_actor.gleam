//// Actor shell for a protocol node.
////
//// The only part of the node that touches processes: it feeds received
//// messages into `node.handle` and performs the resulting effects by
//// sending to link actors, reporting every send and every state change to
//// the logger. The GHS logic itself lives in `node.gleam` as a pure state
//// machine and knows nothing about any of this.

import d2mst/graph.{type Edge, type EdgeId}
import d2mst/message
import engine/link
import engine/logger
import engine/node.{type Event, type State, LinkDown, Receive, Send, Wakeup}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor

pub type CtlMsg {
  /// Wire the node to its link actors. Sent once by the network before any
  /// wakeup. The node monitors every link process.
  Attach(links: Dict(EdgeId, link.Handle))
  /// A single new link was added to the running network (tier 3).
  AttachEdge(edge: Edge, link: link.Handle)
  Wake
  FromLink(on: EdgeId, msg: message.Msg)
  /// A monitored process (a link) went down.
  MonitorDown(down: process.Down)
}

pub type Handle {
  Handle(
    pid: Pid,
    control: Subject(CtlMsg),
    delivery: Subject(message.Delivery),
  )
}

type Shell {
  Shell(
    core: State,
    links: Dict(EdgeId, link.Handle),
    logger: Subject(logger.Msg),
  )
}

pub fn start(
  id: graph.NodeId,
  incident: List(Edge),
  lg: Subject(logger.Msg),
) -> Handle {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(control) {
      let delivery = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(control)
        |> process.select_map(delivery, fn(d: message.Delivery) {
          FromLink(d.on, d.msg)
        })
        |> process.select_monitors(MonitorDown)
      actor.initialised(Shell(node.init(id, incident), dict.new(), lg))
      |> actor.selecting(selector)
      |> actor.returning(#(control, delivery))
      |> Ok
    })
    |> actor.on_message(shell_handle)
    |> actor.start
  // Free-standing process: crash_node kills it, and that death must not
  // propagate to whoever built the network.
  process.unlink(started.pid)
  let #(control, delivery) = started.data
  Handle(pid: started.pid, control:, delivery:)
}

fn shell_handle(shell: Shell, msg: CtlMsg) -> actor.Next(Shell, CtlMsg) {
  case msg {
    Attach(links) -> {
      dict.to_list(links)
      |> list.each(fn(p) { process.monitor({ p.1 }.pid) })
      actor.continue(Shell(..shell, links:))
    }
    AttachEdge(edge, l) -> {
      process.monitor(l.pid)
      actor.continue(
        Shell(
          ..shell,
          core: node.add_edge(shell.core, edge),
          links: dict.insert(shell.links, graph.edge_id(edge.u, edge.v), l),
        ),
      )
    }
    Wake -> run(shell, Wakeup)
    FromLink(on, m) -> run(shell, Receive(on, m))
    MonitorDown(down) ->
      case down {
        process.ProcessDown(pid: pid, ..) ->
          case dict.to_list(shell.links) |> list.find(fn(p) { { p.1 }.pid == pid }) {
            Ok(#(eid, _)) ->
              run(
                Shell(..shell, links: dict.delete(shell.links, eid)),
                LinkDown(eid),
              )
            // Not one of our links (already replaced, or unknown): ignore.
            Error(_) -> actor.continue(shell)
          }
        process.PortDown(..) -> actor.continue(shell)
      }
  }
}

fn run(shell: Shell, event: Event) -> actor.Next(Shell, CtlMsg) {
  let #(core, effects) = node.handle(shell.core, event)
  list.each(effects, fn(effect) {
    let Send(on, m) = effect
    case dict.get(shell.links, on) {
      Ok(l) -> {
        process.send(l.subject, link.Transmit(core.id, m))
        process.send(shell.logger, logger.Sent(core.id))
      }
      Error(_) -> Nil
    }
  })
  process.send(shell.logger, logger.StateChanged(logger.summarise(core)))
  actor.continue(Shell(..shell, core:))
}
