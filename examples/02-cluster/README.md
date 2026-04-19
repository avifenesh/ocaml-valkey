# 02-cluster — cluster routing + TLS

Two programs:

| File | Demonstrates |
|---|---|
| [routing.ml](routing.ml) | All four `Read_from` modes side by side, with per-node tally |
| [tls.ml](tls.ml) | TLS template — managed-service (system CAs) + internal CA paths |

## routing.ml

Run against the included docker-compose cluster:

```bash
sudo bash scripts/cluster-hosts-setup.sh   # one-time
docker compose -f docker-compose.cluster.yml up -d
dune exec examples/02-cluster/routing.exe
```

Probes `CLUSTER MYID` 12 times under each routing mode and tallies
which node actually served the request. Expected output for a
3-primary / 3-replica cluster:

```
[Primary] for slot 0, 12 probes:
  12  <primary id>

[Prefer_replica] for slot 0, 12 probes:
  12  <some replica id>      ← all to one replica per process; varies between runs
```

The `Prefer_replica` distribution is randomised per call (see
[`lib/cluster_router.ml`](../../lib/cluster_router.ml)
`pick_random`), so successive runs hit different replicas.

The AZ-affinity probes show the fall-back-to-primary behaviour
because docker-compose doesn't simulate availability zones — this
is exactly what you'd see in a single-AZ deployment with the AZ
flag set.

## tls.ml

Template only — won't connect anywhere unless you fill in the
host / port. Two patterns:

```ocaml
(* Hosted service: system trust store. *)
let tls = TLS.with_system_cas ~server_name:"my.cache.amazonaws.com" ()

(* Internal CA: load a PEM file. *)
let tls = TLS.with_ca_cert ~server_name:"valkey-c1" ~ca_pem ()
```

For dev TLS, generate a self-signed CA with
`scripts/gen-tls-certs.sh` and point `with_ca_cert` at the
resulting `.dev-certs/ca.pem`. See [docs/tls.md](../../docs/tls.md)
for the full picture.
