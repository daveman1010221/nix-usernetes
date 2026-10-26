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
| `just render` | Render `node.dhall` to `node.nix` after changing what the node runs |

## Architecture

The node is a [nix-container-lib](https://github.com/daveman1010221/nix-container-lib) `System` container: vigild is PID 1 and runs the node's services, with no session (no user, no shell in front, no SSH).

```
node.dhall  →  just render  →  node.nix          what the node runs
├── packages      (a custom layer: containerd, etcd, iproute2, nftables, ...)
├── boot steps    (once at each start: delegate the cgroups, sysctls, the pod masquerade, u7s-prepare)
└── services      (vigild's: containerd, etcd, kube-apiserver, ..., each running /bin/u7s-<service>)

flake.nix                                         what those are made of
├── kubernetes  (stdenv.mkDerivation)
│   ├── src: kubernetes-v1.37.1.tar.gz
│   └── buildPhase: go build -mod=vendor CGO_ENABLED=0
├── the services' scripts (/bin/u7s-*), each waiting for what it needs before it starts
└── nodeImage  (nix-container-lib mkContainer, from node.nix)
    └── the files the node carries: containerd's, the kubelet's and CNI's configuration, CoreDNS
```

After changing `node.dhall`, run `just render` and commit `node.nix` with it.

**Bootstrap flow (`just init`):**
1. Generate PKI with openssl inside the container
2. Write kubeconfigs for all components
3. The control plane services, each waiting for its files, start on their own; kube-apiserver reads the node's
   address from `tap0` before every start
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
