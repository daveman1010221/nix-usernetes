-- node.dhall
--
-- The control-plane node: the single node of `just up`, and the `ControlPlane` node of a cluster (cluster.dhall). A
-- nix-container-lib System container: vigild is PID 1 and runs the node's services; there is no session (no user, no
-- shell in front, no SSH). What every node has is in node-common.dhall; a worker's services are in worker.dhall.
--
-- Render after every change here or in node-common.dhall, and commit node.nix and worker.nix with it (nix build reads
-- those, not these files):
--   just render

let Node = ./node-common.dhall

let s = Node.services

in      Node.base
    //  { name = "nix-usernetes-node"
        , services =
          [ s.containerd
          , s.imagePreload
          , s.etcd
          , s.kubeApiserver
          , s.kubeControllerManager
          , s.kubeScheduler
          , s.kubelet
          , s.kubeProxy // { after = [ "kube-apiserver" ] }
          , s.clusterBootstrap
          ]
        }
