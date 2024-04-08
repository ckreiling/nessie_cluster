import gleam/string
import gleam/function
import gleam/list
import gleam/io
import gleam/result
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/erlang/process.{type Subject, type Timer}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/node.{type ConnectError, type Node}
import nessie

pub type LoggerLevel =
  String

/// A simple logger type which should print the message.
pub type Logger =
  fn(LoggerLevel, String) -> Nil

/// The engine powering DNS lookups and node connections. This is
/// mostly useful for testing; the Resolver returned by
/// `default_resolver` should be sufficient for most - if not all - uses.
pub type Resolver {
  Resolver(
    /// Extract the base name of a node (i.e. everything before the `@` symbol).
    basename: fn(Atom) -> Result(String, Nil),
    /// Connect to a node by name.
    connect_node: fn(Atom) -> Result(Node, ConnectError),
    /// List all visible nodes.
    list_nodes: fn() -> List(Node),
    /// Perform a DNS lookup, returning a list of IP addresses
    /// as strings.
    lookup: fn(String) -> List(String),
  )
}

/// A DNS query to be used to discover ndoes.
pub type DnsQuery {
  /// A DNS name to query.
  DnsQuery(query: String)
  /// Indicate that the cluster should not perform DNS lookups,
  /// and therefore not connect to any nodes.
  ///
  /// This is useful when running in a development environment
  /// where clustering isn't necessary.
  Ignore
}

/// The central DNS cluster type.
///
/// Use the `new` function to create a new cluster, and then
/// use the `with_*` functions to configure it.
pub opaque type DnsCluster {
  DnsCluster(
    name: Atom,
    query: DnsQuery,
    interval_millis: Option(Int),
    logger: Logger,
    resolver: Resolver,
  )
}

pub opaque type DnsClusterState {
  DnsClusterState(
    has_ran: Bool,
    cluster: DnsCluster,
    basename: String,
    poll_timer: Option(Timer),
    self: Subject(Message),
  )
}

/// Create a new DnsCluster for the given query.
///
/// Note that the returned DNS cluster does not actually
/// do anything if a query is not provided using
/// `with_query`.
pub fn new() -> DnsCluster {
  DnsCluster(
    name: atom.create_from_string("dns_cluster"),
    query: Ignore,
    interval_millis: option.Some(5000),
    logger: default_logger("[dns_cluster]"),
    resolver: default_resolver(),
  )
}

/// Use a custom name for the process.
///
/// The default `dns_cluster` name is typically sufficient.
pub fn with_name(for cluster: DnsCluster, using name: Atom) -> DnsCluster {
  DnsCluster(..cluster, name: name)
}

/// Set the query for the given DNS cluster.
///
/// Defaults to `Ignore`.
pub fn with_query(for cluster: DnsCluster, using q: DnsQuery) -> DnsCluster {
  DnsCluster(..cluster, query: q)
}

/// Turn logging on or off for the given cluster.
///
/// Defaults to a `gleam/io.println()` call.
pub fn with_logger(for cluster: DnsCluster, using logger: Logger) -> DnsCluster {
  DnsCluster(..cluster, logger: logger)
}

/// Set the interval at which DNS is polled. If `None`, the
/// cluster will only poll DNS when `discover_nodes` is called.
///
/// Defaults to 5000 milliseconds.
pub fn with_interval(
  for cluster: DnsCluster,
  millis interval: Option(Int),
) -> DnsCluster {
  DnsCluster(..cluster, interval_millis: interval)
}

/// Set a custom resolver for the given cluster.
///
/// The default resolver will query for A and AAAA
/// records, and try to connect to Erlang nodes at
/// all of the returned IP addresses.
///
/// Most users will not need to change this, but
/// it can be useful for testing or more advanced
/// use-cases.
pub fn with_resolver(
  for cluster: DnsCluster,
  using resolver: Resolver,
) -> DnsCluster {
  DnsCluster(..cluster, resolver: resolver)
}

