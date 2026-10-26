-- node.dhall
--
-- The node container: a nix-container-lib System container. vigild is PID 1 and runs the node's services; there is no
-- session (no user, no shell in front, no SSH).
--
-- Render after every change, and commit node.nix with it (nix build reads node.nix, not this file):
--   just render
--
-- What lives where:
--   here       — what the node runs: its packages, what it does once at each start, its services and their order
--   flake.nix  — what those are made of: Kubernetes built from source, each service's script (/bin/u7s-*), and the
--                files the image carries (containerd's, the kubelet's and CNI's configuration, CoreDNS)

let Lib =
      https://raw.githubusercontent.com/daveman1010221/nix-container-lib/6c86c19101123245354a39bbf571b6f100770dc1/dhall/prelude.dhall
        sha256:e88446f08eba97c5e8540743a4c0458d3bee5d7debd8e072f9b9ace610abf729

let service = Lib.defaults.defaultService

-- Each service's output is kept in vigild's memory only (`just logs <service>`): podman sends the container's stdout
-- to the host's journal, and the kubelet at --v=2 would fill it.
let quiet = { logs = Lib.ServiceLogs.Disabled }

-- A one-shot: done once it has succeeded, run again when it fails.
let oneShot = { onSuccess = Lib.ServiceExit.Ignore, onFailure = Lib.ServiceExit.Restart }

-- The CNI plugins are not here: they are linked into /opt/cni/bin (flake.nix), and one of them, bridge, is also
-- iproute2's.
let nodePackages =
      Lib.customLayer
        "node"
        [ Lib.nixpkgs "bash"
        , Lib.nixpkgs "conntrack-tools"
        , Lib.nixpkgs "containerd"
        , Lib.nixpkgs "cri-tools"
        , Lib.nixpkgs "curl"
        , Lib.nixpkgs "etcd"
        , Lib.nixpkgs "ethtool"
        , Lib.nixpkgs "findutils"
        , Lib.nixpkgs "gnugrep"
        , Lib.nixpkgs "gnused"
        , Lib.nixpkgs "iproute2"
        , Lib.nixpkgs "iptables"
        , Lib.nixpkgs "jq"
        , Lib.nixpkgs "kmod"
        , Lib.nixpkgs "kubernetes-helm"
        , Lib.nixpkgs "nftables"
        , Lib.nixpkgs "openssl"
        , Lib.nixpkgs "procps"
        , Lib.nixpkgs "runc"
        , Lib.nixpkgs "socat"
        , Lib.nixpkgs "util-linux"
        ]

in  Lib.defaults.systemContainer
    //  { name = "nix-usernetes-node"
        , packageLayers = [ Lib.PackageLayer.Micro, nodePackages ]
        , extraEnv =
          [ Lib.buildEnv "KUBECONFIG" "/etc/kubernetes/admin.conf"
          , Lib.buildEnv "VIGIL_LOG_BUFFER" "5000"
          ]
        , startup = Some
            { session = Lib.Session.None
            , boot =
              -- containerd puts every pod's cgroup under the root of the node's own cgroup namespace (/k8s.io/<id>).
              [ Lib.BootStep.DelegateCgroups
              , Lib.BootStep.Sysctls "/etc/sysctl.d/99-u7s.conf"
              -- Pods are masqueraded by this table, not by CNI's ipMasq, whose nftables backend needs the `inet` family.
              , Lib.BootStep.NftRuleset "/etc/u7s/masquerade.nft"
              , Lib.BootStep.Script
                  { name = "prepare", command = "/bin/u7s-prepare", required = True }
              ]
            , launch = Lib.Launch.System
            }
        -- A service starts once those it is `after` are running, not once they are done: what one needs before it
        -- can start (its certificates, its kubeconfig, the preloaded images), its script waits for. Ordering only,
        -- as systemd's Wants= was: a service that fails is restarted on its own until what it needs answers.
        , services =
          [ service // quiet // { name = "containerd", summary = "containerd container runtime", command = "/bin/u7s-containerd", killDelay = Some "10s" }
          , service // quiet // oneShot // { name = "image-preload", summary = "import the bundled images into containerd", command = "/bin/u7s-image-preload", after = [ "containerd" ] }
          , service // quiet // { name = "etcd", summary = "etcd key-value store", command = "/bin/u7s-etcd", killDelay = Some "10s" }
          , service // quiet // { name = "kube-apiserver", summary = "Kubernetes API server", command = "/bin/u7s-kube-apiserver", after = [ "etcd" ], killDelay = Some "10s" }
          , service // quiet // { name = "kube-controller-manager", summary = "Kubernetes controller manager", command = "/bin/u7s-kube-controller-manager", after = [ "kube-apiserver" ] }
          , service // quiet // { name = "kube-scheduler", summary = "Kubernetes scheduler", command = "/bin/u7s-kube-scheduler", after = [ "kube-apiserver" ] }
          , service // quiet // { name = "kubelet", summary = "kubelet", command = "/bin/u7s-kubelet", after = [ "containerd", "image-preload" ], killDelay = Some "20s" }
          , service // quiet // { name = "kube-proxy", summary = "kube-proxy", command = "/bin/u7s-kube-proxy", after = [ "kube-apiserver" ] }
          , service // quiet // oneShot // { name = "cluster-bootstrap", summary = "apply the kube-dns Service", command = "/bin/u7s-cluster-bootstrap", after = [ "kube-apiserver" ] }
          ]
        }
