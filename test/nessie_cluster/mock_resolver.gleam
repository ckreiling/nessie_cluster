import nessie_cluster.{type DnsCluster, type Resolver, Resolver}
import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/node.{type ConnectError, type Node}
import gleam/erlang/process.{type Subject}
import gleam/option
import gleam/otp/actor
import gleam/result

const call_timeout = 100

/// Mock DNS responses for nodes.
pub type DnsMock =
  Dict(String, List(String))

/// Mock conect errors for nodes
pub type ConnectErrorMock =
  Dict(Atom, ConnectError)

pub type TestableDnsCluster {
  TestableDnsCluster(
    cluster: DnsCluster,
    connect_calls: fn() -> Dict(Atom, Int),
  )
}

type State {
  State(
    nodes: List(Node),
    dns_mock: DnsMock,
    connect_error_mock: ConnectErrorMock,
    connect_calls: Dict(Atom, Int),
  )
}

type Message {
  Lookup(reply: Subject(List(String)), name: String)
  ConnectNode(reply: Subject(Result(Node, ConnectError)), node: Atom)
  ListNodes(reply: Subject(List(Node)))
  ConnectCalls(reply: Subject(Dict(Atom, Int)))
  Shutdown
}

pub fn new_cluster(
  dns dns_mock: DnsMock,
  connect_errors connect_error_mock: ConnectErrorMock,
) -> TestableDnsCluster {
  let assert Ok(resolver_actor) =
    actor.start(
      State(
        nodes: [],
        dns_mock: dns_mock,
        connect_error_mock: connect_error_mock,
        connect_calls: dict.new(),
      ),
      handle_message,
    )

  let resolver =
    Resolver(
      basename: fn(_) { Ok("mock") },
      list_nodes: fn() { actor.call(resolver_actor, ListNodes, call_timeout) },
      lookup: fn(name: String) {
        actor.call(resolver_actor, Lookup(_, name), call_timeout)
      },
      connect_node: fn(node: Atom) {
        actor.call(resolver_actor, ConnectNode(_, node), call_timeout)
      },
    )

  let cluster = nessie_cluster.with_resolver(nessie_cluster.new(), resolver)

  TestableDnsCluster(cluster, fn() {
    actor.call(resolver_actor, ConnectCalls, call_timeout)
  })
}

fn handle_message(message: Message, state: State) -> actor.Next(Message, State) {
  case message {
    Lookup(reply, name) -> {
      state.dns_mock
      |> dict.get(name)
      |> result.unwrap([])
      |> actor.send(reply, _)
      actor.continue(state)
    }
    ConnectNode(reply, node) -> {
      let connect_calls =
        dict.update(state.connect_calls, node, fn(maybe_count) {
          option.unwrap(maybe_count, 0) + 1
        })
      let state = State(..state, connect_calls: connect_calls)

      case dict.get(state.connect_error_mock, node) {
        Ok(error) -> {
          actor.send(reply, Error(error))
          actor.continue(state)
        }
        Error(Nil) -> {
          let node = to_node(node)
          let nodes = [node, ..state.nodes]
          actor.send(reply, Ok(node))
          actor.continue(State(..state, nodes: nodes))
        }
      }
    }
    ListNodes(reply) -> {
      actor.send(reply, state.nodes)
      actor.continue(state)
    }
    ConnectCalls(reply) -> {
      actor.send(reply, state.connect_calls)
      actor.continue(state)
    }
    Shutdown -> actor.Stop(process.Normal)
  }
}

@external(erlang, "mock_resolver_ffi", "identity")
fn to_node(node: Atom) -> Node
