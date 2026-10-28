# nix-usernetes Justfile
# Single-node rootless Kubernetes for a developer workstation.
# Start it when you need it. Stop it when you don't.
#
# Prerequisites: podman, just, openssl, jq
#
# Quickstart:
#   nix build .#node-image -o result-node-image
#   just load-node-image
#   just up
#   just init
#   just kubeconfig
#   export KUBECONFIG=$(pwd)/kubeconfig
#
# CoreDNS is baked into the node image and starts automatically as a static
# pod. No manual DNS setup is required after `just init`.
#
# cert-manager is a Polar concern, not cluster infrastructure. Install it
# from the Polar project context:
#   just install-cert-manager   # run from this directory before deploying Polar

# ── configuration ─────────────────────────────────────────────────────────────

IMAGE        := "localhost/nix-usernetes-node:1.37.1"
CONTAINER    := "u7s"
NODE_NAME    := "u7s-node"
POD_SUBNET   := "10.244.0.0/16"
SVC_SUBNET   := "10.96.0.0/16"

PORT_APISERVER := "6443"
PORT_ETCD      := "2379"
PORT_KUBELET   := "10250"

# ── core lifecycle ────────────────────────────────────────────────────────────

# Start the node container. Idempotent: a running node is left alone, a stopped one (after the host rebooted) is started,
# and a missing one is created on the existing state volumes. Everything the cluster keeps is on a volume, so a node
# container that was removed (`just down`, or by hand) comes back as it was, persistent volumes included.
# --dns-search=. keeps the host's search domain out of the node's resolv.conf. Kubelet copies that file into every pod,
# and with ndots:5 a host domain (a corporate or wifi one) is tried before the real name; when the host's resolver does
# not answer it, every lookup waits out CoreDNS's 5 s upstream timeout and clients with shorter budgets give up.
up:
    #!/usr/bin/env bash
    set -euo pipefail
    state=$(podman container inspect --format '{{{{.State.Status}}' {{CONTAINER}} 2>/dev/null || echo absent)
    case "$state" in
        running) echo "Container '{{CONTAINER}}' already running."; exit 0 ;;
        absent)  ;;
        *)       echo "Starting the stopped container '{{CONTAINER}}' ($state)."; exec podman start {{CONTAINER}} ;;
    esac
    podman run -d \
        --name {{CONTAINER}} \
        --hostname {{NODE_NAME}} \
        --network slirp4netns:allow_host_loopback=true \
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
        --publish {{PORT_APISERVER}}:{{PORT_APISERVER}} \
        --publish {{PORT_ETCD}}:{{PORT_ETCD}} \
        --publish {{PORT_KUBELET}}:{{PORT_KUBELET}} \
        --volume /run/booted-system/kernel-modules/lib/modules:/lib/modules:ro \
        --volume u7s-pki:/etc/kubernetes \
        --volume u7s-etcd:/var/lib/etcd \
        --volume u7s-kubelet:/var/lib/kubelet \
        --volume u7s-containerd:/var/lib/containerd \
        --volume u7s-local-path:/opt/local-path-provisioner \
        --env NODE_NAME={{NODE_NAME}} \
        {{IMAGE}}

# Stop the node container gracefully and remove it. The cluster's state stays on the volumes.
down:
    podman stop --time 30 {{CONTAINER}} 2>/dev/null || true
    podman rm {{CONTAINER}} 2>/dev/null || true

# Recreate the node container on the same state: how a newly loaded node image takes effect. For a newer Kubernetes
# minor version than one up from the cluster's, use `reset` instead: the control plane and etcd go one minor at a time.
restart: down up

# Stop and wipe all state, persistent volumes included. Next `just up && just init` starts fresh.
reset: down
    podman volume rm -f u7s-pki u7s-etcd u7s-kubelet u7s-containerd u7s-local-path 2>/dev/null || true
    rm -f kubeconfig
    @echo "State wiped. Run 'just up && just init' to start fresh."

