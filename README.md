# nessie_cluster

[![Package Version](https://img.shields.io/hexpm/v/nessie_cluster)](https://hex.pm/packages/nessie_cluster)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/nessie_cluster/)

Small but mighty: a library for forming Erlang clusters in Gleam via DNS.

This is a port of the [Elixir `DNSCluster` library](https://hex.pm/packages/dns_cluster)
to Gleam. (Note this project does not have any affiliation with the Elixir library)

## Examples

### Fly.io

See the [example repo](https://github.com/ckreiling/nessie_cluster_example) for an example
Gleam web service with clustering on Fly.io.

### Unsupervised

This is **NOT** recommended. [See below](#Supervised) for a supervised example.

```sh
gleam add nessie_cluster
gleam add gleam_erlang # for sleeping
```
```gleam
import gleam/option.{None}
import gleam/erlang/process
import nessie_cluster

pub fn main_simple() {
    let cluster: nessie_cluster.DnsCluster = nessie_cluster.with_query(
      nessie_cluster.new(), 
      nessie_cluster.DnsQuery("api.internal")
    )

    // The process queries DNS periodically, connecting to nodes
    let assert Ok(_subject) = nessie_cluster.start_spec(cluster, None)

    process.sleep_forever()
}
```

### Supervised

**It is strongly recommended to start the process under a supervisor,
ensuring it is restarted if it crashes.**

This example also sources the DNS name from an environment variable.

```sh
gleam add nessie_cluster
gleam add gleam_erlang
gleam add gleam_otp
```

```gleam
import gleam/option.{None}
import gleam/erlang/os
import gleam/erlang/process
import gleam/otp/supervisor
import nessie_cluster

pub fn main() {
    // Source the DNS name from an env var
    let dns_query = case os.get_env("DISCOVERY_DNS_NAME") {
        // DNS queries will occur periodically for the given DNS name
        Ok(dns_name) -> nessie_cluster.DnsQuery(dns_name)
        // ensures DNS queries never occur, e.g. for local development
        Error(Nil) -> nessie_cluster.Ignore
    }

    let cluster: nessie_cluster.DnsCluster =
        nessie_cluster.with_query(nessie_cluster.new(), dns_query)

    let cluster_worker =
        supervisor.worker(fn(_) { 
            nessie_cluster.start_spec(cluster, None)
        })

    let children = fn(children) {
        children
        |> supervisor.add(cluster_worker)
        // add other children to your supervisor, e.g. a web server ...
    }
  
    let assert Ok(_) = supervisor.start(children)
  
    process.sleep_forever()
}
```

Further documentation can be found at <https://hexdocs.pm/nessie_cluster>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
