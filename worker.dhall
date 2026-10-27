-- worker.dhall
--
-- A worker node of a cluster (cluster.dhall): the kubelet and kube-proxy, on containerd, joined to the control plane's
-- apiserver. No etcd, no control plane, no CoreDNS (it runs on the control plane). What every node has is in
-- node-common.dhall.
--
-- Render after every change here or in node-common.dhall, and commit worker.nix with it:
--   just render

let Node = ./node-common.dhall

let s = Node.services

in      Node.base
    //  { name = "nix-usernetes-worker"
        , services = [ s.containerd, s.imagePreload, s.kubelet, s.kubeProxy ]
        }
