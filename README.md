# nix-usernetes

A Nix-native, rootless, single-node Kubernetes cluster for NixOS developer workstations, inspired by usernetes.

Built as a replacement for [`kindest/node`](https://github.com/rootless-containers/usernetes) that works on systems where every filesystem is f2fs — which the upstream cAdvisor vendored in `kindest/node` does not support.

## Why this exists

The upstream `kindest/node` embeds a kubelet whose vendored cAdvisor hardcodes a `supportedFsType` map that does not include `f2fs`. On a NixOS host with full-disk LUKS+LVM+f2fs encryption, kubelet crashes immediately:

```
failed to get rootfs info: failed to get mount point for device
"/dev/mapper/nix-home": no partition info for device
```

The fix was a one-line change (`"f2fs": true`) that hadn't reached any upstream release, so this project built all Kubernetes components from source in Nix with the patch applied. Kubernetes 1.36 fixed it upstream: its cAdvisor (v0.56.2) looks filesystems up through plugins, and the VFS plugin handles f2fs. Since 1.37 the build uses Kubernetes' vendored cAdvisor unchanged.

## What it builds

A layered OCI container image containing:

- **kubelet, kube-apiserver, kube-controller-manager, kube-scheduler, kubectl, kube-proxy** — built from source at K8s 1.37.1, as static binaries (`CGO_ENABLED=0`)
- **etcd** — from nixpkgs
- **containerd, runc, cri-tools, cni-plugins** — from nixpkgs
- **vigild as PID 1** — [vigil-rs](https://github.com/git001/vigil-rs), through nix-container-lib's `System` mode: its start script runs the node's boot steps (the cgroup controllers handed to the pods' cgroups, the sysctls, the pod masquerade), then execs vigild

All control plane components (etcd, kube-apiserver, kube-controller-manager, kube-scheduler), containerd and the kubelet run as **vigild services** using the Nix-built binaries already in the image. No container image pulls, no pause images, no in-cluster CNI required for the control plane.

## Requirements

- NixOS (tested on 26.05)
- Podman 5.x
- `just`
- `nix` with flakes enabled

## Quickstart

### First time

```bash
# Build the image
nix build .#node-image -o result-node-image

# Load into podman
podman load < result-node-image

# Start and initialise the cluster
just up
just init
just kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig

# Verify
kubectl get nodes
kubectl cluster-info
```

### Subsequent starts

Everything the cluster keeps is on named podman volumes: `u7s-pki` (PKI and kubeconfigs), `u7s-etcd`, `u7s-kubelet`,
`u7s-containerd` (images) and `u7s-local-path` (every persistent volume's data). The node container itself holds
nothing, so it may be stopped, removed (by `just down`, or by hand, `podman system prune` included) and created again
without losing anything. No need to re-init:

```bash
just up          # starts a stopped node (after a host reboot), or creates a removed one on the volumes
just kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

### Restart, tear down

```bash
just restart     # recreate the node container on the same state: how a newly loaded node image takes effect
just down        # stop and remove the node container; the state volumes stay
just reset       # stop the node and wipe all state, persistent volumes included
```

A node image with a Kubernetes minor version more than one ahead of the cluster's needs `reset`, not `restart`: the
control plane and etcd are upgraded one minor version at a time.

## A cluster of nodes

`cluster.dhall` describes a cluster on the same host: one control plane and any number of workers, each its own
container, with labels and taints per node. It runs beside the single node (u7s), under its own names (`u7c-*`) and
on its own apiserver port (7443).

```bash
nix build .#node-image -o result-node-image && just load-node-image       # the control plane
nix build .#worker-image -o result-worker-image && just load-worker-image # the workers
nix develop        # cluster.sh needs dhall-to-json, ip, nft, nsenter and unshare
just cluster-up    # the hub, the nodes' network, the nodes
just cluster-init  # once: the control plane's PKI, the workers joined, labels and taints
just cluster-kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig-u7c
kubectl get nodes -o wide
```

`just cluster-down` stops and removes the nodes and keeps their volumes (`u7c-<node>-pki`, `-kubelet`, ...);
`just cluster-up` brings them back without another init. `just cluster-reset` wipes them. To add a node, put it at the
end of `cluster.dhall`'s list and run `just cluster-up` and `just cluster-init` again: init skips what is done.

**Placement.** `cluster.dhall` lays the cluster out in pools, one worker each, for Polar:

| Node | Runs | Label | Taint |
|------|------|-------|-------|
| `cp` | Kubernetes' own (CoreDNS) | | `node-role.kubernetes.io/control-plane:NoSchedule` |
| `core` | Polar's core: the credentials agent, the cert issuer, cassini | `polar.dev/pool=core` | `polar.dev/pool=core:NoSchedule` |
| `observers` | the low-trust side: the observers | `polar.dev/pool=observers` | `polar.dev/pool=observers:NoSchedule` |
| `writers` | the high-trust side: what writes the graph | `polar.dev/pool=writers` | `polar.dev/pool=writers:NoSchedule` |
| `services` | everything else Polar relies on (Flux, the registry, Keycloak, ...) | `polar.dev/pool=services` | |

A pod goes to a dedicated pool by asking for it twice, by the label and by tolerating the taint:

```yaml
nodeSelector: { polar.dev/pool: writers }
tolerations: [ { key: polar.dev/pool, operator: Equal, value: writers, effect: NoSchedule } ]
```

A pod that asks for no pool runs on `services`, the one worker without a taint. A pod with the selector but not the
toleration does not run anywhere. The single node (u7s) has no pools, so a workload that selects one belongs on a
cluster: the selector is for the deployments that target a cluster.

The nodes share this host's kernel: a pool separates workloads by where Kubernetes schedules them, the way they would be
on separate machines, and is not a security boundary of its own.

**The network.** Rootless podman's bridge networks need iptables extensions (`xt_comment`, `xt_nat`) or nftables'
`inet` family, which a kernel without IPv6 does not have, so the cluster brings its own, built inside podman's rootless
user namespace with no privilege beyond what the user already has there:

```
host ──slirp4netns── hub (10.0.2.100)          masquerades the nodes out, their DNS to the host's resolver,
                     └── br0 10.77.0.1/24      the host's :7443 to the control plane's apiserver
                         ├── veth ── cp    10.77.0.11   pods 10.244.0.0/24
                         └── veth ── core  10.77.0.12   pods 10.244.1.0/24
```

Each node's network namespace is kept on a file under `$XDG_RUNTIME_DIR/nix-usernetes/<cluster>/netns`, wired to the
hub's bridge before the node starts, and joined by the node's container (`--network ns:`), so a node that restarts
keeps its network. A hub that restarts takes its ends of the veth pairs with it: `just cluster-up` wires the nodes
again. Every node routes each other node's pod range through that node, so pods reach each other directly, without NAT.

**What differs by role.** `node.dhall` (the control plane, and u7s) and `worker.dhall` take their services from
`node-common.dhall`: a worker runs containerd, the kubelet and kube-proxy, and its image carries no CoreDNS and no
cluster bootstrap. A node's identity reaches it in the environment (`NODE_NAME`, `NODE_IP`, `POD_CIDR`); a worker's
kubelet and kube-proxy have their own certificates, signed by the control plane's CA when it joins.

## Just targets

| Target | Description |
|--------|-------------|
| `just up` | Start the node container: a stopped one is started, a missing one created on the state volumes |
| `just down` | Stop the node container gracefully and remove it; the state volumes stay |
| `just restart` | `down` then `up`: apply a newly loaded node image |
| `just reset` | Stop and wipe all state (PKI, etcd, kubelet, images, persistent volumes) |
| `just init` | Generate PKI and kubeconfigs on a fresh cluster, untaint it, prepull images |
| `just kubeconfig` | Extract admin kubeconfig to `./kubeconfig` |
| `just shell` | Open a shell inside the node container |
| `just logs [service...]` | Follow the services' logs (kept in memory by vigild, the last 5000 lines of each) |
| `just status` | Show the services' state (`vigil services list`) and the node's pods |
| `just render` | Render `node.dhall` and `worker.dhall` to `node.nix` and `worker.nix` after changing what a node runs |
| `just cluster-up` / `cluster-down` / `cluster-reset` | Start, stop, or wipe the cluster of `cluster.dhall` |
| `just cluster-init` | Once: the control plane's PKI, the workers joined, labels and taints applied |
| `just cluster-kubeconfig` / `cluster-status` | Write `./kubeconfig-<cluster>`; show the cluster's containers and nodes |

## Architecture

The node is a [nix-container-lib](https://github.com/daveman1010221/nix-container-lib) `System` container: vigild is PID 1 and runs the node's services, with no session (no user, no shell in front, no SSH).

```
node-common.dhall                                 what every node has
├── packages      (a custom layer: containerd, etcd, iproute2, nftables, ...)
├── boot steps    (once at each start: delegate the cgroups, sysctls, the pod masquerade, u7s-prepare)
└── services      (vigild's: containerd, etcd, kube-apiserver, ..., each running /bin/u7s-<service>)
node.dhall    →  just render  →  node.nix         the control plane (and u7s): all of the services
worker.dhall  →  just render  →  worker.nix       a worker: containerd, the kubelet, kube-proxy

flake.nix                                         what those are made of
├── kubernetes  (stdenv.mkDerivation)
│   ├── src: kubernetes-v1.37.1.tar.gz
│   └── buildPhase: go build -mod=vendor CGO_ENABLED=0
├── the services' scripts (/bin/u7s-*), each waiting for what it needs before it starts
└── nodeImage, workerImage  (nix-container-lib mkContainer, from node.nix and worker.nix)
    └── the files a node carries: containerd's, the kubelet's and CNI's configuration (the control plane's: CoreDNS)
```

After changing a `.dhall` file, run `just render` and commit the `.nix` files with it.

**Bootstrap flow (`just init`):**
1. Generate PKI with openssl inside the container
2. Write kubeconfigs for all components
3. The control plane services, each waiting for its files, start on their own; kube-apiserver reads the node's
   address (`NODE_IP`, or the one slirp4netns gives u7s on `tap0`) before every start
4. Wait for apiserver readiness
5. Remove control-plane taint so workloads schedule
6. Prepull the pause image

## Updating Kubernetes versions

1. Update `k8sVersion` in `flake.nix`, and the image tag in `IMAGE` in the `Justfile`
2. Get the new source hash and put it in `k8sSha256`:
   `nix store prefetch-file --json https://github.com/kubernetes/kubernetes/archive/refs/tags/v<version>.tar.gz | jq -r .hash`
3. Check the release's `go.mod` Go version against nixpkgs' `go`, and run `nix flake update` if it is older
4. Check that the flags in the services' scripts (`*Run` in `flake.nix`) still exist: each binary's `--help` lists them

## License

MIT — see [LICENSE](LICENSE)

Original usernetes project: https://github.com/rootless-containers/usernetes
