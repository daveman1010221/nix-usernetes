-- cluster.dhall
--
-- A cluster of nix-usernetes nodes on this host: one control plane and any number of workers, each its own container.
--   just cluster-up      — the hub, the nodes' network, the nodes
--   just cluster-init    — the control plane's PKI, the workers joined, labels and taints applied (once)
--   just cluster-kubeconfig
-- The single node of `just up` (u7s) is separate, and the two can run side by side.
--
-- Each node gets an address on the hub's bridge (10.77.0.11 for the first, then .12, ...) and a /24 of the cluster's
-- pod range in the same order (10.244.0.0/24, 10.244.1.0/24, ...), so changing the order of the nodes renumbers them:
-- add a node at the end, or `just cluster-reset` after reordering.

let Role = < ControlPlane | Worker >

let Effect = < NoSchedule | PreferNoSchedule | NoExecute >

let Taint = { key : Text, value : Text, effect : Effect }

let Labels = List { mapKey : Text, mapValue : Text }

let Node = { name : Text, role : Role, labels : Labels, taints : List Taint }

let node =
      \(name : Text) ->
      \(role : Role) ->
        { name, role, labels = [] : Labels, taints = [] : List Taint } : Node

in  { -- the containers are <name>-<node> (and <name>-hub), the volumes <name>-<node>-<what>
      name = "u7c"
    -- the host's port for the control plane's apiserver; u7s has 6443
    , apiserverPort = 7443
    , nodes =
      [ node "cp" Role.ControlPlane
      , node "core" Role.Worker // { labels = toMap { pool = "core" } }
      ]
    }
