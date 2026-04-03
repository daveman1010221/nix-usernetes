{
  description = "nix-usernetes — Nix-native rootless Kubernetes node image (kindest/node replacement)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = false;
        };

        # ── versioning ────────────────────────────────────────────────────────
        k8sVersion    = "1.33.10";
        k8sTag        = "v${k8sVersion}";
        k8sSha256     = "sha256-pN06vX2i9PUP/nlYNoKh+ZCFaQO10gCUjBLmnmMt2P8=";

        # Our patched cAdvisor fork (adds "f2fs": true to supportedFsType map)
        cadvisorForkOwner  = "daveman1010221";
        cadvisorForkBranch = "fix-f2fs-v0.52.1";
        cadvisorForkRev    = "v0.52.2-f2fs";
        cadvisorForkSha256 = "sha256-E4ikMWyfapmTbgD8Y359n0Cx953SY2mDy/QDRgLUnMU=";

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
          systemd
          containerd
          runc
          cri-tools
          etcd
          flannel
          helm
          openssl
          jq
          curl
          socat
          conntrack-tools
          ethtool
          ;

        cniPlugins = pkgs.cni-plugins;

        # ── patched cAdvisor source ───────────────────────────────────────────
        cadvisorPatchedSrc = pkgs.fetchFromGitHub {
          owner  = cadvisorForkOwner;
          repo   = "cadvisor";
          rev    = cadvisorForkRev;
          sha256 = cadvisorForkSha256;
        };

        # ── Kubernetes source ─────────────────────────────────────────────────
        kubernetesSrc = pkgs.fetchurl {
          url    = "https://github.com/kubernetes/kubernetes/archive/refs/tags/${k8sTag}.tar.gz";
          sha256 = k8sSha256;
        };

        # ── kubelet (+ friends) built from source with patched cAdvisor ───────
        kubernetesPatched = pkgs.stdenv.mkDerivation rec {
          pname   = "kubernetes-patched";
          version = k8sVersion;

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
          KUBE_GIT_MINOR      = "33";
          KUBE_GIT_COMMIT     = "nix-patched-cadvisor";
          KUBE_GIT_TREE_STATE = "clean";

          configurePhase = ''
            runHook preConfigure

            mkdir -p "$HOME" "$GOPATH"

            # ── Inject our patched cAdvisor into the vendor tree ───────────────
            # Replace vendor/github.com/google/cadvisor/ with our fork's code,
            # but leave go.mod and vendor/modules.txt UNCHANGED — both still
            # declare "github.com/google/cadvisor v0.52.1".
            #
            # Go's -mod=vendor consistency check only validates that version
            # strings are consistent across go.mod <-> modules.txt. It does NOT
            # hash the actual source files inside vendor/. Swapping the code
            # while keeping the declared version at v0.52.1 passes all checks.
            CADVISOR_VENDOR="vendor/github.com/google/cadvisor"

            echo "Replacing vendored cadvisor code with patched fork (${cadvisorForkRev})..."
            echo "  (keeping declared version as v0.52.1 to satisfy go.mod consistency)"
            rm -rf "$CADVISOR_VENDOR"
            cp -r --no-preserve=mode,ownership "${cadvisorPatchedSrc}" "$CADVISOR_VENDOR"

            # Belt-and-suspenders: verify strings are still consistent
            GO_MOD_VER=$(grep 'google/cadvisor' go.mod | grep -v '//' | awk '{print $2}')
            MODULES_TXT_VER=$(grep '# github.com/google/cadvisor' vendor/modules.txt | awk '{print $3}')
            echo "  go.mod version:      $GO_MOD_VER"
            echo "  vendor/modules.txt:  $MODULES_TXT_VER"
            if [ "$GO_MOD_VER" != "$MODULES_TXT_VER" ]; then
              echo "ERROR: cadvisor version mismatch between go.mod and vendor/modules.txt"
              exit 1
            fi
            echo "  ✓ Version strings consistent — vendor injection OK"

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
                  -X k8s.io/client-go/pkg/version.gitMinor=33
                  -X k8s.io/client-go/pkg/version.gitCommit=nix-patched-cadvisor
                  -X k8s.io/client-go/pkg/version.gitTreeState=clean
                  -X k8s.io/component-base/version.gitVersion=${k8sTag}
                  -X k8s.io/component-base/version.gitMajor=1
                  -X k8s.io/component-base/version.gitMinor=33
                  -X k8s.io/component-base/version.gitCommit=nix-patched-cadvisor
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
            mkdir -p "$out/bin"
            cp _output/bin/* "$out/bin/"
            runHook postInstall
          '';

          meta = {
            description = "Kubernetes binaries patched with f2fs-aware cAdvisor";
            platforms   = [ "x86_64-linux" ];
          };
        };

        # ── systemd units and configs baked into the image ──────────────────

        containerdUnit = pkgs.writeText "containerd.service" ''
          [Unit]
          Description=containerd container runtime
          After=network.target
          [Service]
          Environment=PATH=/bin:/sbin:/usr/bin:/usr/sbin:${containerd}/bin:${runc}/bin:${cri-tools}/bin:${pkgs.rootlesskit}/bin:${pkgs.slirp4netns}/bin
          ExecStartPre=-/sbin/modprobe overlay
          ExecStart=${containerd}/bin/containerd
          Restart=always
          RestartSec=5
          Delegate=yes
          KillMode=process
          OOMScoreAdjust=-999
          LimitNOFILE=1048576
          LimitNPROC=infinity
          LimitCORE=infinity
          [Install]
          WantedBy=multi-user.target
        '';

        etcdUnit = pkgs.writeText "etcd.service" ''
          [Unit]
          Description=etcd key-value store
          After=network.target

          [Service]
          ExecStartPre=/bin/sh -c 'until test -f /etc/kubernetes/pki/etcd/server.crt; do sleep 2; done'
          ExecStart=${etcd}/bin/etcd             --data-dir=/var/lib/etcd             --listen-client-urls=https://127.0.0.1:2379             --advertise-client-urls=https://127.0.0.1:2379             --listen-peer-urls=https://127.0.0.1:2380             --initial-advertise-peer-urls=https://127.0.0.1:2380             --initial-cluster=default=https://127.0.0.1:2380             --cert-file=/etc/kubernetes/pki/etcd/server.crt             --key-file=/etc/kubernetes/pki/etcd/server.key             --client-cert-auth=true             --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt             --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt             --peer-key-file=/etc/kubernetes/pki/etcd/peer.key             --peer-client-cert-auth=true             --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt             --snapshot-count=10000
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=multi-user.target
        '';

        apiserverUnit = pkgs.writeText "kube-apiserver.service" ''
          [Unit]
          Description=Kubernetes API Server
          After=etcd.service
          Requires=etcd.service

          [Service]
          ExecStartPre=/bin/sh -c 'until test -f /etc/kubernetes/pki/apiserver.crt; do sleep 2; done'
          ExecStart=${kubernetesPatched}/bin/kube-apiserver             --advertise-address=$HOST_IP             --bind-address=0.0.0.0             --allow-privileged=true             --authorization-mode=Node,RBAC             --client-ca-file=/etc/kubernetes/pki/ca.crt             --enable-admission-plugins=NodeRestriction             --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt             --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt             --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key             --etcd-servers=https://127.0.0.1:2379             --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt             --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key             --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname             --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt             --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key             --requestheader-allowed-names=front-proxy-client             --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt             --requestheader-extra-headers-prefix=X-Remote-Extra-             --requestheader-group-headers=X-Remote-Group             --requestheader-username-headers=X-Remote-User             --secure-port=6443             --service-account-issuer=https://kubernetes.default.svc.cluster.local             --service-account-key-file=/etc/kubernetes/pki/sa.pub             --service-account-signing-key-file=/etc/kubernetes/pki/sa.key             --service-cluster-ip-range=10.96.0.0/16             --tls-cert-file=/etc/kubernetes/pki/apiserver.crt             --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
          Restart=always
          RestartSec=5
          PassEnvironment=HOST_IP

          [Install]
          WantedBy=multi-user.target
        '';

        controllerManagerUnit = pkgs.writeText "kube-controller-manager.service" ''
          [Unit]
          Description=Kubernetes Controller Manager
          After=kube-apiserver.service
          Requires=kube-apiserver.service

          [Service]
          ExecStartPre=/bin/sh -c 'until test -f /etc/kubernetes/controller-manager.conf; do sleep 2; done'
          ExecStart=${kubernetesPatched}/bin/kube-controller-manager             --allocate-node-cidrs=true             --cluster-cidr=10.244.0.0/16             --cluster-name=kubernetes             --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt             --cluster-signing-key-file=/etc/kubernetes/pki/ca.key             --controllers=*,bootstrapsigner,tokencleaner             --kubeconfig=/etc/kubernetes/controller-manager.conf             --leader-elect=false             --root-ca-file=/etc/kubernetes/pki/ca.crt             --service-account-private-key-file=/etc/kubernetes/pki/sa.key             --service-cluster-ip-range=10.96.0.0/16             --use-service-account-credentials=true
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=multi-user.target
        '';

        schedulerUnit = pkgs.writeText "kube-scheduler.service" ''
          [Unit]
          Description=Kubernetes Scheduler
          After=kube-apiserver.service
          Requires=kube-apiserver.service

          [Service]
          ExecStartPre=/bin/sh -c 'until test -f /etc/kubernetes/scheduler.conf; do sleep 2; done'
          ExecStart=${kubernetesPatched}/bin/kube-scheduler             --kubeconfig=/etc/kubernetes/scheduler.conf             --leader-elect=false
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=multi-user.target
        '';

        kubeletUnit = pkgs.writeText "kubelet.service" ''
          [Unit]
          Description=kubelet
          After=containerd.service
          Requires=containerd.service

          [Service]
          Environment=PATH=/bin:/sbin:/usr/bin:/usr/sbin:${kubernetesPatched}/bin:${containerd}/bin:${runc}/bin:${cri-tools}/bin
          ExecStartPre=/bin/sh -c 'grep -q u7s-node /etc/hosts || echo "127.0.0.1 u7s-node" >> /etc/hosts'
          ExecStartPre=/bin/sh -c 'until test -f /etc/kubernetes/kubelet.conf; do sleep 2; done'
          ExecStart=${kubernetesPatched}/bin/kubelet             --config=/etc/kubelet/kubelet-config.yaml             --kubeconfig=/etc/kubernetes/kubelet.conf             --v=2
          Restart=always
          RestartSec=10
          TimeoutStopSec=60

          [Install]
          WantedBy=multi-user.target
        '';

        kubeProxyUnit = pkgs.writeText "kube-proxy.service" ''
          [Unit]
          Description=kube-proxy
          After=network.target kube-apiserver.service
          [Service]
          Environment=PATH=/bin:/sbin:/usr/bin:/usr/sbin:${kubernetesPatched}/bin:${pkgs.nftables}/bin
          ExecStart=${kubernetesPatched}/bin/kube-proxy \
            --kubeconfig=/etc/kubernetes/admin.conf \
            --proxy-mode=iptables \
            --cluster-cidr=10.244.0.0/24 \
            --conntrack-max-per-core=0
          Restart=always
          RestartSec=5
          [Install]
          WantedBy=multi-user.target
        '';

        kubeletConfig = pkgs.writeText "kubelet-config.yaml" ''
          apiVersion: kubelet.config.k8s.io/v1beta1
          kind: KubeletConfiguration
          featureGates:
            KubeletInUserNamespace: true
          failSwapOn: false
          cgroupDriver: cgroupfs
          cgroupsPerQOS: false
          enforceNodeAllocatable: []
          containerRuntimeEndpoint: "unix:///run/containerd/containerd.sock"
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
          version = 3
          [plugins."io.containerd.cri.v1.runtime"]
            sandbox_image = "registry.k8s.io/pause:3.10"
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
        '';

        cniConfig = pkgs.writeText "10-u7s.conflist" ''
          {
            "cniVersion": "1.0.0",
            "name": "u7s",
            "plugins": [
              {
                "type": "ptp",
                "ipMasq": true,
                "ipam": {
                  "type": "host-local",
                  "ranges": [[{ "subnet": "10.244.0.0/24" }]],
                  "routes": [{ "dst": "0.0.0.0/0" }]
                }
              },
              {
                "type": "portmap",
                "capabilities": { "portMappings": true }
              }
            ]
          }
        '';

        # ── systemd units derivation ─────────────────────────────────────────
        # pkgs.systemd does not ship unit files — they're generated by the NixOS
        # module system. We write the minimal set needed to boot in a container
        # as literal text, using canonical upstream unit file content.
        systemdUnits = pkgs.runCommand "systemd-container-units" {} ''
          mkdir -p $out/etc/systemd/system
          mkdir -p $out/etc

          # default.target → multi-user.target
          ln -s multi-user.target $out/etc/systemd/system/default.target

          cat > $out/etc/systemd/system/multi-user.target << 'UNIT'
[Unit]
Description=Multi-User System
Documentation=man:systemd.special(7)
Requires=basic.target
Conflicts=rescue.service rescue.target
After=basic.target rescue.service rescue.target
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/basic.target << 'UNIT'
[Unit]
Description=Basic System
Documentation=man:systemd.special(7)
Requires=sysinit.target
After=sysinit.target
Wants=sockets.target timers.target paths.target
After=sockets.target timers.target paths.target
UNIT

          cat > $out/etc/systemd/system/sysinit.target << 'UNIT'
[Unit]
Description=System Initialization
Documentation=man:systemd.special(7)
Conflicts=emergency.service emergency.target
After=emergency.service emergency.target
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/sockets.target << 'UNIT'
[Unit]
Description=Sockets
Documentation=man:systemd.special(7)
UNIT

          cat > $out/etc/systemd/system/timers.target << 'UNIT'
[Unit]
Description=Timers
Documentation=man:systemd.special(7)
UNIT

          cat > $out/etc/systemd/system/paths.target << 'UNIT'
[Unit]
Description=Paths
Documentation=man:systemd.special(7)
UNIT

          cat > $out/etc/systemd/system/network.target << 'UNIT'
[Unit]
Description=Network
Documentation=man:systemd.special(7)
After=network-pre.target
UNIT

          cat > $out/etc/systemd/system/network-pre.target << 'UNIT'
[Unit]
Description=Network (Pre)
Documentation=man:systemd.special(7)
UNIT

          cat > $out/etc/systemd/system/network-online.target << 'UNIT'
[Unit]
Description=Network is Online
Documentation=man:systemd.special(7)
After=network.target
UNIT

          cat > $out/etc/systemd/system/local-fs.target << 'UNIT'
[Unit]
Description=Local File Systems
Documentation=man:systemd.special(7)
DefaultDependencies=no
Conflicts=shutdown.target
After=local-fs-pre.target
OnFailure=emergency.target
UNIT

          cat > $out/etc/systemd/system/local-fs-pre.target << 'UNIT'
[Unit]
Description=Local File Systems (Pre)
Documentation=man:systemd.special(7)
DefaultDependencies=no
Conflicts=shutdown.target
UNIT

          cat > $out/etc/systemd/system/swap.target << 'UNIT'
[Unit]
Description=Swaps
Documentation=man:systemd.special(7)
UNIT

          cat > $out/etc/systemd/system/slices.target << 'UNIT'
[Unit]
Description=Slices
Documentation=man:systemd.special(7)
Wants=system.slice
UNIT

          cat > $out/etc/systemd/system/system.slice << 'UNIT'
[Unit]
Description=System Slice
Documentation=man:systemd.special(7)
DefaultDependencies=no
UNIT

          cat > $out/etc/systemd/system/rescue.target << 'UNIT'
[Unit]
Description=Rescue Mode
Documentation=man:systemd.special(7)
Requires=sysinit.target rescue.service
After=sysinit.target rescue.service
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/rescue.service << 'UNIT'
[Unit]
Description=Rescue Shell
DefaultDependencies=no
Conflicts=shutdown.target
After=sysinit.target
Before=shutdown.target

[Service]
Type=idle
ExecStart=-/bin/sh
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
KillMode=process
IgnoreSIGPIPE=no
UNIT

          cat > $out/etc/systemd/system/emergency.target << 'UNIT'
[Unit]
Description=Emergency Mode
Documentation=man:systemd.special(7)
Requires=emergency.service
After=emergency.service
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/emergency.service << 'UNIT'
[Unit]
Description=Emergency Shell
DefaultDependencies=no
Conflicts=shutdown.target
After=sysinit.target
Before=shutdown.target

[Service]
Type=idle
ExecStart=-/bin/sh
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
KillMode=process
IgnoreSIGPIPE=no
UNIT

          cat > $out/etc/systemd/system/shutdown.target << 'UNIT'
[Unit]
Description=Shutdown
Documentation=man:systemd.special(7)
DefaultDependencies=no
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/reboot.target << 'UNIT'
[Unit]
Description=Reboot
Documentation=man:systemd.special(7)
DefaultDependencies=no
Requires=shutdown.target
After=shutdown.target
AllowIsolate=yes
UNIT

          cat > $out/etc/systemd/system/poweroff.target << 'UNIT'
[Unit]
Description=Power-Off
Documentation=man:systemd.special(7)
DefaultDependencies=no
Requires=shutdown.target
After=shutdown.target
AllowIsolate=yes
UNIT

          # os-release
          printf 'ID=nix-usernetes
NAME=nix-usernetes
PRETTY_NAME="nix-usernetes"
'             > $out/etc/os-release
        '';

        # ── OCI layer image ───────────────────────────────────────────────────
        nodeImage = pkgs.dockerTools.buildLayeredImage {
          name = "nix-usernetes-node";
          tag  = k8sVersion;

          contents = pkgs.lib.flatten [
            bash
            cniPlugins
            conntrack-tools
            containerd
            coreutils
            cri-tools
            curl
            ethtool
            findutils
            gnugrep
            iproute2
            iptables
            jq
            kmod
            openssl
            pkgs.cacert
            pkgs.dockerTools.fakeNss
            pkgs.dockerTools.usrBinEnv
            pkgs.gnused
            pkgs.nftables
            procps
            runc
            socat
            util-linux

            # All control plane components run as native systemd units — no container pulls
            kubernetesPatched
            etcd
            helm

            systemd
            systemdUnits
          ];

          extraCommands = ''
            # containerd config — use systemd cgroup driver to match kubelet
            mkdir -p etc/containerd
            cp ${containerdConfig} etc/containerd/config.toml

            # CA certificates
            mkdir -p etc/ssl/certs
            ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
            ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-bundle.crt

            # CNI binaries
            mkdir -p opt/cni/bin
            for f in ${cniPlugins}/bin/*; do
              ln -sf "$f" opt/cni/bin/$(basename "$f")
            done

            # CNI config — bridge+host-local, no daemon required
            mkdir -p etc/cni/net.d
            cp ${cniConfig} etc/cni/net.d/10-u7s.conflist

            # kubelet config — kept outside /etc/kubernetes so the u7s-pki
            # volume mount doesn't shadow it
            mkdir -p etc/kubelet
            cp ${kubeletConfig} etc/kubelet/kubelet-config.yaml

            # /etc/kubernetes is populated at runtime by just init
            mkdir -p etc/kubernetes/manifests etc/kubernetes/pki

            # systemd units — all control plane components run as native systemd
            # services using our Nix-built binaries. No container pulls, no pause
            # images, no CNI needed for control plane.
            mkdir -p etc/systemd/system/multi-user.target.wants
            cp ${containerdUnit}        etc/systemd/system/containerd.service
            cp ${etcdUnit}              etc/systemd/system/etcd.service
            cp ${apiserverUnit}         etc/systemd/system/kube-apiserver.service
            cp ${controllerManagerUnit} etc/systemd/system/kube-controller-manager.service
            cp ${schedulerUnit}         etc/systemd/system/kube-scheduler.service
            cp ${kubeletUnit}           etc/systemd/system/kubelet.service
            cp ${kubeProxyUnit} etc/systemd/system/kube-proxy.service

            ln -sf /etc/systemd/system/kube-proxy.service etc/systemd/system/multi-user.target.wants/kube-proxy.service
            ln -sf /etc/systemd/system/containerd.service         etc/systemd/system/multi-user.target.wants/containerd.service
            ln -sf /etc/systemd/system/etcd.service                 etc/systemd/system/multi-user.target.wants/etcd.service
            ln -sf /etc/systemd/system/kube-apiserver.service       etc/systemd/system/multi-user.target.wants/kube-apiserver.service
            ln -sf /etc/systemd/system/kube-controller-manager.service etc/systemd/system/multi-user.target.wants/kube-controller-manager.service
            ln -sf /etc/systemd/system/kube-scheduler.service       etc/systemd/system/multi-user.target.wants/kube-scheduler.service
            ln -sf /etc/systemd/system/kubelet.service              etc/systemd/system/multi-user.target.wants/kubelet.service

            # Standard dirs
            mkdir -p var/lib/kubelet var/lib/etcd
            mkdir -p run/containerd run/kubernetes
            mkdir -p lib/modules
            mkdir -p tmp

            touch etc/resolv.conf
            echo "u7s-node" > etc/hostname
          '';

          config = {
            Cmd        = [ "/sbin/init" ];
            Entrypoint = [];
            Env = [
              "container=docker"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
              "SSL_CERT_DIR=/etc/ssl/certs"
              "PATH=/bin:/sbin:/usr/bin:/usr/sbin:${kubernetesPatched}/bin:${containerd}/bin:${runc}/bin:${cri-tools}/bin"
              "KUBECONFIG=/etc/kubernetes/admin.conf"
            ];
            Volumes = {
              "/sys/fs/cgroup"        = {};
              "/lib/modules"          = {};
              "/run"                  = {};
              "/etc/kubernetes"       = {};
              "/var/lib/kubelet"      = {};
              "/var/lib/etcd"         = {};
              "/var/lib/containerd"   = {};
            };
            Labels = {
              "org.opencontainers.image.title"       = "nix-usernetes-node";
              "org.opencontainers.image.description" = "Single-node rootless Kubernetes for developer workstations";
              "org.opencontainers.image.version"     = k8sVersion;
            };
          };
        };

      in {
        packages = {
          kubernetes  = kubernetesPatched;
          node-image  = nodeImage;
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
            helm
            pkgs.kubectl
            pkgs.just
            openssl
            jq
            curl
            pkgs.skopeo
          ];
          shellHook = ''
            echo "nix-usernetes dev shell"
            echo "  nix build .#kubernetes    — build patched K8s binaries only"
            echo "  nix build .#node-image    — build full OCI node image"
            echo "  nix build                  — same as .#node-image"
          '';
        };
      }
    );
}
