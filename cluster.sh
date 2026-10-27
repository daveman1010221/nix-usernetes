#!/usr/bin/env bash
# cluster.sh — a cluster of nix-usernetes nodes on this host, as cluster.dhall describes it. The Justfile's cluster-*
# recipes run it: up, init, down, reset, kubeconfig, status.
#
# The network. Rootless podman's bridge networks need iptables extensions (xt_comment, xt_nat) or nftables' `inet`
# family, which a kernel without IPv6 does not have, so the cluster brings its own, all inside podman's rootless user
# namespace (`podman unshare`), with no privilege beyond what the user already has there:
#   - the hub, a container on slirp4netns, owns a bridge (10.77.0.1/24). It masquerades the nodes' traffic out through
#     slirp4netns, sends their DNS to the host's resolver (10.0.2.2:5300, as the single node's CoreDNS does), and
#     publishes the control plane's apiserver on the host (cluster.dhall's apiserverPort).
#   - each node has a network namespace of its own, kept on a file under $XDG_RUNTIME_DIR, wired to the bridge by a veth
#     pair (its end is the node's eth0) before the node starts, and joined by the node's container (--network ns:).
#     A node that restarts keeps its network; a hub that restarts takes its ends of the pairs with it, and `up` wires
#     the nodes again.
#   - every node has a route to each other node's pod range through that node, so pods reach each other directly.
#
# Needs: podman, jq, dhall-to-json, and ip, nft, nsenter and unshare on the host (the dev shell has them all).
set -euo pipefail
cd "$(dirname "$0")"

TOPOLOGY=${TOPOLOGY:-cluster.dhall}
CP_IMAGE=${CP_IMAGE:-localhost/nix-usernetes-node:1.37.1}
WORKER_IMAGE=${WORKER_IMAGE:-localhost/nix-usernetes-worker:1.37.1}

BRIDGE_NET=10.77.0      # the hub is .1, the nodes .11, .12, ... in cluster.dhall's order
POD_NET=10.244          # node i has 10.244.i.0/24
HOST_DNS=10.0.2.2:5300  # the host's resolver, as slirp4netns presents it (DNSStubListenerExtra)

TOPO=$(dhall-to-json --file "$TOPOLOGY")
CLUSTER=$(jq -r .name <<<"$TOPO")
PORT=$(jq -r .apiserverPort <<<"$TOPO")
mapfile -t NODES < <(jq -r '.nodes[].name' <<<"$TOPO")
mapfile -t CPS < <(jq -r '.nodes[] | select(.role == "ControlPlane") | .name' <<<"$TOPO")
mapfile -t WORKERS < <(jq -r '.nodes[] | select(.role == "Worker") | .name' <<<"$TOPO")

[ "${#CPS[@]}" -eq 1 ] || { echo "$TOPOLOGY: a cluster has exactly one ControlPlane node (it has ${#CPS[@]})" >&2; exit 1; }
[ "$(printf '%s\n' "${NODES[@]}" | sort -u | wc -l)" -eq "${#NODES[@]}" ] || { echo "$TOPOLOGY: node names repeat" >&2; exit 1; }
[ "${#NODES[@]}" -le 200 ] || { echo "$TOPOLOGY: at most 200 nodes" >&2; exit 1; }
CP=${CPS[0]}

HUB=$CLUSTER-hub
NETNS_DIR=$XDG_RUNTIME_DIR/nix-usernetes/$CLUSTER/netns
KUBECONFIG_OUT=kubeconfig-$CLUSTER

index_of() { local i; for i in "${!NODES[@]}"; do [ "${NODES[$i]}" = "$1" ] && { echo "$i"; return; }; done; return 1; }
node_ip()  { echo "$BRIDGE_NET.$((11 + $(index_of "$1")))"; }
pod_cidr() { echo "$POD_NET.$(index_of "$1").0/24"; }
ctr()      { echo "$CLUSTER-$1"; }
role()     { jq -r --arg n "$1" '.nodes[] | select(.name == $n) | .role' <<<"$TOPO"; }
volumes()  { local v=(pki kubelet containerd local-path); [ "$(role "$1")" = ControlPlane ] && v+=(etcd); printf "$CLUSTER-$1-%s\n" "${v[@]}"; }
state()    { podman container inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo absent; }
cp_kubectl() { podman exec "$(ctr "$CP")" kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"; }

# ── up ───────────────────────────────────────────────────────────────────────────────────────────────────────────────

start_hub() {
    case "$(state "$HUB")" in
        running) return ;;
        absent)  ;;
        *)       podman rm -f "$HUB" >/dev/null ;;
    esac
    echo "Starting the hub ($HUB)."
    # port_handler=slirp4netns: with podman's default handler, a published port bypasses the hub's DNAT. The hub keeps
    # nothing, and its sleep, as PID 1, ignores SIGTERM: it is stopped with SIGKILL.
    podman run -d --rm --name "$HUB" \
        --network slirp4netns:allow_host_loopback=true,port_handler=slirp4netns \
        --publish "$PORT:6443" \
        --stop-signal KILL \
        --entrypoint /bin/sleep "$CP_IMAGE" infinity >/dev/null
}

