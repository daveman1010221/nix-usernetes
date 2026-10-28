-- node.dhall
--
-- The single node of `just up` (u7s): the control plane and the pods on one node. A nix-container-lib System container:
-- vigild is PID 1 and runs the node's services; there is no session (no user, no shell in front, no SSH). What every
-- node is made of is in node-common.dhall; a cluster's roles are control-plane.dhall and worker.dhall.
--
-- Render after every change here or in node-common.dhall, and commit the .nix files with it (nix build reads those,
-- not these files):
--   just render

let Node = ./node-common.dhall

let p = Node.packages

let s = Node.services

in      Node.base "nix-usernetes-node" (p.common # p.pods # p.controlPlane) Node.boot.pods
    //  { services =
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
