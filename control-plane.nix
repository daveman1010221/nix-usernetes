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
  name = "nix-usernetes-control-plane";
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
        name = "nix-usernetes-control-plane";
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
          { attrPath = "etcd"; flakeInput = null; }
          { attrPath = "kubernetes-helm"; flakeInput = null; }
        ];
      })
  ];
  pipeline = null;
  services = [
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