# The bridge, every node's network namespace and veth pair, their routes, and the hub's NAT, as they should be; what is
# there already is left alone.
wire() {
    local hub_pid spec="" n i
    hub_pid=$(podman inspect -f '{{.State.Pid}}' "$HUB")
    for n in "${NODES[@]}"; do
        i=$(index_of "$n")
        spec+="$n $i $(node_ip "$n") $(pod_cidr "$n")"$'\n'
    done
    podman unshare bash -s "$hub_pid" "$NETNS_DIR" "$BRIDGE_NET" "$(node_ip "$CP")" "$HOST_DNS" "$spec" <<'EOF'
set -euo pipefail
hub_pid=$1 netns_dir=$2 net=$3 cp_ip=$4 host_dns=$5 spec=$6
in_hub() { nsenter --net=/proc/$hub_pid/ns/net "$@"; }

if ! in_hub ip link show br0 >/dev/null 2>&1; then
    in_hub ip link add br0 type bridge
    in_hub ip addr add "$net.1/24" dev br0
    in_hub ip link set br0 up
    in_hub sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
fi

mkdir -p "$netns_dir"
while read -r name i ip cidr; do
    [ -n "$name" ] || continue
    ns=$netns_dir/$name
    if ! nsenter --net="$ns" true 2>/dev/null; then
        touch "$ns"
        unshare --net="$ns" true
    fi
    # A veth pair dies with either end's namespace: no eth0 here means a new namespace, or a hub that restarted.
    if ! nsenter --net="$ns" ip link show eth0 >/dev/null 2>&1; then
        in_hub ip link del "veth$i" 2>/dev/null || true
        in_hub ip link add "veth$i" type veth peer name eth0 netns "$ns"
        in_hub ip link set "veth$i" master br0 up
        nsenter --net="$ns" ip link set lo up
        nsenter --net="$ns" ip link set eth0 up
        nsenter --net="$ns" ip addr add "$ip/24" dev eth0
        nsenter --net="$ns" ip route add default via "$net.1"
        echo "wired $name ($ip, pods $cidr)"
    fi
    while read -r other _ other_ip other_cidr; do
        [ -n "$other" ] && [ "$other" != "$name" ] || continue
        nsenter --net="$ns" ip route replace "$other_cidr" via "$other_ip"
    done <<<"$spec"
done <<<"$spec"

in_hub nft delete table ip u7s-hub 2>/dev/null || true
in_hub nft -f - <<NFT
table ip u7s-hub {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "tap0" tcp dport 6443 dnat to $cp_ip:6443
        ip daddr $net.1 udp dport 53 dnat to $host_dns
        ip daddr $net.1 tcp dport 53 dnat to $host_dns
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $net.0/24 oifname != "br0" masquerade
    }
}
NFT
EOF
}

