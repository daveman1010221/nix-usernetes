{
  description = "nix-usernetes — Nix-native rootless Kubernetes node image (kindest/node replacement)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # vigild is the node's PID 1 and supervises its services; vigil is its CLI (`vigil services list`, `vigil logs`).
    vigil-rs.url = "github:daveman1010221/vigil-rs-nix";
    vigil-rs.inputs.nixpkgs.follows = "nixpkgs";
    vigil-rs.inputs.flake-utils.follows = "flake-utils";
    # The node is a nix-container-lib System container (node.dhall), with the vigil-rs above.
    nix-container-lib.url = "github:daveman1010221/nix-container-lib";
    nix-container-lib.inputs.nixpkgs.follows = "nixpkgs";
    nix-container-lib.inputs.flake-utils.follows = "flake-utils";
    nix-container-lib.inputs.vigil-rs.follows = "vigil-rs";
  };

  outputs = { self, nixpkgs, flake-utils, vigil-rs, nix-container-lib }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = false;
        };

        # ── versioning ────────────────────────────────────────────────────────
        # Kubernetes vendors cAdvisor, which only reports filesystems of a type
        # it knows. Up to 1.35 (cAdvisor v0.53.0) f2fs was not one of them and
        # the kubelet failed on f2fs hosts, so this flake swapped in a patched
        # fork; since 1.36 (cAdvisor v0.56.2) its VFS plugin handles f2fs.
        k8sVersion     = "1.37.1";
        k8sTag         = "v${k8sVersion}";
        k8sMinor       = builtins.elemAt (pkgs.lib.splitString "." k8sVersion) 1;
        k8sSha256      = "sha256-iSlaw3XrD9/migaW2BvmFXcdayfHrZu2ddxv/Q0s5fM=";
        coreDNSVersion = "1.14.6";

        # ── CoreDNS OCI image ─────────────────────────────────────────────────
        # Fetched by Nix at build time and bundled into the node image.
        # The image-preload service imports it into containerd before
        # kubelet starts, so CoreDNS is available without any network access
        # at cluster init time.
        #
        # To update: set sha256 = pkgs.lib.fakeHash, run `nix build`, copy
        # the correct hash from the error output, replace fakeHash with it.
        coreDNSImage = pkgs.dockerTools.pullImage {
          imageName      = "registry.k8s.io/coredns/coredns";
          imageDigest    = "sha256:900f9c109f7a33545d3c811516e8376df9019147b750f5ce3e254468769176ea";
          sha256         = "sha256-FBp3wbQ9tkw9nf5w1tgs6ysx8UBBHaHxUHL7TJYK9L0=";
          finalImageName = "registry.k8s.io/coredns/coredns";
          finalImageTag  = "v${coreDNSVersion}";
        };

        # ── packages from nixpkgs ─────────────────────────────────────────────
        inherit (pkgs)
          go
          bash
          coreutils
          util-linux
          findutils
          gnugrep
          iproute2
          iptables
          kmod
          procps
          containerd
          runc
          cri-tools
          etcd
          flannel
          kubernetes-helm
          openssl
          jq
          curl
          socat
          conntrack-tools
          ethtool
          ;

        cniPlugins = pkgs.cni-plugins;

        # ── Kubernetes source ─────────────────────────────────────────────────
        kubernetesSrc = pkgs.fetchurl {
          url    = "https://github.com/kubernetes/kubernetes/archive/refs/tags/${k8sTag}.tar.gz";
          sha256 = k8sSha256;
        };

        # ── kubelet (+ friends) built from source ─────────────────────────────
        # One build, one output per binary, so that each image carries only the binaries its role runs: `out` is
        # kubectl, the others kubernetes.kubelet, kubernetes.proxy, kubernetes.apiserver, ...
        kubernetes = pkgs.stdenv.mkDerivation rec {
          pname   = "kubernetes";
          version = k8sVersion;
          outputs = [ "out" "kubelet" "proxy" "apiserver" "controllerManager" "scheduler" ];

          src = kubernetesSrc;

          nativeBuildInputs = [
            go
            pkgs.git
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnumake
            pkgs.rsync
            pkgs.which
          ];

          # CGO_ENABLED=0: fully static binaries, no C library deps, no Nix
          # store path references in the output. This is the correct approach
          # for a regular (input-addressed) derivation building container
          # binaries. kubelet's seccomp support has a pure-Go fallback path.
          #
          # Do NOT use outputHash/outputHashMode here — those are for FODs
          # (fetching external content). FODs cannot reference store paths,
          # which compiled binaries inherently do when CGO is enabled.
          buildInputs = [];

          HOME         = "/build/go-home";
          GOFLAGS      = "-mod=vendor";
          GONOSUMCHECK = "*";
          GONOSUMDB    = "*";
          GOPROXY      = "off";
          GOPATH       = "/build/gopath";
          CGO_ENABLED  = "0";

          KUBE_GIT_VERSION    = k8sTag;
          KUBE_GIT_MAJOR      = "1";
          KUBE_GIT_MINOR      = k8sMinor;
          KUBE_GIT_COMMIT     = "nix-usernetes";
          KUBE_GIT_TREE_STATE = "clean";

          configurePhase = ''
            runHook preConfigure
            mkdir -p "$HOME" "$GOPATH"
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild

            TARGETS=(
              cmd/kubelet
              cmd/kube-apiserver
              cmd/kube-controller-manager
              cmd/kube-scheduler
              cmd/kubectl
              cmd/kube-proxy
            )

            for target in "''${TARGETS[@]}"; do
              echo "Building $target..."
              go build \
                -mod=vendor \
                -trimpath \
                -ldflags "
                  -X k8s.io/client-go/pkg/version.gitVersion=${k8sTag}
                  -X k8s.io/client-go/pkg/version.gitMajor=1
                  -X k8s.io/client-go/pkg/version.gitMinor=${k8sMinor}
                  -X k8s.io/client-go/pkg/version.gitCommit=nix-usernetes
                  -X k8s.io/client-go/pkg/version.gitTreeState=clean
                  -X k8s.io/component-base/version.gitVersion=${k8sTag}
                  -X k8s.io/component-base/version.gitMajor=1
                  -X k8s.io/component-base/version.gitMinor=${k8sMinor}
                  -X k8s.io/component-base/version.gitCommit=nix-usernetes
                  -X k8s.io/component-base/version.gitTreeState=clean
                  -w -s
                " \
                -o "_output/bin/$(basename $target)" \
                "./$target"
            done

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 _output/bin/kubectl                 "$out/bin/kubectl"
            install -Dm755 _output/bin/kubelet                 "$kubelet/bin/kubelet"
            install -Dm755 _output/bin/kube-proxy              "$proxy/bin/kube-proxy"
            install -Dm755 _output/bin/kube-apiserver          "$apiserver/bin/kube-apiserver"
            install -Dm755 _output/bin/kube-controller-manager "$controllerManager/bin/kube-controller-manager"
            install -Dm755 _output/bin/kube-scheduler          "$scheduler/bin/kube-scheduler"
            runHook postInstall
          '';

          meta = {
            description = "Kubernetes binaries, built statically from source";
            platforms   = [ "x86_64-linux" ];
          };
        };

        # ── node services' scripts ────────────────────────────────────────────
        # Each service in node.dhall runs one of these, as /bin/u7s-<service>. vigild starts a service once those it is
        # ordered `after` are running, not once they have done anything, so what a service needs before it can start
        # (its certificates, its kubeconfig, the preloaded images) it waits for itself, here.
        servicePath = "/bin:/sbin:/usr/bin:/usr/sbin";
        waitFor = path: ''until [ -e ${path} ]; do sleep 2; done'';

        # The node's address, in NODE_IP: a cluster's node is given its own (cluster.sh, its veth on the hub's bridge);
        # the single node of `just up` has the one slirp4netns gives it on tap0 (10.0.2.100), read at every start, so
        # nothing about it is kept in the container.
        nodeIp = ''
          if [ -z "''${NODE_IP:-}" ]; then
            for _ in $(seq 1 30); do
              set -- $(ip -4 -o addr show dev tap0 2>/dev/null)
              if [ -n "''${4:-}" ]; then NODE_IP=''${4%/*}; break; fi
              sleep 1
            done
          fi
          if [ -z "''${NODE_IP:-}" ]; then echo "$0: no NODE_IP given, and tap0 has no IPv4 address" >&2; exit 1; fi
        '';

        containerdRun = pkgs.writeShellScriptBin "u7s-containerd" ''
          export PATH=${servicePath}:${containerd}/bin:${runc}/bin:${cri-tools}/bin:${pkgs.rootlesskit}/bin:${pkgs.slirp4netns}/bin
          modprobe overlay 2>/dev/null || true
          exec ${containerd}/bin/containerd
        '';

        etcdRun = pkgs.writeShellScriptBin "u7s-etcd" ''
          export PATH=${servicePath}
          ${waitFor "/etc/kubernetes/pki/etcd/server.crt"}
          exec ${etcd}/bin/etcd \
            --data-dir=/var/lib/etcd \
            --listen-client-urls=https://127.0.0.1:2379 \
            --advertise-client-urls=https://127.0.0.1:2379 \
            --listen-peer-urls=https://127.0.0.1:2380 \
            --initial-advertise-peer-urls=https://127.0.0.1:2380 \
            --initial-cluster=default=https://127.0.0.1:2380 \
            --cert-file=/etc/kubernetes/pki/etcd/server.crt \
            --key-file=/etc/kubernetes/pki/etcd/server.key \
            --client-cert-auth=true \
            --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \
            --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt \
            --peer-key-file=/etc/kubernetes/pki/etcd/peer.key \
            --peer-client-cert-auth=true \
            --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt \
            --snapshot-count=10000
        '';

        # The apiserver advertises the node's address, so a node that is removed and created again (`just restart`, or
        # by hand) starts as it did. It reaches an aggregated API's or a webhook's Service at the address of a pod behind
        # it, not at its cluster IP (--enable-aggregator-routing): a cluster's control plane runs no kube-proxy, so no
        # cluster IP answers there, while every pod's address does (cluster.sh routes the pod ranges).
        apiserverRun = pkgs.writeShellScriptBin "u7s-kube-apiserver" ''
          export PATH=${servicePath}
          ${waitFor "/etc/kubernetes/pki/apiserver.crt"}
          ${nodeIp}
          exec ${kubernetes.apiserver}/bin/kube-apiserver \
            --advertise-address="$NODE_IP" \
            --bind-address=0.0.0.0 \
            --allow-privileged=true \
            --authorization-mode=Node,RBAC \
            --client-ca-file=/etc/kubernetes/pki/ca.crt \
            --enable-admission-plugins=NodeRestriction \
            --enable-aggregator-routing=true \
            --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \
            --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \
            --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \
            --etcd-servers=https://127.0.0.1:2379 \
            --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
            --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
            --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname \
            --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt \
            --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key \
            --requestheader-allowed-names=front-proxy-client \
            --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt \
            --requestheader-extra-headers-prefix=X-Remote-Extra- \
            --requestheader-group-headers=X-Remote-Group \
            --requestheader-username-headers=X-Remote-User \
            --secure-port=6443 \
            --service-account-issuer=https://kubernetes.default.svc.cluster.local \
            --service-account-key-file=/etc/kubernetes/pki/sa.pub \
            --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
            --service-cluster-ip-range=10.96.0.0/16 \
            --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \
            --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
        '';

        controllerManagerRun = pkgs.writeShellScriptBin "u7s-kube-controller-manager" ''
          export PATH=${servicePath}
          ${waitFor "/etc/kubernetes/controller-manager.conf"}
          # Each node's pod range is given to it (POD_CIDR, read by u7s-prepare into CNI's host-local IPAM), so none is
          # allocated here: one allocated in the order nodes register would not be the range the node uses.
          exec ${kubernetes.controllerManager}/bin/kube-controller-manager \
            --allocate-node-cidrs=false \
            --cluster-cidr=${clusterCidr} \
            --cluster-name=kubernetes \
            --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt \
            --cluster-signing-key-file=/etc/kubernetes/pki/ca.key \
            --controllers=*,bootstrapsigner,tokencleaner \
            --kubeconfig=/etc/kubernetes/controller-manager.conf \
            --leader-elect=false \
            --root-ca-file=/etc/kubernetes/pki/ca.crt \
            --service-account-private-key-file=/etc/kubernetes/pki/sa.key \
            --service-cluster-ip-range=10.96.0.0/16 \
            --use-service-account-credentials=true
        '';

        schedulerRun = pkgs.writeShellScriptBin "u7s-kube-scheduler" ''
          export PATH=${servicePath}
          ${waitFor "/etc/kubernetes/scheduler.conf"}
          exec ${kubernetes.scheduler}/bin/kube-scheduler \
            --kubeconfig=/etc/kubernetes/scheduler.conf \
            --leader-elect=false
        '';

        # The kubelet waits for image-preload to have imported CoreDNS into containerd, before it reads the static pod
        # manifest directory. A cluster's worker registers with its labels and taints (NODE_LABELS, NODE_TAINTS, from
        # cluster.dhall), so it is never Ready without them, and nothing is scheduled there that they would keep out.
        kubeletRun = pkgs.writeShellScriptBin "u7s-kubelet" ''
          export PATH=${servicePath}:${kubernetes.kubelet}/bin:${containerd}/bin:${runc}/bin:${cri-tools}/bin
          ${waitFor "/etc/kubernetes/kubelet.conf"}
          ${waitFor "/run/u7s/images-preloaded"}
          ${nodeIp}
          set --
          [ -n "''${NODE_LABELS:-}" ] && set -- "$@" --node-labels="$NODE_LABELS"
          [ -n "''${NODE_TAINTS:-}" ] && set -- "$@" --register-with-taints="$NODE_TAINTS"
          exec ${kubernetes.kubelet}/bin/kubelet \
            --config=/etc/kubelet/kubelet-config.yaml \
            --kubeconfig=/etc/kubernetes/kubelet.conf \
            --node-ip="$NODE_IP" \
            --v=2 \
            "$@"
        '';

        # A worker has its own kubeconfig (kube-proxy.conf, written by `just cluster-init`); the control plane uses the
        # admin's, as the single node always has.
        kubeProxyRun = pkgs.writeShellScriptBin "u7s-kube-proxy" ''
          export PATH=${servicePath}:${kubernetes.proxy}/bin:${pkgs.nftables}/bin
          until [ -e /etc/kubernetes/kube-proxy.conf ] || [ -e /etc/kubernetes/admin.conf ]; do sleep 2; done
          config=/etc/kubernetes/admin.conf
          [ -e /etc/kubernetes/kube-proxy.conf ] && config=/etc/kubernetes/kube-proxy.conf
          exec ${kubernetes.proxy}/bin/kube-proxy \
            --kubeconfig="$config" \
            --proxy-mode=nftables \
            --cluster-cidr=${clusterCidr} \
            --conntrack-max-per-core=0
        '';

        # ── kubelet configuration ─────────────────────────────────────────────
        # clusterDNS points at the kube-dns Service IP (10.96.0.10).
        # This is the well-known convention: the 10th address in the service
        # CIDR (10.96.0.0/16 → 10.96.0.10) is reserved for kube-dns.
        # The kube-dns Service is applied by the cluster-bootstrap service after
        # the apiserver becomes ready.
        kubeletConfig = pkgs.writeText "kubelet-config.yaml" ''
          apiVersion: kubelet.config.k8s.io/v1beta1
          kind: KubeletConfiguration
          featureGates:
            KubeletInUserNamespace: true
          failSwapOn: false
          cgroupDriver: cgroupfs
          cgroupsPerQOS: false
          enforceNodeAllocatable: []
          # The kubelet limits registry requests to 5 a second with a burst of 10, and a pull policy of Always makes one for every container
          # that starts: 24 pods at once are throttled ("pull QPS exceeded"), retried with a backoff, and take 18 s to run instead of 1.3 s.
          # This node pulls from a registry on its own host, so there is nothing to protect: 0 is no limit.
          registryPullQPS: 0
          containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
          staticPodPath: /etc/kubernetes/manifests
          clusterDNS:
            - 10.96.0.10
          clusterDomain: cluster.local
          authentication:
            anonymous:
              enabled: true
            webhook:
              enabled: false
          authorization:
            mode: AlwaysAllow
          logging:
            verbosity: 2
        '';

        containerdConfig = pkgs.writeText "containerd-config.toml" ''
          version = 4
          [plugins."io.containerd.cri.v1.runtime"]
            restrict_oom_score_adj = true
            [plugins."io.containerd.cri.v1.runtime".cni]
              bin_dirs = ["/opt/cni/bin"]
              conf_dir = "/etc/cni/net.d"
            [plugins."io.containerd.cri.v1.runtime".containerd]
              default_runtime_name = "runc"
              [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]
                runtime_type = "io.containerd.runc.v2"
                [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
                  SystemdCgroup = false
                  NoPivotRoot = true
          # The pause image, which _prepull-images in the Justfile loads.
          [plugins."io.containerd.cri.v1.images".pinned_images]
            sandbox = "registry.k8s.io/pause:3.10.2"
          [plugins."io.containerd.cri.v1.images".registry]
            config_path = "/etc/containerd/certs.d"
        '';

        # hosts.toml for the local dev registry (polar-registry, run on the
        # host via `just registry-up`). u7s reaches the host through its
        # slirp4netns gateway at 10.0.2.2 -- this tells containerd that
        # endpoint is a plain-HTTP registry, not a misconfigured HTTPS one.
        localRegistryHostsToml = pkgs.writeText "hosts.toml" ''
          server = "http://10.0.2.2:5000"

          [host."http://10.0.2.2:5000"]
            capabilities = ["pull", "resolve"]
        '';

        # hosts.toml for a registry kept in the cluster (Polar's sandbox-local),
        # which the node pulls from as localhost:30500, a NodePort. kube-proxy's
        # nftables mode serves NodePorts on the node's addresses but not on
        # 127.0.0.1 (iptables mode did, through route_localnet), so containerd
        # sends those pulls to the same NodePort on the node's own address.
        # A template: u7s-prepare writes it with the node's address at every start.
        inClusterRegistryHostsToml = pkgs.writeText "hosts.toml.in" ''
          server = "http://@NODE_IP@:30500"

          [host."http://@NODE_IP@:30500"]
            capabilities = ["pull", "resolve"]
        '';

        sysctlConfig = pkgs.writeText "99-u7s.conf" ''
          net.ipv4.conf.default.arp_notify=1
          net.ipv4.conf.default.arp_accept=1
          net.ipv4.conf.all.arp_ignore=0
          net.ipv4.ip_forward=1
        '';

        # ── pod networking, all in nftables ───────────────────────────────────
        # Nothing here goes through iptables: iptables-nft needs the kernel's
        # xt_* extensions (xt_comment, xt_nat, xt_statistic, ...), which a
        # minimal host kernel may not build. kube-proxy runs in nftables mode
        # and portmap uses its nftables backend, both with `ip`-family tables.
        # Pods are masqueraded by a table a boot step loads rather than by ptp's
        # ipMasq: its nftables backend needs the `inet` family, which a kernel
        # without IPv6 does not have.
        #
        # Every node has its own /24 of the cluster's range (POD_CIDR; the single
        # node's is the first), and reaches the others' through their nodes
        # (routes cluster.sh adds), so traffic between pods is never masqueraded.
        clusterCidr = "10.244.0.0/16";

        masqueradeRules = pkgs.writeText "u7s-masquerade.nft" ''
          table ip u7s-masquerade {
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr ${clusterCidr} ip daddr != { ${clusterCidr}, 224.0.0.0/4 } masquerade
            }
          }
        '';

        # A template: u7s-prepare writes it with the node's pod range at every start.
        cniConfig = pkgs.writeText "10-u7s.conflist.in" ''
          {
            "cniVersion": "1.0.0",
            "name": "u7s",
            "plugins": [
              {
                "type": "ptp",
                "ipMasq": false,
                "ipam": {
                  "type": "host-local",
                  "ranges": [[{ "subnet": "@POD_CIDR@" }]],
                  "routes": [{ "dst": "0.0.0.0/0" }]
                }
              },
              {
                "type": "tuning",
                "sysctl": {
                  "net.ipv4.conf.IFNAME.arp_notify": "1",
                  "net.ipv4.conf.IFNAME.arp_accept": "1"
                }
              },
              {
                "type": "portmap",
                "backend": "nftables",
                "capabilities": { "portMappings": true }
              }
            ]
          }
        '';

        # ── CoreDNS Corefile ──────────────────────────────────────────────────
        # The single node's is mounted as a hostPath volume by the CoreDNS static pod, which reaches the apiserver with
        # a kubeconfig; a cluster's is in a ConfigMap, for a Deployment that reaches it as its service account.
        # Forwards upstream DNS to 10.0.2.2:5300: 10.0.2.2 is the host, as
        # slirp4netns presents it (its gateway), so this is the host's
        # 127.0.0.1:5300, a second listener of systemd-resolved
        # (services.resolved.settings.Resolve.DNSStubListenerExtra on the host).
        # The cluster therefore asks the host's own resolver, and follows it
        # when the VPN, the network or the upstream changes, without leaking
        # queries to a resolver of our choosing.
        #
        # Not slirp4netns's built-in DNS at 10.0.2.3: it did not answer from
        # inside the node (no reply to a query sent from the node container,
        # while the host's resolvers answered), so nothing resolved names
        # outside the cluster.
        coreDNSCorefileText = kubernetesAccess: ''
          .:53 {
              errors
              health {
                  lameduck 5s
              }
              ready
              kubernetes cluster.local in-addr.arpa ip6.arpa {
                  pods insecure
                  fallthrough in-addr.arpa ip6.arpa
                  ttl 30
                  ${kubernetesAccess}
              }
              forward . 10.0.2.2:5300
              cache 30
              loop
              reload
              loadbalance
          }
        '';
        coreDNSCorefile = pkgs.writeText "Corefile"
          (coreDNSCorefileText "kubeconfig /etc/kubernetes/coredns.conf kubernetes-admin@kubernetes");

        # ── CoreDNS static pod manifest ───────────────────────────────────────
        # kubelet watches /etc/kubernetes/manifests/ and manages this pod
        # automatically. imagePullPolicy: Never — the image is preloaded into
        # containerd by the image-preload service before kubelet starts.
        # coredns.conf uses 127.0.0.1 as the apiserver address to avoid a
        # chicken-and-egg problem where CoreDNS needs DNS to resolve u7s-node.
        coreDNSManifest = pkgs.writeText "coredns.yaml" ''
          apiVersion: v1
          kind: Pod
          metadata:
            name: coredns
            namespace: kube-system
            labels:
              k8s-app: kube-dns
          spec:
            priorityClassName: system-node-critical
            tolerations:
              - key: CriticalAddonsOnly
                operator: Exists
              - key: node-role.kubernetes.io/control-plane
                effect: NoSchedule
            containers:
              - name: coredns
                image: registry.k8s.io/coredns/coredns:v${coreDNSVersion}
                imagePullPolicy: Never
                args: [ "-conf", "/etc/coredns/Corefile" ]
                volumeMounts:
                  - name: config-volume
                    mountPath: /etc/coredns
                    readOnly: true
                  - name: kubeconfig
                    mountPath: /etc/kubernetes/coredns.conf
                    readOnly: true
                ports:
                  - containerPort: 53
                    name: dns
                    protocol: UDP
                  - containerPort: 53
                    name: dns-tcp
                    protocol: TCP
                  - containerPort: 9153
                    name: metrics
                    protocol: TCP
                livenessProbe:
                  httpGet:
                    path: /health
                    port: 8080
                    scheme: HTTP
                  initialDelaySeconds: 60
                  timeoutSeconds: 5
                  successThreshold: 1
                  failureThreshold: 5
                readinessProbe:
                  httpGet:
                    path: /ready
                    port: 8181
                    scheme: HTTP
                securityContext:
                  allowPrivilegeEscalation: false
                  capabilities:
                    add:
                      - NET_BIND_SERVICE
                    drop:
                      - ALL
                  readOnlyRootFilesystem: true
            volumes:
              - name: config-volume
                hostPath:
                  path: /etc/coredns
                  type: Directory
              - name: kubeconfig
                hostPath:
                  path: /etc/kubernetes/coredns.conf
                  type: File
            dnsPolicy: Default
        '';

        # ── a cluster's CoreDNS ───────────────────────────────────────────────
        # A cluster's control plane runs no kubelet, so its CoreDNS is a Deployment, which its cluster-bootstrap
        # applies, on a worker: on one with no taint (it tolerates none of a pool's, cluster.dhall), from the image
        # every worker carries (imagePullPolicy: Never). It reaches the apiserver as its service account, with the
        # permissions of upstream's system:coredns, and the host's resolver as the single node's does (10.0.2.2:5300,
        # through the hub). As JSON: the Corefile in its ConfigMap is a string, with no indentation to keep.
        coreDNSClusterManifest = pkgs.writeText "coredns.json" (builtins.toJSON {
          apiVersion = "v1";
          kind = "List";
          items = [
            {
              apiVersion = "v1";
              kind = "ServiceAccount";
              metadata = { name = "coredns"; namespace = "kube-system"; };
            }
            {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "ClusterRole";
              metadata.name = "system:coredns";
              rules = [
                { apiGroups = [ "" ]; resources = [ "endpoints" "services" "pods" "namespaces" ]; verbs = [ "list" "watch" ]; }
                { apiGroups = [ "discovery.k8s.io" ]; resources = [ "endpointslices" ]; verbs = [ "list" "watch" ]; }
              ];
            }
            {
              apiVersion = "rbac.authorization.k8s.io/v1";
              kind = "ClusterRoleBinding";
              metadata.name = "system:coredns";
              roleRef = { apiGroup = "rbac.authorization.k8s.io"; kind = "ClusterRole"; name = "system:coredns"; };
              subjects = [ { kind = "ServiceAccount"; name = "coredns"; namespace = "kube-system"; } ];
            }
            {
              apiVersion = "v1";
              kind = "ConfigMap";
              metadata = { name = "coredns"; namespace = "kube-system"; };
              data.Corefile = coreDNSCorefileText "";
            }
            {
              apiVersion = "apps/v1";
              kind = "Deployment";
              metadata = { name = "coredns"; namespace = "kube-system"; labels.k8s-app = "kube-dns"; };
              spec = {
                replicas = 1;
                selector.matchLabels.k8s-app = "kube-dns";
                template = {
                  metadata.labels.k8s-app = "kube-dns";
                  spec = {
                    serviceAccountName = "coredns";
                    priorityClassName = "system-cluster-critical";
                    tolerations = [ { key = "CriticalAddonsOnly"; operator = "Exists"; } ];
                    dnsPolicy = "Default";
                    containers = [ {
                      name = "coredns";
                      image = "registry.k8s.io/coredns/coredns:v${coreDNSVersion}";
                      imagePullPolicy = "Never";
                      args = [ "-conf" "/etc/coredns/Corefile" ];
                      volumeMounts = [ { name = "config-volume"; mountPath = "/etc/coredns"; readOnly = true; } ];
                      ports = [
                        { containerPort = 53; name = "dns"; protocol = "UDP"; }
                        { containerPort = 53; name = "dns-tcp"; protocol = "TCP"; }
                        { containerPort = 9153; name = "metrics"; protocol = "TCP"; }
                      ];
                      livenessProbe = {
                        httpGet = { path = "/health"; port = 8080; scheme = "HTTP"; };
                        initialDelaySeconds = 60; timeoutSeconds = 5; successThreshold = 1; failureThreshold = 5;
                      };
                      readinessProbe.httpGet = { path = "/ready"; port = 8181; scheme = "HTTP"; };
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities = { add = [ "NET_BIND_SERVICE" ]; drop = [ "ALL" ]; };
                        readOnlyRootFilesystem = true;
                      };
                    } ];
                    volumes = [ { name = "config-volume"; configMap.name = "coredns"; } ];
                  };
                };
              };
            }
          ];
        });

        # ── kube-dns Service manifest ─────────────────────────────────────────
        # Applied by the cluster-bootstrap service after the apiserver is ready.
        # Gives CoreDNS its well-known cluster IP (10.96.0.10) so that
        # kubelet's clusterDNS setting resolves correctly. Static pods cannot
        # self-register a Service — this is the one resource that requires a
        # live apiserver.
        kubeDNSServiceManifest = pkgs.writeText "kube-dns-service.yaml" ''
          apiVersion: v1
          kind: Service
          metadata:
            name: kube-dns
            namespace: kube-system
            labels:
              k8s-app: kube-dns
              kubernetes.io/cluster-service: "true"
              kubernetes.io/name: CoreDNS
            annotations:
              prometheus.io/port: "9153"
              prometheus.io/scrape: "true"
          spec:
            clusterIP: 10.96.0.10
            selector:
              k8s-app: kube-dns
            ports:
              - name: dns
                port: 53
                protocol: UDP
                targetPort: 53
              - name: dns-tcp
                port: 53
                protocol: TCP
                targetPort: 53
              - name: metrics
                port: 9153
                protocol: TCP
                targetPort: 9153
        '';

        # ── image preload ─────────────────────────────────────────────────────
        # A one-shot service: once containerd answers, it imports every OCI tarball in /var/lib/preload-images/ into
        # containerd's k8s.io namespace, so static pod images are there without any network access at cluster init,
        # and leaves /run/u7s/images-preloaded for the kubelet, which waits for it.
        imagePreloadRun = pkgs.writeShellScriptBin "u7s-image-preload" ''
          export PATH=${servicePath}:${containerd}/bin
          until ctr version >/dev/null 2>&1; do sleep 1; done
          sh ${imagePreloadScript}
          touch /run/u7s/images-preloaded
        '';

        imagePreloadScript = pkgs.writeText "preload-images.sh" ''
          #!/bin/sh
          set -eu
          PRELOAD_DIR=/var/lib/preload-images

          if [ ! -d "$PRELOAD_DIR" ]; then
            echo "image-preload: no preload directory found, skipping."
            exit 0
          fi

          for tarball in "$PRELOAD_DIR"/*.tar; do
            [ -f "$tarball" ] || continue
            echo "image-preload: importing $tarball into containerd k8s.io namespace..."
            ctr -n k8s.io images import "$tarball" \
              && echo "image-preload: OK $tarball" \
              || echo "image-preload: WARN failed to import $tarball"
          done
        '';

        # ── cluster bootstrap ─────────────────────────────────────────────────
        # A one-shot service: it waits for /etc/kubernetes/admin.conf (written by just init's _gen-configs step) and a
        # live apiserver, then applies what the image carries in /var/lib/cluster-bootstrap: the kube-dns Service, and a
        # cluster's control plane also its CoreDNS. It runs at every start; kubectl apply is idempotent.
        clusterBootstrapRun = pkgs.writeShellScriptBin "u7s-cluster-bootstrap" ''
          export PATH=${servicePath}:${kubernetes}/bin
          ${waitFor "/etc/kubernetes/admin.conf"}
          until kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz >/dev/null 2>&1; do
            echo "cluster-bootstrap: waiting for apiserver..."
            sleep 3
          done
          exec kubectl --kubeconfig /etc/kubernetes/admin.conf apply -f /var/lib/cluster-bootstrap/
        '';

        # ── boot step: prepare ────────────────────────────────────────────────
        # node-common.dhall's boot steps run once, at each start, before vigild: the cgroup delegation, the sysctls and
        # the pod masquerade come from nix-container-lib; this does the rest. podman writes /etc/hosts at every start,
        # and the node's name resolves to itself (the control plane's kubeconfigs use it). The files that hold the
        # node's address and pod range are written from their templates, on a node that runs pods (a cluster's control
        # plane has neither). /run (a tmpfs) holds what the services hand each other.
        nodePrepare = pkgs.writeShellScriptBin "u7s-prepare" ''
          export PATH=${servicePath}
          set -eu
          name=''${NODE_NAME:-u7s-node}
          grep -qw "$name" /etc/hosts || echo "127.0.0.1 $name" >> /etc/hosts
          ${nodeIp}
          if [ -e /etc/u7s/10-u7s.conflist.in ]; then
            sed "s|@POD_CIDR@|''${POD_CIDR:-10.244.0.0/24}|" /etc/u7s/10-u7s.conflist.in > /etc/cni/net.d/10-u7s.conflist
            sed "s|@NODE_IP@|$NODE_IP|" /etc/u7s/registry-hosts.toml.in > /etc/containerd/certs.d/localhost:30500/hosts.toml
          fi
          mkdir -p /run/u7s
        '';

        # The node's address, for `just` (the apiserver's certificate, CoreDNS's kubeconfig).
        nodeIpRun = pkgs.writeShellScriptBin "u7s-node-ip" ''
          export PATH=${servicePath}
          ${nodeIp}
          echo "$NODE_IP"
        '';

        # Each role's scripts: a node that runs pods, one that runs the control plane, the single node both.
        commonScripts       = [ nodeIpRun nodePrepare ];
        podScripts          = [ containerdRun imagePreloadRun kubeletRun kubeProxyRun ];
        controlPlaneScripts = [ etcdRun apiserverRun controllerManagerRun schedulerRun clusterBootstrapRun ];

        # ── OCI images ────────────────────────────────────────────────────────
        # nix-container-lib System containers, one per role, from node.dhall, control-plane.dhall and worker.dhall
        # (rendered to .nix). The library makes start.nu, which runs the boot steps, writes vigild's layer from the
        # services, and execs vigild as PID 1; this adds what a node is made of:
        #   single        — u7s: the control plane and the pods, CoreDNS as a static pod
        #   control-plane — a cluster's: etcd and the control plane, CoreDNS as a Deployment it applies; no kubelet
        #   worker        — a cluster's: containerd, the kubelet and kube-proxy, and the CoreDNS image
        mkNode = { configNixPath, role }:
          let
            runsPods         = role != "control-plane";
            runsControlPlane = role != "worker";
            description = {
              single          = "Rootless Kubernetes for developer workstations: a single node";
              "control-plane" = "Rootless Kubernetes for developer workstations: a cluster's control plane";
              worker          = "Rootless Kubernetes for developer workstations: a cluster's worker node";
            }.${role};
          in nix-container-lib.lib.${system}.mkContainer {
          inherit system pkgs configNixPath;
          inputs        = { inherit vigil-rs; };
          tag           = k8sVersion;

          extraDerivations =
            [ (pkgs.symlinkJoin {
                name  = "u7s-${role}-scripts";
                paths = commonScripts
                  ++ pkgs.lib.optionals runsPods podScripts
                  ++ pkgs.lib.optionals runsControlPlane controlPlaneScripts;
              })
              # `vigil services list`, `vigil logs` (just status, just logs)
              vigil-rs.packages.${system}.vigil
              # GNU coreutils over the library's (a subset: no seq, cut, wc, head, du, ...), which the scripts and
              # `just init` use. start.nu keeps the library's: it puts them first on its own PATH.
              (pkgs.lib.hiPrio coreutils)
            ]
            # The role's own binaries, on PATH as well as in its scripts
            ++ pkgs.lib.optionals runsPods [ kubernetes.kubelet kubernetes.proxy ]
            ++ pkgs.lib.optionals runsControlPlane [
              kubernetes.out kubernetes.apiserver kubernetes.controllerManager kubernetes.scheduler
            ];

          # Files the node carries as files: a volume mounted over one of these directories (u7s-pki over
          # /etc/kubernetes) is filled from the image when it is created, and keeps what it was filled with.
          extraCommands = ''
            # tools that look in /sbin find them in /bin (every package here has its sbin tools in bin too)
            [ -e sbin ] || ln -s bin sbin

            # /etc/kubernetes is populated at runtime by just init
            mkdir -p etc/kubernetes/pki
          '' + pkgs.lib.optionalString runsPods ''

            # containerd config
            mkdir -p etc/containerd
            cp ${containerdConfig} etc/containerd/config.toml
            mkdir -p etc/containerd/certs.d/10.0.2.2:5000
            cp ${localRegistryHostsToml} etc/containerd/certs.d/10.0.2.2:5000/hosts.toml
            # written by u7s-prepare from the template, with the node's address
            mkdir -p etc/containerd/certs.d/localhost:30500

            # boot steps' files (node-common.dhall)
            mkdir -p etc/sysctl.d etc/u7s
            cp ${sysctlConfig} etc/sysctl.d/99-u7s.conf
            cp ${masqueradeRules} etc/u7s/masquerade.nft
            cp ${inClusterRegistryHostsToml} etc/u7s/registry-hosts.toml.in

            # CNI binaries
            mkdir -p opt/cni/bin
            for f in ${cniPlugins}/bin/*; do
              ln -sf "$f" opt/cni/bin/$(basename "$f")
            done

            # CNI config: written by u7s-prepare from the template, with the node's pod range
            mkdir -p etc/cni/net.d
            cp ${cniConfig} etc/u7s/10-u7s.conflist.in

            # kubelet config — kept outside /etc/kubernetes so the u7s-pki
            # volume mount doesn't shadow it
            mkdir -p etc/kubelet
            cp ${kubeletConfig} etc/kubelet/kubelet-config.yaml
            mkdir -p etc/kubernetes/manifests

            # The CoreDNS image, imported by the image-preload service: the single node's static pod runs it, and a
            # cluster's Deployment on whichever worker it is scheduled
            mkdir -p var/lib/preload-images
            cp ${coreDNSImage} var/lib/preload-images/coredns.tar

            mkdir -p var/lib/kubelet run/containerd run/kubernetes lib/modules
          '' + pkgs.lib.optionalString runsControlPlane ''

            # ── Cluster bootstrap resources ────────────────────────────────────
            # Applied by the cluster-bootstrap service after apiserver is ready.
            mkdir -p var/lib/cluster-bootstrap var/lib/etcd
            cp ${kubeDNSServiceManifest} var/lib/cluster-bootstrap/kube-dns-service.yaml
          '' + pkgs.lib.optionalString (role == "single") ''

            # ── CoreDNS, a static pod ──────────────────────────────────────────
            # Corefile — mounted as hostPath by the CoreDNS static pod
            mkdir -p etc/coredns
            cp ${coreDNSCorefile} etc/coredns/Corefile
            cp ${coreDNSManifest} etc/kubernetes/manifests/coredns.yaml
          '' + pkgs.lib.optionalString (role == "control-plane") ''

            # ── CoreDNS, a Deployment on a worker ──────────────────────────────
            cp ${coreDNSClusterManifest} var/lib/cluster-bootstrap/coredns.json
          '' + ''

            touch etc/resolv.conf
            echo "u7s-node" > etc/hostname
          '';

          extraConfig = {
            # The node's state. Not /sys/fs/cgroup, /lib/modules or /run, which `just up` mounts (the cgroup filesystem,
            # the host's modules, a tmpfs): as image volumes each was also an anonymous volume, a new one at every
            # `podman run` and left behind by `podman rm`.
            Volumes = {
              "/etc/kubernetes"       = {};
            } // pkgs.lib.optionalAttrs runsPods {
              "/var/lib/kubelet"      = {};
              "/var/lib/containerd"   = {};
              "/opt/local-path-provisioner" = {};
            } // pkgs.lib.optionalAttrs runsControlPlane {
              "/var/lib/etcd"         = {};
            };
            Labels = {
              "org.opencontainers.image.description" = description;
              "org.opencontainers.image.version"     = k8sVersion;
            };
          };
        };

        nodeImage         = (mkNode { configNixPath = ./node.nix;          role = "single";        }).image;
        controlPlaneImage = (mkNode { configNixPath = ./control-plane.nix; role = "control-plane"; }).image;
        workerImage       = (mkNode { configNixPath = ./worker.nix;        role = "worker";        }).image;

        debugScript = pkgs.writeTextFile {
          name = "u7s-debug";
          executable = true;
          destination = "/usr/local/bin/u7s-debug";
          text = ''
            #!/usr/bin/env nu

            def section [title: string] {
              print $"\n(ansi green_bold)══ ($title) ══(ansi reset)"
            }

            def main [] {
              section "Interfaces & Addresses"
              ip addr show

              section "Routing Tables"
              ip route show table all

              section "ARP / Neighbor Table"
              ip neigh show

              section "iptables NAT PREROUTING"
              iptables -t nat -L PREROUTING -n -v

              section "iptables NAT POSTROUTING"
              iptables -t nat -L POSTROUTING -n -v

              section "nftables kube-proxy table"
              nft list table ip kube-proxy

              section "nftables pod masquerade table"
              nft list table ip u7s-masquerade

              section "nftables ruleset (nat table)"
              nft list table ip nat

              section "nftables ruleset (filter table)"
              nft list table ip filter

              section "Conntrack table (first 20)"
              conntrack -L 2>/dev/null | head -20

              section "Interface packet counters"
              cat /proc/net/dev

              section "Connectivity: apiserver (10.96.0.1:443)"
              curl --max-time 3 -sk https://10.96.0.1:443 | from json | get kind

              section "Connectivity: internet (1.1.1.1)"
              let result = (curl --max-time 3 -sI http://1.1.1.1 | lines | first)
              print $result

              section "Pod CIDR routes"
              ip route show | where ($it | str contains "10.244")

              section "Done"
            }
          '';
        };

        debugEtc = pkgs.runCommand "debug-etc" {} ''
          mkdir -p $out/etc
          echo "root:x:0:0:root:/root:/bin/sh" > $out/etc/passwd
          echo "root:x:0:" > $out/etc/group
          echo "root:!:19000:0:99999:7:::" > $out/etc/shadow
          mkdir -p $out/root
        '';

        debugImage = pkgs.dockerTools.buildLayeredImage {
          name = "nix-usernetes-debug";
          tag  = "latest";
          contents = pkgs.lib.flatten [
            bash
            pkgs.nushell
            pkgs.vim
            pkgs.strace
            pkgs.tcpdump
            conntrack-tools
            iproute2
            iptables
            pkgs.nftables
            pkgs.iputils
            curl
            socat
            jq
            procps
            pkgs.cacert
            debugEtc
          ];
          extraCommands = ''
            mkdir -p usr/local/bin etc root
            cp ${debugScript}/usr/local/bin/u7s-debug usr/local/bin/u7s-debug
            mkdir -p etc/ssl/certs
            ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
            # Replace absolute symlinks with relative ones to work around containerd 2.2.x bug
            # https://github.com/containerd/containerd/issues/12683
            for f in etc/passwd etc/group etc/shadow; do
              if [ -L "$f" ]; then
                target=$(readlink "$f")
                reltarget=$(echo "$target" | sed 's|^/|../../|')
                rm "$f"
                ln -sf "$reltarget" "$f"
              fi
            done
          '';
          config = {
            Cmd = [ "/usr/local/bin/u7s-debug" ];
            Entrypoint = [ "${pkgs.nushell}/bin/nu" ];
            Env = [
              "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
              "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin"
            ];
          };
        };

      in {
        packages = {
          kubernetes  = kubernetes;
          node-image          = nodeImage;
          control-plane-image = controlPlaneImage;
          worker-image        = workerImage;
          debug-image  = debugImage;
          default     = nodeImage;
        };

        devShells.default = pkgs.mkShell {
          name = "nix-usernetes-dev";
          packages = [
            go
            pkgs.git
            pkgs.gnumake
            containerd
            cri-tools
            kubernetes-helm
            pkgs.kubectl
            pkgs.just
            openssl
            jq
            curl
            pkgs.skopeo
            pkgs.dhall-nix
            # cluster.sh reads cluster.dhall as JSON, and wires the nodes' network namespaces to the hub's bridge
            pkgs.dhall-json
            iproute2
            pkgs.nftables
            util-linux
          ];
          shellHook = ''
            echo "nix-usernetes dev shell"
            echo ""
            echo "  nix build .#node-image -o result-node-image   — build the single node's image"
            echo "  just load-node-image                          — load image into podman"
            echo "  just build-cluster-images                     — build and load a cluster's (control plane, worker)"
            echo "  just reset && just up && just init            — cycle the cluster"
            echo "  just kubeconfig                               — write kubeconfig"
            echo ""
            echo "  nix build .#kubernetes    — build K8s binaries only"
            echo "  nix build .#debug-image   — build debug image"
          '';
        };
      }
    );
}