# Follow a service's log (`just logs kubelet`), or every service's with none given. vigild keeps the last 5000 lines of
# each in memory; `podman logs` has only vigild's own messages (services starting, exiting, being restarted).
logs *services:
    podman exec -it {{CONTAINER}} vigil logs -f {{services}}

# Open a shell inside the node.
shell:
    podman exec -it {{CONTAINER}} bash

# Show status of Kubernetes components inside the node.
status:
    @echo "=== services ==="
    podman exec {{CONTAINER}} vigil services list || true
    @echo ""
    @echo "=== static pods ==="
    podman exec {{CONTAINER}} \
        crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods 2>/dev/null || true

# ── cluster bootstrap (run once after first `just up`) ───────────────────────

# Generate PKI, configs, and static pod manifests. Safe to re-run.
# CoreDNS starts automatically via static pod — no manual DNS setup needed.
# cert-manager is NOT installed here — it is a Polar concern.
# Run `just install-cert-manager` separately before deploying Polar.
init: _gen-pki _gen-configs _untaint _prepull-images
    @echo ""
    @echo "✓ Cluster initialised. Run 'just kubeconfig' then:"
    @echo "  export KUBECONFIG=$(pwd)/kubeconfig"
    @echo "  kubectl get pods -A"
    @echo ""
    @echo "CoreDNS will start automatically as a static pod."
    @echo "Run 'just install-cert-manager' before deploying Polar."

# Extract kubeconfig (replaces node name with 127.0.0.1 for local access).
kubeconfig: _check-running
    podman exec {{CONTAINER}} \
        sed "s/{{NODE_NAME}}/127.0.0.1/g" /etc/kubernetes/admin.conf > kubeconfig
    @echo "export KUBECONFIG=$(pwd)/kubeconfig"

# ── private bootstrap steps ──────────────────────────────────────────────────

_check-running container=CONTAINER:
    @podman inspect {{container}} --format '{{{{.State.Running}}}}' 2>/dev/null \
        | grep -q true \
        || (echo "Container '{{container}}' is not running. Run 'just up' first." && exit 1)

# Generate all PKI certificates into the node's pki volume (/etc/kubernetes/pki): u7s's, or a cluster's control plane's
# (cluster.sh).
_gen-pki container=CONTAINER node=NODE_NAME: (_check-running container)
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{container}} test -f /etc/kubernetes/pki/ca.crt 2>/dev/null; then
        echo "PKI already exists, skipping."
        exit 0
    fi
    CONTAINER_IP=$(podman exec {{container}} u7s-node-ip)
    echo "Generating PKI..."
    podman exec --env CONTAINER_IP="$CONTAINER_IP" --env NODE_NAME={{node}} {{container}} bash -euc '
        set -euo pipefail
        mkdir -p /etc/kubernetes/pki/etcd

        CONTAINER_IP="$CONTAINER_IP"
        NODE_NAME="$NODE_NAME"
        APISERVER_PORT="{{PORT_APISERVER}}"

        gen_ca() {
            local dir="$1" name="$2"
            openssl genrsa -out "${dir}/${name}.key" 4096
            openssl req -x509 -new -nodes \
                -key "${dir}/${name}.key" \
                -subj "/CN=${name}" \
                -days 3650 \
                -out "${dir}/${name}.crt"
        }

        gen_cert() {
            local ca_dir="$1" ca_name="$2" dir="$3" name="$4" cn="$5" san="$6"
            openssl genrsa -out "${dir}/${name}.key" 2048
            openssl req -new \
                -key "${dir}/${name}.key" \
                -subj "/CN=${cn}/O=system:masters" \
                -out "${dir}/${name}.csr"
            openssl x509 -req -in "${dir}/${name}.csr" \
                -CA "${ca_dir}/${ca_name}.crt" \
                -CAkey "${ca_dir}/${ca_name}.key" \
                -CAcreateserial \
                -days 3650 \
                -extfile <(printf "%s" "${san}") \
                -out "${dir}/${name}.crt"
            rm -f "${dir}/${name}.csr"
        }

        # ── CA certs ──────────────────────────────────────────────────
        gen_ca /etc/kubernetes/pki ca
        gen_ca /etc/kubernetes/pki/etcd ca
        gen_ca /etc/kubernetes/pki front-proxy-ca

        # ── apiserver cert ────────────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki apiserver kube-apiserver \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:127.0.0.1,IP:10.96.0.1,IP:${CONTAINER_IP}"

        # ── apiserver→kubelet client cert ─────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki apiserver-kubelet-client kube-apiserver-kubelet-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── front-proxy client cert ───────────────────────────────────
        gen_cert /etc/kubernetes/pki front-proxy-ca \
            /etc/kubernetes/pki front-proxy-client front-proxy-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── etcd certs ────────────────────────────────────────────────
        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki/etcd server etcd-server \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},IP:127.0.0.1"

        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki/etcd peer etcd-peer \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},IP:127.0.0.1"

        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki apiserver-etcd-client apiserver-etcd-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── service account key pair ──────────────────────────────────
        openssl genrsa -out /etc/kubernetes/pki/sa.key 2048
        openssl rsa -in /etc/kubernetes/pki/sa.key \
            -pubout -out /etc/kubernetes/pki/sa.pub

        # ── admin client cert (for kubeconfig) ────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki admin kubernetes-admin \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── controller-manager client cert ────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki controller-manager-client system:kube-controller-manager \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── scheduler client cert ─────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki scheduler-client system:kube-scheduler \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── kubelet client cert ───────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki kubelet-client "system:node:${NODE_NAME}" \
            "subjectAltName=DNS:${NODE_NAME},IP:127.0.0.1"

        echo "PKI generation complete."
    '

