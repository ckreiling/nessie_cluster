# dns_cluster

[![Package Version](https://img.shields.io/hexpm/v/dns_cluster)](https://hex.pm/packages/dns_cluster)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/dns_cluster/)

Small but mighty: a library for forming Erlang clusters in Gleam via DNS.

This is a port of the [Elixir `DNSCluster` library](https://hex.pm/packages/dns_cluster)
to Gleam.

```sh
gleam add dns_cluster
gleam add gleam_erlang # optional, but highly recommended
gleam add gleam_otp    # optional, but highly recommended
```
```gleam
import gleam/option.{None}
import gleam/erlang/process
import dns_cluster

pub fn main_simple() {
    let cluster: dns_cluster.DnsCluster = dns_cluster.with_query(
      dns_cluster.new(), 
      dns_cluster.DnsQuery("api.internal")
    )

    // The process queries DNS periodically, connecting to nodes
    let assert Ok(_subject) = dns_cluster.start_spec(cluster, None)

    process.sleep_forever()
}
```

Below is a slightly more complex example, sourcing the DNS name
from an environment variable and starting the DNS cluster process
under a supervisor.

**It is strongly recommended to start the process under a supervisor,
ensuring it is restarted if it crashes.**

```gleam
import gleam/option.{Some}
import gleam/erlang/os
import gleam/erlang/process
import gleam/otp/supervisor
import dns_cluster

pub fn main() {
    // Source the DNS name from an env var
    let dns_query = case os.get_env("DISCOVERY_DNS_NAME") {
        // DNS queries will occur periodically for the given DNS name
        Ok(dns_name) -> dns_cluster.DnsQuery(dns_name)
        // ensures DNS queries never occur, e.g. for local development
        Error(Nil) -> dns_cluster.Ignore
    }

    let cluster: dns_cluster.DnsCluster =
        dns_cluster.with_query(dns_cluster.new(), dns_query)

    let parent_subject = process.new_subject()
  
    let cluster_worker =
        supervisor.worker(fn(_) { 
            dns_cluster.start_spec(cluster, option.Some(parent_subject))
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

## On Fly.io

Forming a cluster on Fly.io is simple. Follow the instructions below.

Firstly, setup a deployment of Gleam on Fly.io following [the official
guide](https://gleam.run/deployment/fly/).

Update the CMD in the Dockerfile to instead look like this:

```dockerfile
# ... rest of the Dockerfile

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run", "-extra", "-name", "myflyapp@${FLY_PRIVATE_IP}"]
```

Further documentation can be found at <https://hexdocs.pm/dns_cluster>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
gleam shell # Run an Erlang shell
```