start_node() {
    local n=$1 c image vols=() v
    c=$(ctr "$n")
    case "$(state "$c")" in
        running) return ;;
        absent)  ;;
        *)       echo "Starting the stopped node $c."; podman start "$c" >/dev/null; return ;;
    esac
    image=$WORKER_IMAGE
    [ "$(role "$n")" = ControlPlane ] && image=$CP_IMAGE
    for v in $(volumes "$n"); do
        case "$v" in
            *-pki)        vols+=(--volume "$v:/etc/kubernetes") ;;
            *-kubelet)    vols+=(--volume "$v:/var/lib/kubelet") ;;
            *-containerd) vols+=(--volume "$v:/var/lib/containerd") ;;
            *-local-path) vols+=(--volume "$v:/opt/local-path-provisioner") ;;
            *-etcd)       vols+=(--volume "$v:/var/lib/etcd") ;;
        esac
    done
    echo "Starting node $c ($(role "$n"), $(node_ip "$n"))."
    # As `just up` runs u7s, but on the node's own network namespace, with the hub as its resolver.
    podman run -d \
        --name "$c" \
        --hostname "$n" \
        --network "ns:$NETNS_DIR/$n" \
        --dns "$BRIDGE_NET.1" \
        --dns-search=. \
        --privileged \
        --pids-limit -1 \
        --cgroupns=private \
        --ipc=host \
        --security-opt seccomp=unconfined \
        --security-opt apparmor=unconfined \
        --tmpfs /run \
        --tmpfs /run/lock \
        --tmpfs /tmp \
        --volume /run/booted-system/kernel-modules/lib/modules:/lib/modules:ro \
        "${vols[@]}" \
        --env NODE_NAME="$n" \
        --env NODE_IP="$(node_ip "$n")" \
        --env POD_CIDR="$(pod_cidr "$n")" \
        "$image" >/dev/null
}

cmd_up() {
    start_hub
    wire
    local n
    for n in "${NODES[@]}"; do start_node "$n"; done
    echo "Cluster '$CLUSTER' is up."
    podman exec "$(ctr "$CP")" test -f /etc/kubernetes/admin.conf 2>/dev/null || echo "Next, once: just cluster-init"
}

# ── init ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

# A kubeconfig for a client certificate the control plane's CA signed, written into a node.
write_kubeconfig() {
    local node_ctr=$1 dest=$2 user=$3 dir=$4 name=$5 server=$6 ca cert key
    ca=$(podman exec "$(ctr "$CP")" base64 -w0 /etc/kubernetes/pki/ca.crt)
    cert=$(podman exec "$(ctr "$CP")" base64 -w0 "$dir/$name.crt")
    key=$(podman exec "$(ctr "$CP")" base64 -w0 "$dir/$name.key")
    podman exec -i "$node_ctr" sh -c "cat > $dest" <<YAML
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $ca
    server: $server
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: $user
  name: $user@kubernetes
current-context: $user@kubernetes
users:
- name: $user
  user:
    client-certificate-data: $cert
    client-key-data: $key
YAML
}

# A worker's credentials: the kubelet's, as the node it is (system:node:<name>, which the Node authorizer and
# NodeRestriction hold to that node), and kube-proxy's (system:kube-proxy). Signed by the control plane's CA, kept on
# its volume (pki/nodes/<name>), and written into the worker as kubeconfigs that reach the apiserver at its address.
join_worker() {
    local w=$1 c dir=/etc/kubernetes/pki/nodes/$1 server
    c=$(ctr "$w")
    server="https://$(node_ip "$CP"):6443"
    if podman exec "$c" test -f /etc/kubernetes/kubelet.conf 2>/dev/null; then
        echo "$w has joined already, skipping."
        return
    fi
    echo "Joining $w."
    podman exec "$(ctr "$CP")" bash -euc '
        dir=$1 node=$2
        mkdir -p "$dir"
        issue() {
            openssl genrsa -out "$dir/$1.key" 2048 2>/dev/null
            openssl req -new -key "$dir/$1.key" -subj "/CN=$2/O=$3" -out "$dir/$1.csr"
            openssl x509 -req -in "$dir/$1.csr" -CA /etc/kubernetes/pki/ca.crt -CAkey /etc/kubernetes/pki/ca.key \
                -CAcreateserial -days 3650 -extfile <(printf "extendedKeyUsage=clientAuth") -out "$dir/$1.crt" 2>/dev/null
            rm -f "$dir/$1.csr"
        }
        issue kubelet "system:node:$node" system:nodes
        issue kube-proxy system:kube-proxy system:node-proxier
    ' _ "$dir" "$w"
    podman exec "$(ctr "$CP")" cat /etc/kubernetes/pki/ca.crt | podman exec -i "$c" sh -c 'cat > /etc/kubernetes/pki/ca.crt'
    write_kubeconfig "$c" /etc/kubernetes/kube-proxy.conf system:kube-proxy "$dir" kube-proxy "$server"
    # Last: the kubelet waits for this file, and its being there is what makes this worker joined.
    write_kubeconfig "$c" /etc/kubernetes/kubelet.conf "system:node:$w" "$dir" kubelet "$server"
}