# Generate kubeconfig files for each component.
_gen-configs container=CONTAINER node=NODE_NAME: (_check-running container)
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{container}} test -f /etc/kubernetes/admin.conf 2>/dev/null; then
        echo "Kubeconfigs already exist, skipping."
        exit 0
    fi
    echo "Generating kubeconfigs..."
    write_kubeconfig() {
        local dest="$1" user="$2" cert="$3" key="$4" server="$5"
        local ca cert_data key_data
        ca=$(podman exec {{container}} base64 -w0 /etc/kubernetes/pki/ca.crt)
        cert_data=$(podman exec {{container}} base64 -w0 /etc/kubernetes/pki/${cert}.crt)
        key_data=$(podman exec {{container}} base64 -w0 /etc/kubernetes/pki/${key}.key)
        local yaml
        yaml="apiVersion: v1"$'\n'
        yaml+="kind: Config"$'\n'
        yaml+="clusters:"$'\n'
        yaml+="- cluster:"$'\n'
        yaml+="    certificate-authority-data: ${ca}"$'\n'
        yaml+="    server: ${server}"$'\n'
        yaml+="  name: kubernetes"$'\n'
        yaml+="contexts:"$'\n'
        yaml+="- context:"$'\n'
        yaml+="    cluster: kubernetes"$'\n'
        yaml+="    user: ${user}"$'\n'
        yaml+="  name: ${user}@kubernetes"$'\n'
        yaml+="current-context: ${user}@kubernetes"$'\n'
        yaml+="users:"$'\n'
        yaml+="- name: ${user}"$'\n'
        yaml+="  user:"$'\n'
        yaml+="    client-certificate-data: ${cert_data}"$'\n'
        yaml+="    client-key-data: ${key_data}"$'\n'
        printf '%s' "$yaml" | podman exec -i {{container}} bash -c "cat > ${dest}"
    }
    write_kubeconfig /etc/kubernetes/admin.conf \
        kubernetes-admin admin admin "https://{{node}}:{{PORT_APISERVER}}"
    CONTAINER_IP=$(podman exec {{container}} u7s-node-ip)
    write_kubeconfig /etc/kubernetes/coredns.conf \
    kubernetes-admin admin admin "https://${CONTAINER_IP}:{{PORT_APISERVER}}"
    write_kubeconfig /etc/kubernetes/controller-manager.conf \
        system:kube-controller-manager controller-manager-client controller-manager-client "https://{{node}}:{{PORT_APISERVER}}"
    write_kubeconfig /etc/kubernetes/scheduler.conf \
        system:kube-scheduler scheduler-client scheduler-client "https://{{node}}:{{PORT_APISERVER}}"
    write_kubeconfig /etc/kubernetes/kubelet.conf \
        "system:node:{{node}}" kubelet-client kubelet-client "https://{{node}}:{{PORT_APISERVER}}"
    echo "Kubeconfigs written."

