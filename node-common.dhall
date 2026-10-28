-- node-common.dhall
--
-- What nodes are made of, whatever their role: packages, what a node does once at each start, and the services it may
-- run. Each role picks from here:
--   node.dhall           — the single node of `just up` (u7s): everything
--   control-plane.dhall  — a cluster's control plane: etcd and the control plane, and no kubelet, so no pod runs there
--   worker.dhall         — a cluster's worker: containerd, the kubelet and kube-proxy
--
-- What lives where:
--   here       — what a node runs: its packages, what it does once at each start, its services and their order
--   flake.nix  — what those are made of: Kubernetes built from source, each service's script (/bin/u7s-*), and the
--                files the image carries (containerd's, the kubelet's and CNI's configuration, CoreDNS)

let Lib =
      https://raw.githubusercontent.com/daveman1010221/nix-container-lib/7db6e5d52c28f7bc487c549d204c7a37ce10d431/dhall/prelude.dhall
        sha256:e88446f08eba97c5e8540743a4c0458d3bee5d7debd8e072f9b9ace610abf729

let service = Lib.defaults.defaultService

-- Each service's output is kept in vigild's memory only (`just logs <service>`): podman sends the container's stdout
-- to the host's journal, and the kubelet at --v=2 would fill it.
let quiet = { logs = Lib.ServiceLogs.Disabled }

-- A one-shot: done once it has succeeded, run again when it fails.
let oneShot = { onSuccess = Lib.ServiceExit.Ignore, onFailure = Lib.ServiceExit.Restart }

-- The CNI plugins are not here: they are linked into /opt/cni/bin (flake.nix), and one of them, bridge, is also
-- iproute2's.
let packages =
      { -- every node's
        common =
        [ Lib.nixpkgs "bash"
        , Lib.nixpkgs "curl"
        , Lib.nixpkgs "findutils"
        , Lib.nixpkgs "gnugrep"
        , Lib.nixpkgs "gnused"
        , Lib.nixpkgs "iproute2"
        , Lib.nixpkgs "jq"
        , Lib.nixpkgs "openssl"
        , Lib.nixpkgs "procps"
        , Lib.nixpkgs "util-linux"
        ]
      , -- a node that runs pods
        pods =
        [ Lib.nixpkgs "conntrack-tools"
        , Lib.nixpkgs "containerd"
        , Lib.nixpkgs "cri-tools"
        , Lib.nixpkgs "ethtool"
        , Lib.nixpkgs "iptables"
        , Lib.nixpkgs "kmod"
        , Lib.nixpkgs "nftables"
        , Lib.nixpkgs "runc"
        , Lib.nixpkgs "socat"
        ]
      , -- a node that runs the control plane
        controlPlane = [ Lib.nixpkgs "etcd", Lib.nixpkgs "kubernetes-helm" ]
      }

let boot =
      { -- A node that runs pods: containerd puts every pod's cgroup under the root of the node's own cgroup namespace
        -- (/k8s.io/<id>), and pods are masqueraded by a table, not by CNI's ipMasq, whose nftables backend needs the
        -- `inet` family.
        pods =
        [ Lib.BootStep.DelegateCgroups
        , Lib.BootStep.Sysctls "/etc/sysctl.d/99-u7s.conf"
        , Lib.BootStep.NftRuleset "/etc/u7s/masquerade.nft"
        , Lib.BootStep.Script
            { name = "prepare", command = "/bin/u7s-prepare", required = True }
        ]
      , -- The control plane alone: its name, which its kubeconfigs use, resolves to itself.
        controlPlane =
        [ Lib.BootStep.Script
            { name = "prepare", command = "/bin/u7s-prepare", required = True }
        ]
      }

-- A node of the given name, packages and boot steps, without its services: each role adds the ones it runs.
let base =
      \(name : Text) ->
      \(nodePackages : List Lib.PackageRef) ->
      \(bootSteps : List Lib.BootStep) ->
            Lib.defaults.systemContainer
        //  { name
            , packageLayers =
              [ Lib.PackageLayer.Micro, Lib.customLayer name nodePackages ]
            , extraEnv =
              [ Lib.buildEnv "KUBECONFIG" "/etc/kubernetes/admin.conf"
              , Lib.buildEnv "VIGIL_LOG_BUFFER" "5000"
              ]
            , startup = Some
                { session = Lib.Session.None
                , boot = bootSteps
                , launch = Lib.Launch.System
                }
            }

-- A service starts once those it is `after` are running, not once they are done: what one needs before it can start
-- (its certificates, its kubeconfig, the preloaded images), its script waits for. Ordering only, as systemd's Wants=
-- was: a service that fails is restarted on its own until what it needs answers.
let services =
      { containerd = service // quiet // { name = "containerd", summary = "containerd container runtime", command = "/bin/u7s-containerd", killDelay = Some "10s" }
      , imagePreload = service // quiet // oneShot // { name = "image-preload", summary = "import the bundled images into containerd", command = "/bin/u7s-image-preload", after = [ "containerd" ] }
      , etcd = service // quiet // { name = "etcd", summary = "etcd key-value store", command = "/bin/u7s-etcd", killDelay = Some "10s" }
      , kubeApiserver = service // quiet // { name = "kube-apiserver", summary = "Kubernetes API server", command = "/bin/u7s-kube-apiserver", after = [ "etcd" ], killDelay = Some "10s" }
      , kubeControllerManager = service // quiet // { name = "kube-controller-manager", summary = "Kubernetes controller manager", command = "/bin/u7s-kube-controller-manager", after = [ "kube-apiserver" ] }
      , kubeScheduler = service // quiet // { name = "kube-scheduler", summary = "Kubernetes scheduler", command = "/bin/u7s-kube-scheduler", after = [ "kube-apiserver" ] }
      , kubelet = service // quiet // { name = "kubelet", summary = "kubelet", command = "/bin/u7s-kubelet", after = [ "containerd", "image-preload" ], killDelay = Some "20s" }
      -- After the apiserver where the node runs one (node.dhall); on a worker, its script waits for its kubeconfig.
      , kubeProxy = service // quiet // { name = "kube-proxy", summary = "kube-proxy", command = "/bin/u7s-kube-proxy" }
      , clusterBootstrap = service // quiet // oneShot // { name = "cluster-bootstrap", summary = "apply the cluster's own resources (kube-dns, and a cluster's CoreDNS)", command = "/bin/u7s-cluster-bootstrap", after = [ "kube-apiserver" ] }
      }

in  { Lib, packages, boot, base, services }