pub opaque type Message {
  DiscoverNodes(
    client: Option(Subject(#(List(Node), List(ConnectError)))),
    manual: Bool,
  )
  Stop(client: Subject(Nil))
  HasRan(client: Subject(Bool))
}

/// Triggers node discovery manually, returning a tuple containing the list of
/// connected nodes (after doing discovery) and a list of connection errors that
/// occurred, if any.
///
/// If no timeout is supplied, this function returns immediately with `Ok(#([], []))`
/// after sending a message to trigger node discovery.
///
/// This function is only useful for advanced cases - the DNS cluster
/// polls at a regular interval by default, which is typically sufficient.
pub fn discover_nodes(
  on subject: Subject(Message),
  timeout_millis timeout: Option(Int),
) -> Result(#(List(Node), List(ConnectError)), process.CallError(_)) {
  case timeout {
    option.Some(timeout) ->
      process.try_call(
        subject,
        fn(client) { DiscoverNodes(option.Some(client), True) },
        timeout,
      )
    option.None -> {
      process.send(subject, DiscoverNodes(option.None, True))
      Ok(#([], []))
    }
  }
}

/// Stop the DNS cluster.
///
/// This causes the actor to exit normally.
pub fn stop(
  subject: Subject(Message),
  timeout: Int,
) -> Result(Nil, process.CallError(_)) {
  process.try_call(subject, Stop, timeout)
}

/// Returns a boolean indicating whether DNS discovery has
/// ran at least once.
///
/// Useful for running in a healthcheck to ensure at least 1
/// DNS discovery cycle has ran.
pub fn has_ran(
  subject: Subject(Message),
  timeout: Int,
) -> Result(Bool, process.CallError(_)) {
  process.try_call(subject, HasRan, timeout)
}

/// Starts an actor which will periodically poll DNS for
/// IP addresses and connect to Erlang nodes.
pub fn start_spec(
  cluster: DnsCluster,
  parent_subject: Option(Subject(Subject(Message))),
) -> Result(Subject(Message), actor.StartError) {
  actor.start_spec(spec(cluster, parent_subject))
}

fn spec(cluster: DnsCluster, parent_subject: Option(Subject(Subject(Message)))) {
  actor.Spec(
    init_timeout: 10_000,
    init: fn() {
      let basename_result =
        node.self()
        |> node.to_atom()
        |> cluster.resolver.basename()
      case basename_result {
        Ok(basename) -> {
          let _ = process.register(process.self(), cluster.name)
          let state =
            DnsClusterState(
              cluster: cluster,
              basename: basename,
              poll_timer: option.None,
              self: process.new_subject(),
              has_ran: False,
            )
          case #(cluster.query, cluster.interval_millis) {
            #(_, option.None) -> Nil
            #(Ignore, _) -> Nil
            #(DnsQuery(_), _) ->
              process.send(state.self, DiscoverNodes(option.None, False))
          }
          option.map(parent_subject, process.send(_, state.self))
          let selector =
            process.selecting(
              process.new_selector(),
              state.self,
              function.identity,
            )
          actor.Ready(state: state, selector: selector)
        }
        Error(_) -> actor.Failed("Failed to get node basename")
      }
    },
    loop: fn(msg: Message, state: DnsClusterState) {
      case #(msg, state.cluster.query) {
        #(Stop(client), _) -> {
          option.map(state.poll_timer, process.cancel_timer(_))
          let _ = process.unregister(state.cluster.name)
          process.send(client, Nil)
          state.cluster.logger("warn", "DNS cluster stopped.")
          actor.Stop(process.Normal)
        }
        #(HasRan(client), _) -> {
          process.send(client, state.has_ran)
          actor.Continue(state: state, selector: option.None)
        }
        #(DiscoverNodes(maybe_client, manual), DnsQuery(query)) -> {
          let cluster = state.cluster

          let errors =
            do_discover_nodes(
              cluster.resolver,
              cluster.logger,
              state.basename,
              query,
            )

          let state = case #(cluster.interval_millis, maybe_client, manual) {
            // If there is an available client, send it a response.
            #(_, option.Some(client), _) -> {
              let connected_nodes = cluster.resolver.list_nodes()
              actor.send(client, #(connected_nodes, errors))
              state
            }
            // If no client and manual call, skip timer reset
            #(_, _, True) -> state
            // If no interval is set, skip timer reset
            #(option.None, _, _) -> state
            // Finally we are confident this is not a manual invocation AND we have an interval
            #(option.Some(interval_millis), _, _) ->
              DnsClusterState(
                ..state,
                poll_timer: option.Some(process.send_after(
                  state.self,
                  interval_millis,
                  DiscoverNodes(option.None, False),
                )),
              )
          }

          let state = DnsClusterState(..state, has_ran: True)
          actor.Continue(state: state, selector: option.None)
        }

        #(DiscoverNodes(maybe_client, _), Ignore) -> {
          state.cluster.logger(
            "warn",
            "DNS cluster is set to ignore, will not discover or connect to nodes.",
          )
          case maybe_client {
            option.Some(client) -> {
              let nodes = state.cluster.resolver.list_nodes()
              process.send(client, #(nodes, []))
            }
            option.None -> Nil
          }
          actor.Continue(state: state, selector: option.None)
        }
      }
    },
  )
}