# Wait for apiserver and remove the control-plane taint so pods schedule on this node.
_untaint: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Waiting for apiserver to become ready..."
    for i in $(seq 1 60); do
        if podman exec {{CONTAINER}} \
            kubectl --kubeconfig /etc/kubernetes/admin.conf \
            get nodes 2>/dev/null | grep -q Ready; then
            echo "Apiserver ready."
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "Timed out waiting for apiserver. Check: just status, then just logs kube-apiserver (or kubelet)"
            exit 1
        fi
        sleep 3
    done
    podman exec {{CONTAINER}} \
        kubectl --kubeconfig /etc/kubernetes/admin.conf \
        taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
    podman exec {{CONTAINER}} \
        kubectl --kubeconfig /etc/kubernetes/admin.conf \
        taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true
    echo "Node untainted — workloads will schedule."

# Pre-pull images into the cluster containerd. Uses local podman cache if available.
# CoreDNS is bundled in the node image itself and does not need to be listed here.
_prepull-images container=CONTAINER: (_check-running container)
    #!/usr/bin/env bash
    set -euo pipefail
    for img in \
        registry.k8s.io/pause:3.10.2; do
        if podman exec {{container}} ctr -n k8s.io images check "$img" &>/dev/null; then
            echo "Image $img already in cluster, skipping."
            continue
        fi
        if ! podman image exists "$img" 2>/dev/null; then
            echo "Pulling $img into local cache..."
            podman pull "$img"
        fi
        echo "Loading $img into cluster..."
        podman save "$img" | podman exec -i {{container}} ctr -n k8s.io images import -
    done

# ── cert-manager (Polar concern) ──────────────────────────────────────────────

# Install cert-manager into the cluster.
# cert-manager is required by Polar but is not permanent cluster infrastructure.
# Call this once after `just init` before deploying Polar.
# Images are loaded from local podman cache — pull them first if not present:
#   podman pull quay.io/jetstack/cert-manager-controller:v1.19.2
#   podman pull quay.io/jetstack/cert-manager-cainjector:v1.19.2
#   podman pull quay.io/jetstack/cert-manager-webhook:v1.19.2
install-cert-manager: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{CONTAINER}} kubectl --kubeconfig /etc/kubernetes/admin.conf \
        get namespace cert-manager &>/dev/null; then
        echo "cert-manager already installed, skipping."
        exit 0
    fi
    for img in \
        quay.io/jetstack/cert-manager-controller:v1.19.2 \
        quay.io/jetstack/cert-manager-cainjector:v1.19.2 \
        quay.io/jetstack/cert-manager-webhook:v1.19.2; do
        if podman exec {{CONTAINER}} ctr -n k8s.io images check "$img" &>/dev/null; then
            echo "Image $img already in cluster, skipping."
            continue
        fi
        if ! podman image exists "$img" 2>/dev/null; then
            echo "Pulling $img into local cache..."
            podman pull "$img"
        fi
        echo "Loading $img into cluster..."
        podman save "$img" | podman exec -i {{CONTAINER}} ctr -n k8s.io images import -
    done
    podman exec {{CONTAINER}} kubectl --kubeconfig /etc/kubernetes/admin.conf \
        apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
    echo "cert-manager installed."

