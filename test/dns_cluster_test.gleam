import dns_cluster.{DnsQuery}
import dns_cluster/mock_resolver.{TestableDnsCluster}
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/node
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

const example_ips = ["1.2.3.4", "5.6.7.8"]

const example_domain_name = "example.com"

pub fn sends_parent_subject_test() {
  let TestableDnsCluster(cluster: cluster, ..) =
    dict.new()
    |> dict.insert(example_domain_name, example_ips)
    |> mock_resolver.new_dns_cluster(connect_errors: dict.new())

  let parent_subject = process.new_subject()

  let _ =
    cluster
    |> dns_cluster.with_query(DnsQuery(example_domain_name))
    |> dns_cluster.with_interval(None)
    |> dns_cluster.start_spec(Some(parent_subject))
    |> should.be_ok()

  let subject =
    parent_subject
    |> process.receive(100)
    |> should.be_ok()

  // Ensure the process is alive
  subject
  |> process.subject_owner()
  |> process.is_alive()
  |> should.be_true()

  // Use the subject received from the parent to make a quick call
  subject
  |> dns_cluster.has_ran(100)
  |> should.be_ok()
  |> should.be_false()
}

pub fn connects_to_valid_host_test() {
  let TestableDnsCluster(cluster: cluster, ..) =
    dict.new()
    |> dict.insert(example_domain_name, example_ips)
    |> mock_resolver.new_dns_cluster(connect_errors: dict.new())

  let cluster =
    cluster
    |> dns_cluster.with_query(DnsQuery(example_domain_name))
    |> dns_cluster.with_interval(None)
    |> dns_cluster.start_spec(None)
    |> should.be_ok()

  cluster
  |> dns_cluster.has_ran(100)
  |> should.be_ok()
  |> should.be_false()

  let #(nodes, errors) =
    should.be_ok(dns_cluster.discover_nodes(cluster, Some(100)))

  cluster
  |> dns_cluster.has_ran(100)
  |> should.be_ok()
  |> should.be_true()

  should.equal(errors, [])

  let expected_nodes =
    example_ips
    |> list.map(fn(ip) { atom.create_from_string("mock@" <> ip) })
    |> set.from_list()

  nodes
  |> list.map(node.to_atom)
  |> set.from_list()
  |> should.equal(expected_nodes)
}

pub fn surfaces_connect_errors_test() {
  let problem_node = atom.create_from_string("mock@1.2.3.4")
  let connect_errors =
    dict.insert(dict.new(), problem_node, node.LocalNodeIsNotAlive)

  let TestableDnsCluster(cluster: cluster, ..) =
    dict.new()
    |> dict.insert(example_domain_name, example_ips)
    |> mock_resolver.new_dns_cluster(connect_errors: connect_errors)

  let cluster =
    cluster
    |> dns_cluster.with_query(DnsQuery(example_domain_name))
    |> dns_cluster.with_interval(None)
    |> dns_cluster.start_spec(None)
    |> should.be_ok()

  let #(nodes, errors) =
    should.be_ok(dns_cluster.discover_nodes(cluster, Some(100)))

  cluster
  |> dns_cluster.has_ran(100)
  |> should.be_ok()
  |> should.be_true()

  should.equal(errors, [
    dns_cluster.NodeConnectError(
      node: problem_node,
      error: node.LocalNodeIsNotAlive,
    ),
  ])

  nodes
  |> list.map(node.to_atom)
  |> should.equal([atom.create_from_string("mock@5.6.7.8")])
}