# The node-role label kubectl shows, and cluster.dhall's labels and taints. A kubelet may not set node-role labels on
# its own node (NodeRestriction), so all of them are set here.
apply_topology() {
    local n r k v t
    for n in "${NODES[@]}"; do
        r=$(role "$n")
        r=${r/ControlPlane/control-plane}; r=${r/Worker/worker}
        cp_kubectl label node "$n" --overwrite "node-role.kubernetes.io/$r=" >/dev/null
        while IFS=$'\t' read -r k v; do
            [ -n "$k" ] && cp_kubectl label node "$n" --overwrite "$k=$v" >/dev/null
        done < <(jq -r --arg n "$n" '.nodes[] | select(.name == $n) | .labels | to_entries[] | [.key, .value] | @tsv' <<<"$TOPO")
        while read -r t; do
            [ -n "$t" ] && cp_kubectl taint node "$n" --overwrite "$t" >/dev/null
        done < <(jq -r --arg n "$n" '.nodes[] | select(.name == $n) | .taints[] | "\(.key)=\(.value):\(.effect)"' <<<"$TOPO")
    done
    echo "Labels and taints applied."
}

wait_for_nodes() {
    local n i
    for n in "${NODES[@]}"; do
        for i in $(seq 1 60); do
            cp_kubectl get node "$n" >/dev/null 2>&1 && break
            [ "$i" -eq 60 ] && { echo "Node $n did not register. Check: just cluster-status, podman exec $(ctr "$n") vigil logs kubelet" >&2; exit 1; }
            sleep 3
        done
    done
    echo "All nodes registered."
}

cmd_init() {
    local n
    for n in "${NODES[@]}"; do
        [ "$(state "$(ctr "$n")")" = running ] || { echo "Node $(ctr "$n") is not running. Run 'just cluster-up' first." >&2; exit 1; }
    done
    just _gen-pki "$(ctr "$CP")" "$CP"
    just _gen-configs "$(ctr "$CP")" "$CP"
    for n in "${WORKERS[@]}"; do join_worker "$n"; done
    for n in "${NODES[@]}"; do just _prepull-images "$(ctr "$n")"; done
    wait_for_nodes
    apply_topology
    echo ""
    echo "✓ Cluster '$CLUSTER' initialised. Run 'just cluster-kubeconfig', then:"
    echo "  export KUBECONFIG=$(pwd)/$KUBECONFIG_OUT"
    echo "  kubectl get nodes -o wide"
}

# ── the rest ─────────────────────────────────────────────────────────────────────────────────────────────────────────

cmd_kubeconfig() {
    podman exec "$(ctr "$CP")" cat /etc/kubernetes/admin.conf \
        | sed "s|https://$CP:6443|https://127.0.0.1:$PORT|" > "$KUBECONFIG_OUT"
    echo "export KUBECONFIG=$(pwd)/$KUBECONFIG_OUT"
}

cmd_down() {
    local n c
    for n in "${NODES[@]}"; do
        c=$(ctr "$n")
        podman stop --time 30 "$c" >/dev/null 2>&1 || true
        podman rm "$c" >/dev/null 2>&1 || true
    done
    podman stop --time 2 "$HUB" >/dev/null 2>&1 || true
    podman unshare sh -c 'for f in "$1"/*; do [ -e "$f" ] || continue; umount "$f" 2>/dev/null || true; rm -f "$f"; done' _ "$NETNS_DIR"
    echo "Cluster '$CLUSTER' is down. Its state stays on its volumes."
}

cmd_reset() {
    cmd_down
    local n
    for n in "${NODES[@]}"; do
        # shellcheck disable=SC2046
        podman volume rm -f $(volumes "$n") >/dev/null 2>&1 || true
    done
    rm -f "$KUBECONFIG_OUT"
    echo "Cluster '$CLUSTER' wiped. Next: just cluster-up && just cluster-init"
}

cmd_status() {
    podman ps -a --filter "name=^$CLUSTER-" --format 'table {{.Names}}\t{{.Status}}'
    echo ""
    cp_kubectl get nodes -o wide 2>/dev/null || echo "(the control plane's apiserver does not answer)"
}

case "${1:-}" in
    up)         cmd_up ;;
    init)       cmd_init ;;
    down)       cmd_down ;;
    reset)      cmd_reset ;;
    kubeconfig) cmd_kubeconfig ;;
    status)     cmd_status ;;
    *)          echo "usage: $0 up|init|down|reset|kubeconfig|status" >&2; exit 2 ;;
esac
