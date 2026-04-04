# nix-usernetes Justfile
# Single-node rootless Kubernetes for a developer workstation.
# Start it when you need it. Stop it when you don't.
#
# Prerequisites: podman, just, openssl, jq
#
# Quickstart:
#   just up       # start the container (systemd + containerd + kubelet)
#   just init     # generate PKI and static pod manifests (first time only)
#   just kubeconfig
#   export KUBECONFIG=$(pwd)/kubeconfig
#   kubectl get pods -A

# ── configuration ─────────────────────────────────────────────────────────────

IMAGE        := "localhost/nix-usernetes-node:1.33.10"
CONTAINER    := "u7s"
NODE_NAME    := "u7s-node"
POD_SUBNET   := "10.244.0.0/16"
SVC_SUBNET   := "10.96.0.0/16"

PORT_APISERVER := "6443"
PORT_ETCD      := "2379"
PORT_KUBELET   := "10250"

# ── core lifecycle ────────────────────────────────────────────────────────────

# Start the node container. Idempotent.
up:
    podman run -d \
        --name {{CONTAINER}} \
        --hostname {{NODE_NAME}} \
        --network slirp4netns:allow_host_loopback=true \
        --privileged \
        --cgroupns=private \
        --ipc=host \
        --systemd=always \
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
        --env container=docker \
        --env NODE_NAME={{NODE_NAME}} \
        --stop-signal RTMIN+3 \
        {{IMAGE}} \
        2>/dev/null || echo "Container '{{CONTAINER}}' already running."

# Stop the node container gracefully.
down:
    podman stop --time 30 {{CONTAINER}} 2>/dev/null || true
    podman rm {{CONTAINER}} 2>/dev/null || true

# Stop and wipe all state. Next `just up && just init` starts fresh.
reset: down
    podman volume rm -f u7s-pki u7s-etcd u7s-kubelet u7s-containerd 2>/dev/null || true
    rm -f kubeconfig
    @echo "State wiped. Run 'just up && just init' to start fresh."

# Show container logs (live).
logs:
    podman logs -f {{CONTAINER}}

# Open a shell inside the node.
shell:
    podman exec -it {{CONTAINER}} bash

# Show status of Kubernetes components inside the node.
status:
    @echo "=== systemd units ==="
    podman exec {{CONTAINER}} systemctl status containerd kubelet --no-pager || true
    @echo ""
    @echo "=== static pods ==="
    podman exec {{CONTAINER}} \
        crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods 2>/dev/null || true

# ── cluster bootstrap (run once after first `just up`) ───────────────────────

# Generate PKI, configs, and static pod manifests. Safe to re-run.
init: _gen-pki _gen-configs _gen-apiserver-env _untaint _prepull-images _install-cert-manager
    @echo ""
    @echo "✓ Cluster initialised. Run 'just kubeconfig' then:"
    @echo "  export KUBECONFIG=$(pwd)/kubeconfig"
    @echo "  kubectl get pods -A"

# Extract kubeconfig (replaces node name with 127.0.0.1 for local access).
kubeconfig: _check-running
    podman exec {{CONTAINER}} \
        sed "s/{{NODE_NAME}}/127.0.0.1/g" /etc/kubernetes/admin.conf > kubeconfig
    @echo "export KUBECONFIG=$(pwd)/kubeconfig"

# ── private bootstrap steps ──────────────────────────────────────────────────

_check-running:
    @podman inspect {{CONTAINER}} --format '{{{{.State.Running}}}}' 2>/dev/null \
        | grep -q true \
        || (echo "Container '{{CONTAINER}}' is not running. Run 'just up' first." && exit 1)

# Generate all PKI certificates into the u7s-pki volume (/etc/kubernetes/pki).
_gen-pki: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{CONTAINER}} test -f /etc/kubernetes/pki/ca.crt 2>/dev/null; then
        echo "PKI already exists, skipping."
        exit 0
    fi
    CONTAINER_IP=$(podman exec {{CONTAINER}} ip -4 addr show tap0 | grep "inet " | head -1 | sed 's|.*inet \([0-9.]*\)/.*|\1|')
    echo "Generating PKI..."
    podman exec --env CONTAINER_IP="$CONTAINER_IP" --env NODE_NAME={{NODE_NAME}} {{CONTAINER}} bash -euc '
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

        # ── CA certs ──────────────────────────────────────────────────────
        gen_ca /etc/kubernetes/pki ca
        gen_ca /etc/kubernetes/pki/etcd ca
        gen_ca /etc/kubernetes/pki front-proxy-ca

        # ── apiserver cert ────────────────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki apiserver kube-apiserver \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,IP:127.0.0.1,IP:10.96.0.1,IP:${CONTAINER_IP}"

        # ── apiserver→kubelet client cert ─────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki apiserver-kubelet-client kube-apiserver-kubelet-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── front-proxy client cert ───────────────────────────────────────
        gen_cert /etc/kubernetes/pki front-proxy-ca \
            /etc/kubernetes/pki front-proxy-client front-proxy-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── etcd certs ────────────────────────────────────────────────────
        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki/etcd server etcd-server \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},IP:127.0.0.1"

        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki/etcd peer etcd-peer \
            "subjectAltName=DNS:localhost,DNS:${NODE_NAME},IP:127.0.0.1"

        gen_cert /etc/kubernetes/pki/etcd ca \
            /etc/kubernetes/pki apiserver-etcd-client apiserver-etcd-client \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── service account key pair ──────────────────────────────────────
        openssl genrsa -out /etc/kubernetes/pki/sa.key 2048
        openssl rsa -in /etc/kubernetes/pki/sa.key \
            -pubout -out /etc/kubernetes/pki/sa.pub

        # ── admin client cert (for kubeconfig) ────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki admin kubernetes-admin \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── controller-manager client cert ────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki controller-manager-client system:kube-controller-manager \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── scheduler client cert ─────────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki scheduler-client system:kube-scheduler \
            "subjectAltName=DNS:${NODE_NAME}"

        # ── kubelet client cert ───────────────────────────────────────────
        gen_cert /etc/kubernetes/pki ca \
            /etc/kubernetes/pki kubelet-client "system:node:${NODE_NAME}" \
            "subjectAltName=DNS:${NODE_NAME},IP:127.0.0.1"

        echo "PKI generation complete."
    '

