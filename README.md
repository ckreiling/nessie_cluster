# dns_cluster

[![Package Version](https://img.shields.io/hexpm/v/dns_cluster)](https://hex.pm/packages/dns_cluster)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/dns_cluster/)

Small but mighty: a library for forming Erlang clusters in Gleam with DNS.

This project is a port of the [Elixir `DNSCluster` library](https://hex.pm/packages/dns_cluster)
to Gleam.

```sh
gleam add gleam_erlang # optional, but highly recommended
gleam add dns_cluster
```
```gleam
import gleam/option
import gleam/erlang/os
import gleam/erlang/process
import gleam/otp/supervisor
import dns_cluster

pub fn main() {
    // Source the DNS name from an env var
    let dns_query = case os.get_env("DISCOVERY_DNS_NAME") {
        // DNS queries will occur periodically for the given DNS name, e.g. "api.internal"
        Ok(dns_name) -> dns_cluster.DnsQuery(dns_name)
        // ensures DNS queries never occur, e.g. for local development
        Error(Nil) -> dns_cluster.Ignore
    }

    let cluster: dns_cluster.DnsCluster =
        dns_cluster.with_query(dns_cluster.new(), dns_query)
  
    // It is recommended to start the cluster under a supervisor so it's
    // restarted if it crashes.
    let cluster_worker =
        supervisor.worker(fn(_) { dns_cluster.start_spec(cluster, option.None) })

    let children = fn(children) {
        children
        |> supervisor.add(cluster_worker)
        // add other children to your supervisor, e.g. a web server ...
    }
  
    let assert Ok(_) = supervisor.start(children)
  
    process.sleep_forever()
}
```

Further documentation can be found at <https://hexdocs.pm/dns_cluster>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
