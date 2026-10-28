-- worker.dhall
--
-- A worker node of a cluster (cluster.dhall): the kubelet and kube-proxy, on containerd, joined to the control plane's
-- apiserver. No etcd and no control plane. It carries the CoreDNS image, for whichever worker the cluster's CoreDNS is
-- scheduled on. What every node is made of is in node-common.dhall.
--
-- Render after every change here or in node-common.dhall, and commit worker.nix with it:
--   just render

let Node = ./node-common.dhall

let p = Node.packages

let s = Node.services

in      Node.base "nix-usernetes-worker" (p.common # p.pods) Node.boot.pods
    //  { services = [ s.containerd, s.imagePreload, s.kubelet, s.kubeProxy ] }
