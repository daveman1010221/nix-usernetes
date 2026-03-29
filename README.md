# nix-usernetes

A Nix-native, rootless, single-node Kubernetes cluster for NixOS developer workstations.

Built as a replacement for [`kindest/node`](https://github.com/rootless-containers/usernetes) that works on systems where every filesystem is f2fs — which the upstream cAdvisor vendored in `kindest/node` does not support.

## Why this exists

The upstream `kindest/node` embeds a kubelet whose vendored cAdvisor hardcodes a `supportedFsType` map that does not include `f2fs`. On a NixOS host with full-disk LUKS+LVM+f2fs encryption, kubelet crashes immediately:

```
failed to get rootfs info: failed to get mount point for device
"/dev/mapper/nix-home": no partition info for device
```

The fix is a one-line change (`"f2fs": true`) that hasn't propagated into any upstream release. Rather than wait, this project builds all Kubernetes components from source in Nix with the patch applied.

## What it builds

A layered OCI container image containing:

- **kubelet, kube-apiserver, kube-controller-manager, kube-scheduler, kubectl, kube-proxy** — built from source at K8s 1.33.10
- **Patched cAdvisor** — vendored into kubelet via source tree injection; fork at [`daveman1010221/cadvisor@v0.52.2-f2fs`](https://github.com/daveman1010221/cadvisor/tree/fix-f2fs-v0.52.1)
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
├── kubernetesPatched  (stdenv.mkDerivation)
│   ├── src: kubernetes-v1.33.10.tar.gz
│   ├── cadvisorPatchedSrc: daveman1010221/cadvisor@v0.52.2-f2fs
│   ├── configurePhase: replaces vendor/github.com/google/cadvisor/
│   └── buildPhase: go build -mod=vendor CGO_ENABLED=0
│
└── nodeImage  (dockerTools.buildLayeredImage)
    ├── systemd as PID 1
    ├── containerd + runc + cri-tools
    ├── etcd (nixpkgs)
    ├── kubernetesPatched binaries
    └── systemd units for all control plane components
```

**Bootstrap flow (`just init`):**
1. Generate PKI with openssl inside the container
2. Write kubeconfigs for all components
3. Patch the kube-apiserver unit with the host IP address
4. `systemctl restart` all control plane services
5. Wait for apiserver readiness
6. Remove control-plane taint so workloads schedule

## Patched cAdvisor

K8s 1.33 vendors cAdvisor at `v0.52.1`. The patch adds `"f2fs": true` to the `supportedFsType` map in `fs/fs.go`. The patched fork is at [`daveman1010221/cadvisor`](https://github.com/daveman1010221/cadvisor), branch `fix-f2fs-v0.52.1`, tag `v0.52.2-f2fs`.

The vendor injection keeps the declared version at `v0.52.1` in both `go.mod` and `vendor/modules.txt` — Go's `-mod=vendor` only validates version string consistency, not file content hashes.

## Updating Kubernetes versions

1. Update `k8sVersion` in `flake.nix`
2. Run `./prefetch-hashes.sh` to get new SHA256 values
3. Check the vendored cAdvisor version: `grep cadvisor go.mod`
4. If changed, rebase the cAdvisor fork and update `cadvisorForkRev`

## License

MIT — see [LICENSE](LICENSE)

Original usernetes project: https://github.com/rootless-containers/usernetes
