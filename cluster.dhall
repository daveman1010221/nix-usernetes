-- cluster.dhall
--
-- A cluster of nix-usernetes nodes on this host: one control plane and any number of workers, each its own container.
--   just cluster-up      — the hub, the nodes' network, the nodes
--   just cluster-init    — the control plane's PKI, the workers joined, labels and taints applied (once, and again
--                          after adding a node)
--   just cluster-kubeconfig
-- The single node of `just up` (u7s) is separate, and the two can run side by side.
--
-- Each node gets an address on the hub's bridge (10.77.0.11 for the first, then .12, ...) and a /24 of the cluster's
-- pod range in the same order (10.244.0.0/24, 10.244.1.0/24, ...), so changing the order of the nodes renumbers them:
-- add a node at the end, or `just cluster-reset` after reordering.
--
-- Labels and taints are applied by `just cluster-init`, which may be run again, after adding a node or changing them;
-- one removed from here stays on its node until the cluster is reset (or `kubectl label/taint ...-` removes it).

let Role = < ControlPlane | Worker >

let Effect = < NoSchedule | PreferNoSchedule | NoExecute >

let Taint = { key : Text, value : Text, effect : Effect }

let Labels = List { mapKey : Text, mapValue : Text }

let Node = { name : Text, role : Role, labels : Labels, taints : List Taint }

let node =
      \(name : Text) ->
      \(role : Role) ->
        { name, role, labels = [] : Labels, taints = [] : List Taint } : Node

-- Polar's placement. Each worker is one pool, named on the node by the label polar.dev/pool=<pool>. A dedicated pool's
-- node is also tainted polar.dev/pool=<pool>:NoSchedule, so it runs only the pods that ask for it: a nodeSelector on
-- the label and a toleration of the taint. The open pool's node has no taint, and is where everything that does not
-- ask for a pool runs.
let poolKey = "polar.dev/pool"

let pool =
      \(name : Text) ->
          node name Role.Worker
        // { labels = [ { mapKey = poolKey, mapValue = name } ] }

let dedicatedPool =
      \(name : Text) ->
            pool name
        //  { taints =
              [ { key = poolKey, value = name, effect = Effect.NoSchedule } ]
            }

in  { -- the containers are <name>-<node> (and <name>-hub), the volumes <name>-<node>-<what>
      name = "u7c"
    -- the host's port for the control plane's apiserver; u7s has 6443
    , apiserverPort = 7443
    , nodes =
      [ -- Kubernetes' own: CoreDNS (a static pod) and what tolerates the control plane's taint
        node "cp" Role.ControlPlane
        // { taints =
             [ { key = "node-role.kubernetes.io/control-plane"
               , value = ""
               , effect = Effect.NoSchedule
               }
             ]
           }
      , -- Polar's core: the credentials agent, the cert issuer, cassini
        dedicatedPool "core"
      , -- the low-trust side: the observers
        dedicatedPool "observers"
      , -- the high-trust side: what writes the graph
        dedicatedPool "writers"
      , -- the rest, which Polar relies on but is not Polar proper (Flux, the registry, Keycloak, ...)
        pool "services"
      ]
    }