# Generate kubeconfig files for each component.
_gen-configs: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{CONTAINER}} test -f /etc/kubernetes/admin.conf 2>/dev/null; then
        echo "Kubeconfigs already exist, skipping."
        exit 0
    fi
    echo "Generating kubeconfigs..."

    write_kubeconfig() {
        local dest="$1" user="$2" cert="$3" key="$4"
        local ca cert_data key_data apiserver
        apiserver="https://{{NODE_NAME}}:{{PORT_APISERVER}}"
        ca=$(podman exec {{CONTAINER}} base64 -w0 /etc/kubernetes/pki/ca.crt)
        cert_data=$(podman exec {{CONTAINER}} base64 -w0 /etc/kubernetes/pki/${cert}.crt)
        key_data=$(podman exec {{CONTAINER}} base64 -w0 /etc/kubernetes/pki/${key}.key)
        local yaml
        yaml="apiVersion: v1"$'\n'
        yaml+="kind: Config"$'\n'
        yaml+="clusters:"$'\n'
        yaml+="- cluster:"$'\n'
        yaml+="    certificate-authority-data: ${ca}"$'\n'
        yaml+="    server: ${apiserver}"$'\n'
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
        printf '%s' "$yaml" | podman exec -i {{CONTAINER}} bash -c "cat > ${dest}"
    }

    write_kubeconfig /etc/kubernetes/admin.conf \
        kubernetes-admin admin admin
    write_kubeconfig /etc/kubernetes/controller-manager.conf \
        system:kube-controller-manager controller-manager-client controller-manager-client
    write_kubeconfig /etc/kubernetes/scheduler.conf \
        system:kube-scheduler scheduler-client scheduler-client
    write_kubeconfig /etc/kubernetes/kubelet.conf \
        "system:node:{{NODE_NAME}}" kubelet-client kubelet-client

    echo "Kubeconfigs written."

# Patch the apiserver unit with the actual CONTAINER_IP and restart services.
_gen-apiserver-env: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{CONTAINER}} grep -q "advertise-address=10\." /etc/systemd/system/kube-apiserver.service 2>/dev/null; then
        echo "Apiserver already configured, skipping."
        exit 0
    fi
    CONTAINER_IP=$(podman exec {{CONTAINER}} ip -4 addr show tap0 | grep "inet " | head -1 | sed 's|.*inet \([0-9.]*\)/.*|\1|')
    echo "Configuring apiserver with CONTAINER_IP=${CONTAINER_IP}..."
    podman exec {{CONTAINER}} sed -i \
        "s/--advertise-address=\$HOST_IP/--advertise-address=${CONTAINER_IP}/g" \
        /etc/systemd/system/kube-apiserver.service
    podman exec {{CONTAINER}} systemctl daemon-reload
    podman exec {{CONTAINER}} systemctl restart etcd kube-apiserver kube-controller-manager kube-scheduler kubelet 2>/dev/null || true
    echo "Control plane services restarted."

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
            echo "Timed out waiting for apiserver. Check: podman exec u7s systemctl status kubelet"
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
_prepull-images: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    for img in \
        registry.k8s.io/pause:3.10 \
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

# Install cert-manager into the cluster. Idempotent.
_install-cert-manager: _check-running
    #!/usr/bin/env bash
    set -euo pipefail
    if podman exec {{CONTAINER}} kubectl --kubeconfig /etc/kubernetes/admin.conf \
        get namespace cert-manager &>/dev/null; then
        echo "cert-manager already installed, skipping."
        exit 0
    fi
    podman exec {{CONTAINER}} kubectl --kubeconfig /etc/kubernetes/admin.conf \
        apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml

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
