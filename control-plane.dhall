-- control-plane.dhall
--
-- A cluster's control plane (cluster.dhall's ControlPlane node): etcd, the apiserver, the controller manager and the
-- scheduler, and nothing that runs pods. It has no containerd, no kubelet and no kube-proxy, so it is no Kubernetes
-- node: no pod runs beside etcd and the cluster's CA, whatever it tolerates. Its cluster-bootstrap applies CoreDNS,
-- which runs on a worker. What every node is made of is in node-common.dhall.
--
-- Render after every change here or in node-common.dhall, and commit control-plane.nix with it:
--   just render

let Node = ./node-common.dhall

let p = Node.packages

let s = Node.services

in      Node.base
          "nix-usernetes-control-plane"
          (p.common # p.controlPlane)
          Node.boot.controlPlane
    //  { services =
          [ s.etcd
          , s.kubeApiserver
          , s.kubeControllerManager
          , s.kubeScheduler
          , s.clusterBootstrap
          ]
        }
