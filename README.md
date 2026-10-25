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
- **etcd** — from nixpkgs, run as a native systemd unit
- **containerd, runc, cri-tools, cni-plugins** — from nixpkgs
- **systemd as PID 1** — required for proper cgroup management inside the container

All control plane components (etcd, kube-apiserver, kube-controller-manager, kube-scheduler) run as **native systemd units** using the Nix-built binaries already in the image. No container image pulls, no pause images, no in-cluster CNI required for the control plane.

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

PKI and state persist in named podman volumes. No need to re-init:

```bash
just up
just kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

### Tear down

```bash
just down        # stop container, preserve state volumes
just reset       # stop container and wipe all state
```

## Just targets

| Target | Description |
|--------|-------------|
| `just up` | Start the node container |
| `just down` | Stop the node container gracefully |
| `just reset` | Stop and wipe all state (PKI, etcd data, kubelet state) |
| `just init` | Generate PKI, kubeconfigs, start control plane services |
| `just kubeconfig` | Extract admin kubeconfig to `./kubeconfig` |
| `just shell` | Open a shell inside the node container |
| `just logs` | Follow container logs |
| `just status` | Show systemd unit status inside the container |

## Architecture

```
flake.nix
├── kubernetes  (stdenv.mkDerivation)
│   ├── src: kubernetes-v1.37.1.tar.gz
│   └── buildPhase: go build -mod=vendor CGO_ENABLED=0
│
└── nodeImage  (dockerTools.buildLayeredImage)
    ├── systemd as PID 1
    ├── containerd + runc + cri-tools
    ├── etcd (nixpkgs)
    ├── kubernetes binaries
    └── systemd units for all control plane components
```

**Bootstrap flow (`just init`):**
1. Generate PKI with openssl inside the container
2. Write kubeconfigs for all components
3. Patch the kube-apiserver unit with the host IP address
4. `systemctl restart` all control plane services
5. Wait for apiserver readiness
6. Remove control-plane taint so workloads schedule

## Updating Kubernetes versions

1. Update `k8sVersion` in `flake.nix`, and the image tag in `IMAGE` in the `Justfile`
2. Get the new source hash and put it in `k8sSha256`:
   `nix store prefetch-file --json https://github.com/kubernetes/kubernetes/archive/refs/tags/v<version>.tar.gz | jq -r .hash`
3. Check the release's `go.mod` Go version against nixpkgs' `go`, and run `nix flake update` if it is older
4. Check that the flags in the systemd units still exist: each binary's `--help` lists them

## License

MIT — see [LICENSE](LICENSE)

Original usernetes project: https://github.com/rootless-containers/usernetes
