{
  ai = null;
  entrypoint = null;
  extraEnv = [
    {
      name = "KUBECONFIG";
      placement = u:
        u.BuildTime;
      value = "/etc/kubernetes/admin.conf";
    }
    { name = "VIGIL_LOG_BUFFER"; placement = u: u.BuildTime; value = "5000"; }
  ];
  mode = u:
    u.System;
  name = "nix-usernetes-node";
  nix = {
    buildUserCount = u:
      u.Dynamic;
    enableDaemon = false;
    sandboxPolicy = u:
      u.Auto;
    trustedUsers = [ "root" ];
  };
  packageLayers = [
    (u:
      u.Micro)
    (u:
      u.Custom {
        name = "nix-usernetes-node";
        packages = [
          { attrPath = "bash"; flakeInput = null; }
          { attrPath = "curl"; flakeInput = null; }
          { attrPath = "findutils"; flakeInput = null; }
          { attrPath = "gnugrep"; flakeInput = null; }
          { attrPath = "gnused"; flakeInput = null; }
          { attrPath = "iproute2"; flakeInput = null; }
          { attrPath = "jq"; flakeInput = null; }
          { attrPath = "openssl"; flakeInput = null; }
          { attrPath = "procps"; flakeInput = null; }
          { attrPath = "util-linux"; flakeInput = null; }
          { attrPath = "conntrack-tools"; flakeInput = null; }
          { attrPath = "containerd"; flakeInput = null; }
          { attrPath = "cri-tools"; flakeInput = null; }
          { attrPath = "ethtool"; flakeInput = null; }
          { attrPath = "iptables"; flakeInput = null; }
          { attrPath = "kmod"; flakeInput = null; }
          { attrPath = "nftables"; flakeInput = null; }
          { attrPath = "runc"; flakeInput = null; }
          { attrPath = "socat"; flakeInput = null; }
          { attrPath = "etcd"; flakeInput = null; }
          { attrPath = "kubernetes-helm"; flakeInput = null; }
        ];
      })
  ];
  pipeline = null;
  services = [
    {
      after = [];
      command = "/bin/u7s-containerd";
      enabled = true;
      killDelay = "10s";
      logs = u:
        u.Disabled;
      name = "containerd";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "containerd container runtime";
    }
    {
      after = [ "containerd" ];
      command = "/bin/u7s-image-preload";
      enabled = true;
      killDelay = null;
      logs = u:
        u.Disabled;
      name = "image-preload";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Ignore;
      summary = "import the bundled images into containerd";
    }
    {
      after = [];
      command = "/bin/u7s-etcd";
      enabled = true;
      killDelay = "10s";
      logs = u:
        u.Disabled;
      name = "etcd";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "etcd key-value store";
    }
    {
      after = [ "etcd" ];
      command = "/bin/u7s-kube-apiserver";
      enabled = true;
      killDelay = "10s";
      logs = u:
        u.Disabled;
      name = "kube-apiserver";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "Kubernetes API server";
    }
    {
      after = [ "kube-apiserver" ];
      command = "/bin/u7s-kube-controller-manager";
      enabled = true;
      killDelay = null;
      logs = u:
        u.Disabled;
      name = "kube-controller-manager";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "Kubernetes controller manager";
    }
    {
      after = [ "kube-apiserver" ];
      command = "/bin/u7s-kube-scheduler";
      enabled = true;
      killDelay = null;
      logs = u:
        u.Disabled;
      name = "kube-scheduler";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "Kubernetes scheduler";
    }
    {
      after = [ "containerd" "image-preload" ];
      command = "/bin/u7s-kubelet";
      enabled = true;
      killDelay = "20s";
      logs = u:
        u.Disabled;
      name = "kubelet";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "kubelet";
    }
    {
      after = [ "kube-apiserver" ];
      command = "/bin/u7s-kube-proxy";
      enabled = true;
      killDelay = null;
      logs = u:
        u.Disabled;
      name = "kube-proxy";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Restart;
      summary = "kube-proxy";
    }
    {
      after = [ "kube-apiserver" ];
      command = "/bin/u7s-cluster-bootstrap";
      enabled = true;
      killDelay = null;
      logs = u:
        u.Disabled;
      name = "cluster-bootstrap";
      onFailure = u:
        u.Restart;
      onSuccess = u:
        u.Ignore;
      summary = "apply the cluster's own resources (kube-dns, and a cluster's CoreDNS)";
    }
  ];
  shell = null;
  ssh = null;
  startup = {
    boot = [
      (u:
        u.DelegateCgroups)
      (u:
        u.Sysctls "/etc/sysctl.d/99-u7s.conf")
      (u:
        u.NftRuleset "/etc/u7s/masquerade.nft")
      (u:
        u.Script {
          command = "/bin/u7s-prepare";
          name = "prepare";
          required = true;
        })
    ];
    launch = u:
      u.System;
    session = u:
      u.None;
  };
  staticGid = null;
  staticUid = null;
  tls = null;
  user = {
    createUser = false;
    defaultShell = "/bin/fish";
    skeletonPath = "/etc/container-skel";
    supplementalGroups = [];
  };
}