/// Returns the default resolver which will query for A and AAAA
/// records, and try to connect to Erlang nodes at all of the
/// returned IP addresses.
///
/// Most users will never call this function, however it is provided
/// in-case a more complex resolution strategy is desired.
pub fn default_resolver() -> Resolver {
  Resolver(
    connect_node: node.connect,
    list_nodes: node.visible,
    basename: fn(a) {
      let split =
        a
        |> atom.to_string()
        |> string.split_once(on: "@")
      case split {
        Ok(#(basename, _)) -> Ok(basename)
        _ -> Error(Nil)
      }
    },
    lookup: fn(q) {
      let ipv4_addrs =
        q
        |> nessie.lookup_ipv4(nessie.In, [])
        |> list.map(nessie.IPV4)

      let ipv6_addrs =
        q
        |> nessie.lookup_ipv6(nessie.In, [])
        |> list.map(nessie.IPV6)

      let #(ips, _) =
        [ipv4_addrs, ipv6_addrs]
        |> list.concat()
        |> list.map(nessie.ip_to_string)
        |> result.partition()

      ips
    },
  )
}

/// Returns the default logger which uses `gleam/io.println()` with
/// the specified prefix.
fn default_logger(prefix: String) -> Logger {
  fn(level, msg) {
    io.println(prefix <> "[" <> string.uppercase(level) <> "] " <> msg)
  }
}

fn do_discover_nodes(
  resolver: Resolver,
  logger: Logger,
  basename: String,
  query: String,
) -> List(ConnectError) {
  let node_names =
    list.map(resolver.list_nodes(), fn(n) { atom.to_string(node.to_atom(n)) })
  let peer_ips = resolver.lookup(query)

  let #(_, errors) =
    peer_ips
    |> list.map(fn(ip) { basename <> "@" <> ip })
    |> list.filter(fn(node_name) { !list.contains(node_names, node_name) })
    |> list.map(fn(node_name) {
      let r =
        node_name
        |> atom.create_from_string()
        |> resolver.connect_node()

      case r {
        Ok(_) -> {
          logger("info", "Connected to node " <> node_name)
          Ok(node_name)
        }
        Error(err) -> {
          logger(
            "error",
            "Failed to connect to node "
              <> node_name
              <> ": "
              <> connect_error_to_string(err),
          )
          Error(err)
        }
      }
    })
    |> result.partition()

  errors
}

fn connect_error_to_string(e: ConnectError) -> String {
  case e {
    node.FailedToConnect -> "failed to connect"
    node.LocalNodeIsNotAlive -> "local node is not alive"
  }
}