# ── pod debugging tools ───────────────────────────────────────────────────────

_u7s_kubeconf := justfile_directory() + "/kubeconfig"

# Build and load the debug image into the cluster.
debug-image: _check-running
    nix build .#debug-image -o result-debug-image
    podman load -i result-debug-image
    podman exec -i {{CONTAINER}} ctr -n k8s.io images import - < result-debug-image

# Deploy a debug pod (stays running for exec). Idempotent.
debug-deploy: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if KUBECONFIG={{_u7s_kubeconf}} kubectl get pod u7s-debug &>/dev/null; then
        echo "Debug pod already exists, skipping."
        exit 0
    fi
    KUBECONFIG={{_u7s_kubeconf}} kubectl run u7s-debug \
        --image=docker.io/library/nix-usernetes-debug:latest \
        --image-pull-policy=Never \
        --restart=Never \
        --command -- sleep infinity

# Run debug script in node context.
debug-run: _check-running
    KUBECONFIG={{_u7s_kubeconf}} kubectl exec u7s-debug -- /usr/local/bin/u7s-debug

# Drop into a debug shell.
debug-shell: _check-running
    KUBECONFIG={{_u7s_kubeconf}} kubectl exec -it u7s-debug -- nu

# Run debug script in a specific pod's netns.
# Usage: just debug-pod cert-manager/cert-manager-7b8b89f89d-xxxxx
debug-pod pod: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    NS=$(echo "{{pod}}" | cut -d/ -f1)
    NAME=$(echo "{{pod}}" | cut -d/ -f2)
    NETNS=$(podman exec {{CONTAINER}} sh -c "crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods --namespace $NS --name $NAME -q 2>/dev/null | xargs -I{} crictl --runtime-endpoint unix:///run/containerd/containerd.sock inspectp {} 2>/dev/null | jq -r '.info.runtimeSpec.linux.namespaces[] | select(.type==\"network\") | .path'")
    echo "Pod netns: $NETNS"
    KUBECONFIG={{_u7s_kubeconf}} kubectl exec u7s-debug -- nsenter --net=$NETNS /usr/local/bin/u7s-debug

# Load the node image into podman after a `nix build`.
# Run this after every `nix build .#node-image -o result-node-image`.
load-node-image:
    podman load -i result-node-image

# Load the worker image, for a cluster's workers, after `nix build .#worker-image -o result-worker-image`.
load-worker-image:
    podman load -i result-worker-image

# Render node.dhall and worker.dhall (what a node runs: its packages, boot steps and services) to node.nix and
# worker.nix, which nix build reads. Commit them all. Needs dhall-to-nix (nix shell nixpkgs#dhall-nix) and the
# network, for the library's prelude.
render:
    dhall-to-nix < node.dhall > node.nix
    dhall-to-nix < worker.dhall > worker.nix

# ── a cluster of nodes (cluster.dhall, cluster.sh) ───────────────────────────────────────────────────────────────────
# One control plane and workers, each its own container, on a network of their own; u7s above is separate, and the two
# can run side by side. The images: node-image (the control plane) and worker-image, built and loaded as above.

# Start the cluster: the hub, the nodes' network, the nodes. Idempotent, as `up` is.
cluster-up:
    ./cluster.sh up

# After the first `cluster-up`: the control plane's PKI and kubeconfigs, the workers joined, labels and taints. Run it
# again after adding a node to cluster.dhall, or changing labels or taints: it skips what is done.
cluster-init:
    ./cluster.sh init

# Write kubeconfig-<cluster>, which reaches the apiserver on the host's apiserverPort (cluster.dhall).
cluster-kubeconfig:
    ./cluster.sh kubeconfig

# The cluster's containers and nodes.
cluster-status:
    ./cluster.sh status

# Stop and remove the nodes and the hub. The cluster's state stays on its volumes.
cluster-down:
    ./cluster.sh down

# cluster-down, and wipe the cluster's volumes and kubeconfig.
cluster-reset:
    ./cluster.sh reset
