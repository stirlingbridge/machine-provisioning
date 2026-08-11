#!/usr/bin/env bash
#
# k3s-node.sh -- install a single-node Kubernetes cluster using k3s, ready for
# hosting applications with TLS.
#
# By default, installs k3s and cert-manager, provisions the Gateway API (k3s's
# bundled traefik is kept and used as the Gateway API implementation, with a
# Gateway named "stack-gateway" for workloads to attach their HTTPRoutes to),
# and creates Let's Encrypt ClusterIssuers. Debian and Ubuntu only.
#
# With --nginx-ingress, the legacy Ingress API is provisioned instead: traefik
# is disabled and the nginx ingress controller is installed. See the notes above
# the --nginx-ingress option below.
#
# The latest release of each component is installed rather than a pinned
# version.
#
# Usage:
#   k3s-node.sh [-y] [--letsencrypt-email <email>]
#               [--letsencrypt-staging]
#               [--do-dns-access-token <token>]
#               [--tls-san <name>]
#               [--wildcard-domain <domain>] [--nginx-ingress]
#               [--kata]
#               [--image-registry <host>] [--image-registry-username <user>]
#               [--image-registry-password <password>]
#
#   -y                          Don't prompt for confirmation before making
#                               changes (required for unattended provisioning).
#   --tls-san                   Extra name to include in the Kubernetes API
#                               server's serving certificate, so kubectl can
#                               reach the cluster by that name. May be repeated.
#                               $MACHINE_FQDN is always included when set.
#   --letsencrypt-email         Contact address for Let's Encrypt. Without it
#                               the ClusterIssuers are not created, only written
#                               to $HOME as template files to complete by hand.
#   --letsencrypt-staging       Issue certificates from Let's Encrypt's staging
#                               environment rather than production. The staging
#                               environment's rate limits are far higher, at the
#                               cost of certificates signed by an untrusted root:
#                               browsers and other clients will reject them. Use
#                               while working out a machine's DNS, firewall and
#                               listener configuration, so that a broken setup
#                               does not burn the production rate limit, then
#                               re-run without this option for real certificates.
#
#                               Both the production and staging ClusterIssuers
#                               are always created; this option selects which of
#                               them the Gateway is annotated with, i.e. which
#                               one is used for certificates that this script's
#                               Gateway causes to be issued.
#   --do-dns-access-token       DigitalOcean API token, enabling an additional
#                               DNS-01 ClusterIssuer (needed for wildcard certs).
#   --nginx-ingress             Provision the legacy Ingress API rather than the
#                               Gateway API: k3s's bundled traefik is disabled
#                               and the nginx ingress controller is installed
#                               instead, with per-application Let's Encrypt
#                               certificates obtained over HTTP-01 from Ingress
#                               resources. Note that ingress-nginx is retired
#                               upstream and no longer receives fixes of any
#                               kind, including security fixes.
#
#                               Without this option the Gateway API is
#                               provisioned: traefik is kept and its Gateway API
#                               provider enabled, which also brings in the
#                               Gateway API CRDs; a Gateway named
#                               "stack-gateway" is created in the kube-system
#                               namespace, accepting routes from all namespaces;
#                               and cert-manager's Gateway API support is turned
#                               on.
#
#                               Workloads then attach an HTTPRoute to that
#                               Gateway with a parentRef, rather than creating an
#                               Ingress. Nothing in a workload names traefik, so
#                               the choice of implementation stays a property of
#                               the machine and can be changed here later.
#
#                               The Gateway is created by this script as a plain
#                               resource, not by the traefik helm chart: the
#                               stack utility adds and removes per-application
#                               HTTPS listeners on it at deploy time (obtaining
#                               each certificate over HTTP-01), and a chart-owned
#                               Gateway would be re-synced on chart upgrades,
#                               silently dropping those listeners.
#
#                               Note that the traffic-routing resources are
#                               stable (GA), but cert-manager's Gateway API
#                               support is beta.
#   --wildcard-domain           Domain to obtain a wildcard certificate for, e.g.
#                               "example.com" for a "*.example.com" certificate,
#                               served by the Gateway's HTTPS listener. Not
#                               compatible with --nginx-ingress, and requires
#                               --do-dns-access-token, because a wildcard
#                               certificate can only be issued over DNS-01.
#
#                               In the Gateway API the certificate belongs to the
#                               Gateway's listener rather than to each workload,
#                               so one wildcard certificate covers every
#                               application on the machine. Without this option
#                               the Gateway starts with an HTTP listener only,
#                               and HTTPS listeners with individual HTTP-01
#                               certificates are added per application (by the
#                               stack utility at deploy time, or by hand).
#   --kata                      Additionally install Kata Containers, so that a
#                               pod can be run inside its own lightweight VM
#                               with its own kernel, rather than sharing the
#                               host's kernel as an ordinary container does.
#
#                               This is opt-in per workload: the installation
#                               creates RuntimeClasses ("kata", and
#                               "kata-qemu-runtime-rs" naming the shim
#                               explicitly), and only a pod that asks for one
#                               gets a VM:
#
#                                 spec:
#                                   runtimeClassName: kata
#
#                               Everything else -- k3s's own system pods,
#                               traefik, cert-manager, and any workload that
#                               says nothing about a runtime class -- keeps
#                               running as an ordinary container, and the
#                               cluster is otherwise unchanged. Nothing about
#                               the cluster's external behaviour differs.
#
#                               Kata is installed with upstream's kata-deploy
#                               helm chart, whose DaemonSet places the shim,
#                               hypervisor, guest kernel and guest rootfs on the
#                               node, reconfigures k3s's containerd and restarts
#                               k3s. Only the default hypervisor for the
#                               architecture is installed, not the full set that
#                               the chart can install.
#
#                               A VM needs hardware virtualization, which on a
#                               cloud machine means the provider must allow
#                               nested virtualization. This is checked before
#                               anything is installed, and the script fails
#                               there if the host cannot create a VM, rather
#                               than leaving a cluster whose kata RuntimeClass
#                               never starts a pod. Expect pods on a kata
#                               RuntimeClass to start more slowly and to use
#                               more memory than ordinary ones.
#   --image-registry            Host name of a container image registry, and the
#   --image-registry-username   credentials to authenticate to it with, so that
#   --image-registry-password   the cluster can pull private images from it.
#
#                               These configure *credentials for* that one
#                               registry; they do not decide where images are
#                               pulled from. Pulls are directed by the image
#                               names in the workloads themselves, and images
#                               from registries needing no credentials are
#                               unaffected. Credentials are configured at the
#                               containerd level, so workloads pulling private
#                               images need no imagePullSecrets.
#
#                               Only one registry is supported. A machine that
#                               needs credentials for two or more private
#                               registries is not currently handled -- that
#                               would mean several entries under the "configs"
#                               key of /etc/rancher/k3s/registries.yaml.
#
# Environment:
#   BPI_INSTALL_SKIP_PACKAGES   If set, skip the package install phase.
#   MACHINE_FQDN                If set, added to the API server certificate as
#                               though passed with --tls-san.
#
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

install_dir=~/bin

DO_TOKEN=""
IMAGE_REGISTRY=""
IMAGE_REGISTRY_USERNAME=""
IMAGE_REGISTRY_PASSWORD=""
LETSENCRYPT_EMAIL=""
LETSENCRYPT_STAGING=false
NEEDS_WARN=true
TLS_SAN_ARGS=""
GATEWAY_API=true
WILDCARD_DOMAIN=""
KATA=false

# The Gateway that workloads attach their HTTPRoutes to, and the name of the
# secret its wildcard HTTPS listener (if any) reads its certificate from. The
# name and namespace are a contract with the stack utility, which attaches
# routes to this Gateway and adds per-application HTTPS listeners to it.
GATEWAY_NAME="stack-gateway"
GATEWAY_NAMESPACE="kube-system"
WILDCARD_SECRET_NAME="wildcard-tls"

function die {
  echo "ERROR: $*" 1>&2
  exit 1
}

while (( "$#" )); do
   case $1 in
      -y)
         NEEDS_WARN=false
         ;;
      --letsencrypt-email)
         shift&&LETSENCRYPT_EMAIL="$1"||die
         ;;
      --letsencrypt-staging)
         LETSENCRYPT_STAGING=true
         ;;
      --image-registry)
         shift&&IMAGE_REGISTRY="$1"||die
         ;;
      --image-registry-username)
         shift&&IMAGE_REGISTRY_USERNAME="$1"||die
         ;;
      --image-registry-password)
         shift&&IMAGE_REGISTRY_PASSWORD="$1"||die
         ;;
      --tls-san)
         shift&&TLS_SAN_ARGS="${TLS_SAN_ARGS} --tls-san=$1"||die "--tls-san requires a value"
         ;;
      --do-dns-access-token)
         shift&&DO_TOKEN="$(echo -n "$1" | base64 -w0)"||die
         ;;
      --nginx-ingress)
         GATEWAY_API=false
         ;;
      # The Gateway API is now the default, so this is accepted but does
      # nothing, for the benefit of callers that still pass it.
      --gateway-api)
         GATEWAY_API=true
         ;;
      --wildcard-domain)
         shift&&WILDCARD_DOMAIN="$1"||die "--wildcard-domain requires a value"
         ;;
      --kata)
         KATA=true
         ;;
         *)
         echo "Unrecognized argument: $1" 1>&2
         ;;
   esac
   shift
done

# A wildcard certificate can only be obtained over DNS-01, which needs both the
# DNS provider token and a Let's Encrypt contact address, so fail early rather
# than provisioning a Gateway whose HTTPS listener can never become ready.
if [[ -n "$WILDCARD_DOMAIN" ]]; then
  if [[ "$GATEWAY_API" != "true" ]]; then
    die "--wildcard-domain is not compatible with --nginx-ingress: a wildcard certificate is served by the Gateway's HTTPS listener"
  fi
  if [[ -z "$DO_TOKEN" ]]; then
    die "--wildcard-domain requires --do-dns-access-token, since a wildcard certificate can only be issued over DNS-01"
  fi
  if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    die "--wildcard-domain requires --letsencrypt-email"
  fi
fi

# Kata runs each pod in a real VM, so the host has to be able to create one. On
# a cloud machine that means the provider has to allow nested virtualization,
# which several do not, and which is not something a machine advertises: the
# only honest way to know is to ask the kernel to make a VM.
#
# This runs here, before the confirmation prompt and before anything at all is
# installed, so that a machine that cannot do it is rejected outright. The
# alternative is a fully provisioned cluster whose kata RuntimeClass silently
# fails to start any pod, which is a much worse thing to discover.
function check_virtualization {
  local arch
  arch=$(uname -m)

  case "$arch" in
    x86_64)
      # The CPU flag the hypervisor exposes to us: vmx on Intel, svm on AMD.
      # Without it the kernel cannot load its KVM module at all, and this is
      # precisely what a provider that disallows nested virtualization hides.
      if ! grep -Eq '^flags[[:space:]]*:.*[[:space:]](vmx|svm)([[:space:]]|$)' /proc/cpuinfo; then
        die "this machine's CPU exposes neither the vmx nor the svm virtualization flag, so it cannot run Kata Containers.
On a cloud machine that usually means the provider does not allow nested
virtualization on this instance type or in this region. Provision without
--kata, or use a machine that does."
      fi
      ;;
    aarch64)
      # arm64 virtualization is not a CPU flag but a matter of the machine
      # being booted at the right exception level, which /dev/kvm and the
      # ioctl check below report on directly.
      ;;
    *)
      die "Kata Containers is not supported on $arch by this script (kata-deploy ships x86_64 and aarch64 artifacts)"
      ;;
  esac

  # The modules are normally autoloaded when the flag is present, but not on
  # every image, and a missing /dev/kvm below would then be misreported as the
  # host refusing virtualization. Only attempted when there is no /dev/kvm
  # already: this runs before the confirmation prompt, so on a machine that
  # needs nothing it should change nothing.
  if [[ ! -e /dev/kvm ]]; then
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || sudo modprobe kvm 2>/dev/null || true
  fi

  if [[ ! -e /dev/kvm ]]; then
    die "/dev/kvm does not exist, so this machine cannot run Kata Containers.
The KVM kernel module is not loaded and could not be loaded. On a cloud machine
this usually means nested virtualization is not available here."
  fi

  # Everything above is circumstantial. This is the real check: open the device
  # and ask KVM to create a VM, which is exactly what the hypervisor will do for
  # every kata pod. KVM_GET_API_VERSION is _IO(0xAE, 0x00) and has answered 12
  # since 2007; KVM_CREATE_VM is _IO(0xAE, 0x01) and returns a file descriptor
  # for the new VM.
  #
  # python3 is present on the Debian and Ubuntu cloud images (cloud-init is
  # written in it), but this script can also be run by hand somewhere it is not,
  # and the checks above are worth having on their own.
  if ! command -v python3 > /dev/null 2>&1; then
    echo "WARNING: python3 is not installed, so /dev/kvm was not exercised."
    echo "The CPU and module checks passed; if this host still cannot create a VM,"
    echo "that will not show up until a pod on a kata RuntimeClass fails to start."
    return 0
  fi

  local kvm_error
  if ! kvm_error=$(sudo python3 - <<'PYEOF' 2>&1
import fcntl, os, sys

KVM_GET_API_VERSION = 0xAE00
KVM_CREATE_VM = 0xAE01

try:
    fd = os.open("/dev/kvm", os.O_RDWR | os.O_CLOEXEC)
except OSError as e:
    sys.exit("cannot open /dev/kvm: %s" % e)

try:
    version = fcntl.ioctl(fd, KVM_GET_API_VERSION, 0)
except OSError as e:
    sys.exit("KVM_GET_API_VERSION failed: %s" % e)
if version != 12:
    sys.exit("unexpected KVM API version %d (expected 12)" % version)

try:
    vm = fcntl.ioctl(fd, KVM_CREATE_VM, 0)
except OSError as e:
    sys.exit("KVM_CREATE_VM failed: %s" % e)
os.close(vm)
os.close(fd)
PYEOF
  ); then
    die "this machine cannot create a virtual machine, so it cannot run Kata Containers: ${kvm_error}
/dev/kvm is present but unusable. On a cloud machine this usually means nested
virtualization is not really available on this instance type or in this region.
Provision without --kata, or use a machine that does support it."
  fi

  echo "This machine can create VMs (KVM is present and usable)"
}

if [[ "$KATA" == "true" ]]; then
  echo "**************************************************************************************"
  echo "Checking that this machine can run virtual machines, as --kata requires"
  check_virtualization
fi

# All four ClusterIssuers are created below; these name the two that anything
# provisioned by this script points at. Staging and production differ only in
# the ACME server they talk to, so the choice is made once here and used both
# for the Gateway's annotation and for the closing advice printed to the user.
if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
  HTTP01_ISSUER="letsencrypt-staging"
  DNS01_ISSUER="letsencrypt-staging-dns"
else
  HTTP01_ISSUER="letsencrypt-prod"
  DNS01_ISSUER="letsencrypt-prod-dns"
fi
# The issuer the Gateway is annotated with: in wildcard mode the certificate can
# only be issued over DNS-01, otherwise HTTP-01 covers the per-application
# listeners that the stack utility adds later.
if [[ -n "$WILDCARD_DOMAIN" ]]; then
  GATEWAY_ISSUER="$DNS01_ISSUER"
else
  GATEWAY_ISSUER="$HTTP01_ISSUER"
fi

function retry {
  local try=0
  local max=5
  local delay=10
  while [ $try -lt $max ]; do
    try=$((try + 1))
    echo "Try $try of $* ..."
    "$@" && RC=$? || RC=$?
    if [ $RC -eq 0 ]; then
      return 0
    else
      sleep $delay
    fi
  done
  return 1
}

# Skip the package install stuff if so directed
if ! [[ -n "$BPI_INSTALL_SKIP_PACKAGES" ]]; then

# First display a reasonable warning to the user unless run with -y
if [[ "$NEEDS_WARN" == "true" ]]; then
  echo "**************************************************************************************"
  echo "This script requires sudo privilege. It installs k3s and a single-node"
  echo "Kubernetes cluster on this machine, along with other required packages."
  echo "Only proceed if you are sure you want to make those changes to this machine."
  echo "**************************************************************************************"
  read -p "Are you sure you want to proceed? " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Determine if we are on Debian or Ubuntu
linux_distro=$(lsb_release -a 2>/dev/null | grep "^Distributor ID:" | cut -f 2)
# Some systems don't have lsb_release installed (e.g. ChromeOS) and so we try to
# use /etc/os-release instead
if [[ -z "$linux_distro" ]]; then
  if [[ -f "/etc/os-release" ]]; then
    distro_name_string=$(grep "^NAME=" /etc/os-release | cut -d '=' -f 2)
    if [[ $distro_name_string =~ Debian ]]; then
      linux_distro="Debian"
    elif [[ $distro_name_string =~ Ubuntu ]]; then
      linux_distro="Ubuntu"
    fi
  else
    echo "Failed to identify distro: /etc/os-release doesn't exist"
    exit 1
  fi
fi
case $linux_distro in
  Debian)
    echo "Installing k3s for Debian"
    ;;
  Ubuntu)
    echo "Installing k3s for Ubuntu"
    ;;
  *)
    echo "ERROR: Detected unknown distribution $linux_distro, can't install k3s"
    exit 1
    ;;
esac

# dismiss the popups
export DEBIAN_FRONTEND=noninteractive

# Note: this script used to remove any distro-packaged docker components here.
# That is a prerequisite for installing Docker CE, not for installing k3s, and
# had leaked over from the docker provisioning script. k3s brings its own
# containerd and runc and does not use the distro ones, so nothing needs to be
# removed. (It also removed podman-docker, which podman.sh installs.)

# Enable stop on error now, since we needed it off for the code above
set -euo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

echo "**************************************************************************************"
echo "Installing extra packages"
sudo apt -y update
sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install jq git curl wget

echo "**************************************************************************************"
echo "Installing k3s"
k3s_installer_file=$HOME/install-k3s.sh
curl -sfL https://get.k3s.io -o ${k3s_installer_file}
chmod +x ${k3s_installer_file}

# The API server's serving certificate is only valid for the names it was issued
# for, so the machine's own FQDN has to be added for kubectl to work remotely.
if [[ -n "${MACHINE_FQDN:-}" ]] && [[ "$TLS_SAN_ARGS" != *"--tls-san=${MACHINE_FQDN}"* ]]; then
  TLS_SAN_ARGS="${TLS_SAN_ARGS} --tls-san=${MACHINE_FQDN}"
fi

if [[ "$GATEWAY_API" == "true" ]]; then
  # traefik is kept, and configured through a HelmChartConfig placed in k3s's
  # auto-deploying manifests directory before the first start, so that it is
  # applied as traefik is first deployed rather than needing a restart. Enabling
  # the kubernetesGateway provider also installs the Gateway API CRDs.
  #
  # The chart's own Gateway is disabled: the Gateway is created directly by this
  # script further below instead, because the stack utility adds and removes
  # per-application HTTPS listeners on it at deploy time, and a chart-owned
  # Gateway would be re-synced on chart upgrades, dropping those listeners.
  echo "Configuring traefik as the Gateway API implementation"
  sudo mkdir -p /var/lib/rancher/k3s/server/manifests

  traefik_config_file=$(mktemp)
  cat > "$traefik_config_file" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
    gateway:
      enabled: false
EOF

  sudo mv "$traefik_config_file" /var/lib/rancher/k3s/server/manifests/k3s-traefik-config.yaml
  sudo chown root:root /var/lib/rancher/k3s/server/manifests/k3s-traefik-config.yaml
  sudo chmod 644 /var/lib/rancher/k3s/server/manifests/k3s-traefik-config.yaml

  export INSTALL_K3S_EXEC="${TLS_SAN_ARGS# }"
else
  export INSTALL_K3S_EXEC="--disable=traefik${TLS_SAN_ARGS}"
fi

sudo --preserve-env=INSTALL_K3S_EXEC ${k3s_installer_file}
echo "Installed k3s"

if [[ "$GATEWAY_API" == "true" ]]; then

echo "**************************************************************************************"
echo "Waiting for the Gateway API CRDs installed by traefik..."
# cert-manager only checks for the Gateway API on startup, so the CRDs need to be
# in place before its Gateway API support is enabled further below.
if ! retry sudo kubectl wait --for=create crd/gateways.gateway.networking.k8s.io --timeout=60s; then
  die "the Gateway API CRDs did not appear; check that traefik deployed (kubectl -n kube-system get helmchart,pods)"
fi
echo "Gateway API CRDs are present"

echo "**************************************************************************************"
echo "Creating the ${GATEWAY_NAME} Gateway"
# The listener ports must be traefik's entrypoint ports (web 8000, websecure
# 8443, which its service exposes as 80 and 443) -- traefik only serves
# listeners whose port matches an entrypoint.
#
# The cluster-issuer annotation is how cert-manager knows to issue certificates
# for this Gateway's HTTPS listeners; cert-manager is installed further below,
# and the annotation is inert until then. Which issuer is named was decided
# above, from --wildcard-domain (DNS-01 vs HTTP-01) and --letsencrypt-staging
# (staging vs production ACME server).
gateway_manifest_file=$(mktemp)
cat > "$gateway_manifest_file" <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: ${GATEWAY_ISSUER}
spec:
  gatewayClassName: traefik
  listeners:
    - name: web
      port: 8000
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All
EOF

if [[ -n "$WILDCARD_DOMAIN" ]]; then
  cat >> "$gateway_manifest_file" <<EOF
    - name: websecure
      port: 8443
      protocol: HTTPS
      hostname: "*.${WILDCARD_DOMAIN}"
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: ${WILDCARD_SECRET_NAME}
EOF
fi

retry sudo kubectl apply -f "$gateway_manifest_file" || die "failed to create the ${GATEWAY_NAME} Gateway"
rm -f "$gateway_manifest_file"

else

echo "**************************************************************************************"
echo "Installing nginx ingress"
# The manifest on the main branch is the one generated for the latest release.
sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml

lb_manifest_file=$(mktemp)
cat > "$lb_manifest_file" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller-loadbalancer
  namespace: ingress-nginx
spec:
  selector:
    app.kubernetes.io/component: controller
    app.kubernetes.io/instance: ingress-nginx
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: http
      port: 80
      protocol: TCP
      targetPort: 80
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
  type: LoadBalancer
EOF

sudo kubectl apply -f "$lb_manifest_file"
rm -f "$lb_manifest_file"

# --overwrite so that re-running this script isn't an error
sudo kubectl annotate --overwrite ingressclass nginx ingressclass.kubernetes.io/is-default-class=true

echo "Installed nginx ingress"

fi

echo "**************************************************************************************"
echo "Installing cert-manager"

sudo kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for the webhook in particular: creating a ClusterIssuer before it is
# serving fails, which is what the retries below the ClusterIssuers cover.
echo "Waiting for cert-manager to become available..."
if ! sudo kubectl wait --namespace cert-manager \
    --for=condition=Available deployment --all --timeout=300s; then
  echo "ERROR: cert-manager failed to come up." 1>&2
  sudo kubectl get pods --namespace cert-manager 1>&2
  exit 1
fi
echo "cert-manager is up!"

if [[ "$GATEWAY_API" == "true" ]]; then
  # Gateway API support is beta and off by default. The feature gate behind it is
  # on by default, so only the controller flag is needed. Adding the flag rolls
  # the deployment, which also covers cert-manager's need to see the Gateway API
  # CRDs at startup.
  echo "Enabling cert-manager's Gateway API support"
  if sudo kubectl get deployment cert-manager --namespace cert-manager \
      -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- "--enable-gateway-api"; then
    echo "Already enabled"
  else
    sudo kubectl patch deployment cert-manager --namespace cert-manager --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-gateway-api"}]'
    sudo kubectl rollout status deployment cert-manager --namespace cert-manager --timeout=300s
  fi
fi

# In Gateway API mode the HTTP-01 challenge is solved with a temporary HTTPRoute
# attached to the Gateway, rather than with a temporary Ingress.
if [[ "$GATEWAY_API" == "true" ]]; then
  # IFS= so that read keeps the leading indentation of the first line
  IFS= read -r -d '' HTTP01_SOLVER <<EOF || true
    - http01:
        gatewayHTTPRoute:
          parentRefs:
            - name: ${GATEWAY_NAME}
              namespace: ${GATEWAY_NAMESPACE}
              kind: Gateway
EOF
else
  # IFS= so that read keeps the leading indentation of the first line
  IFS= read -r -d '' HTTP01_SOLVER <<EOF || true
    - http01:
        ingress:
          class: nginx
EOF
fi

cat > $HOME/letsencrypt-prod.yml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: $LETSENCRYPT_EMAIL
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
$HTTP01_SOLVER
EOF

cat > $HOME/letsencrypt-stage.yml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  namespace: cert-manager
spec:
  acme:
    # The ACME server URL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: $LETSENCRYPT_EMAIL
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable the HTTP-01 challenge provider
    solvers:
$HTTP01_SOLVER
EOF

# This one holds a credential, so don't leave it group/world readable
touch $HOME/digitalocean-dns.yml
chmod 600 $HOME/digitalocean-dns.yml
cat > $HOME/digitalocean-dns.yml <<EOF
apiVersion: v1
data:
  access-token: $DO_TOKEN
kind: Secret
metadata:
  name: digitalocean-dns
  namespace: cert-manager
EOF


cat > $HOME/letsencrypt-prod-dns01.yml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns
  namespace: cert-manager
spec:
  acme:
    # Email address used for ACME registration
    email: $LETSENCRYPT_EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      # Name of a secret used to store the ACME account private key
      name: letsencrypt-prod
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              name: digitalocean-dns
              key: access-token
EOF

# The staging counterpart of the above, so that --letsencrypt-staging works in
# wildcard mode too: a wildcard certificate can only be issued over DNS-01, so
# without this there would be no staging issuer for the Gateway to name.
cat > $HOME/letsencrypt-staging-dns01.yml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging-dns
  namespace: cert-manager
spec:
  acme:
    # Email address used for ACME registration
    email: $LETSENCRYPT_EMAIL
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      # Name of a secret used to store the ACME account private key
      name: letsencrypt-staging
    solvers:
      - dns01:
          digitalocean:
            tokenSecretRef:
              name: digitalocean-dns
              key: access-token
EOF

if [[ ! -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "Adding letsencrypt-prod ClusterIssuer..."
  retry sudo kubectl apply -f $HOME/letsencrypt-prod.yml
  echo "Adding letsencrypt-staging ClusterIssuer..."
  retry sudo kubectl apply -f $HOME/letsencrypt-stage.yml
  if [[ ! -z "$DO_TOKEN" ]]; then
    echo "Adding digitalocean-dns Secret..."
    retry sudo kubectl apply -f $HOME/digitalocean-dns.yml
    echo "Adding letsencrypt-prod-dns ClusterIssuer..."
    retry sudo kubectl apply -f $HOME/letsencrypt-prod-dns01.yml
    echo "Adding letsencrypt-staging-dns ClusterIssuer..."
    retry sudo kubectl apply -f $HOME/letsencrypt-staging-dns01.yml
  else
    echo "No DigitalOcean access token specified, so a DNS-based ClusterIssuer's could not be created.  Template files created at $HOME/digitalocean-dns.yml, $HOME/letsencrypt-prod-dns01.yml and $HOME/letsencrypt-staging-dns01.yml"
  fi
else
  echo "No e-mail specified, so ClusterIssuer's could not be created.  Template files created at $HOME/letsencrypt-prod.yml and $HOME/letsencrypt-stage.yml"
fi

if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
  echo "Certificates will be issued from Let's Encrypt's STAGING environment ($GATEWAY_ISSUER):"
  echo "they are signed by an untrusted root and clients will reject them. Re-run without"
  echo "--letsencrypt-staging to switch this machine to production certificates."
fi

echo "Installed cert-manager"

if [[ "$KATA" == "true" ]]; then

echo "**************************************************************************************"
echo "Installing Kata Containers"

# Upstream's kata-deploy helm chart is the supported way to install Kata into an
# existing cluster, and it knows about k3s specifically: with k8sDistribution=k3s
# its DaemonSet writes k3s's containerd configuration under
# /var/lib/rancher/k3s/agent/etc/containerd, restarts the k3s systemd unit and
# waits for the node to come back Ready. Doing any of that by hand here would be
# a copy of upstream's work that goes stale.
#
# k3s has a helm controller built in, but its support for charts served from an
# OCI registry (which this one is) varies by k3s version, and a failure inside
# the controller is much harder to read than one from the CLI.
echo "Installing the helm CLI"
helm_installer_file=$HOME/install-helm.sh
curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "${helm_installer_file}"
chmod +x "${helm_installer_file}"
"${helm_installer_file}"

# As with every other component here, the latest release is installed rather
# than a pinned version. The chart is published per Kata release under the same
# version as the release tag.
KATA_VERSION=$(curl -sSL https://api.github.com/repos/kata-containers/kata-containers/releases/latest | jq -r '.tag_name') || KATA_VERSION=""
if [[ -z "$KATA_VERSION" || "$KATA_VERSION" == "null" ]]; then
  die "could not determine the latest Kata Containers release from the GitHub API"
fi
echo "Installing Kata Containers $KATA_VERSION"

# The chart installs every hypervisor it knows about by default, each with its
# own RuntimeClass and its own artifacts on the node. Only the default shim for
# the architecture is wanted here -- qemu-runtime-rs, on both architectures this
# script allows --kata on -- since it is what the "kata" RuntimeClass points at.
# The rest are for confidential computing, other hypervisors, and hardware this
# machine does not have.
#
# runtimeClasses.createDefault gives the short name "kata" alongside the
# shim-specific "kata-qemu-runtime-rs", so a workload can name a runtime class
# without naming the hypervisor -- the same reasoning as the Gateway above, where
# nothing in a workload names traefik.
#
# snapshotter.setup is emptied: the nydus snapshotter it would otherwise install
# as a host service is only used by the confidential and remote shims, which are
# not installed. The qemu shim uses containerd's default snapshotter.
#
# "upgrade --install" rather than "install" because retry runs this again after a
# failure, and a second "install" of a release that partially succeeded fails on
# the name already being in use rather than on whatever went wrong the first time.
retry sudo helm upgrade --install kata-deploy \
  oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy \
  --kubeconfig /etc/rancher/k3s/k3s.yaml \
  --version "$KATA_VERSION" \
  --namespace kube-system \
  --set k8sDistribution=k3s \
  --set runtimeClasses.createDefault=true \
  --set shims.disableAll=true \
  --set shims.qemu-runtime-rs.enabled=true \
  --set 'snapshotter.setup={}' \
  || die "failed to install the kata-deploy helm chart"

# The DaemonSet has a large image to pull and a lot to unpack onto the node, and
# it restarts k3s when it reconfigures containerd -- so the API server goes away
# underneath these calls, which is what retry is here for. Each attempt is given
# a short timeout rather than one long one: a wait that was interrupted by the
# k3s restart simply resumes on the next attempt.
echo "Waiting for kata-deploy to install Kata on this node..."
if ! retry sudo kubectl rollout status daemonset/kata-deploy --namespace kube-system --timeout=300s; then
  die "the kata-deploy DaemonSet did not become ready; check with: sudo kubectl logs daemonset/kata-deploy --namespace kube-system"
fi

# kata-deploy claims the node with katacontainers.io/kata-runtime=false before it
# writes anything, and only promotes the label to "true" once the node really is
# able to run kata workloads. So this, and not the DaemonSet being ready, is what
# says the installation worked.
if ! retry sudo kubectl wait --for=jsonpath='{.metadata.labels.katacontainers\.io/kata-runtime}'=true \
    node --all --timeout=300s; then
  die "the node was not labelled katacontainers.io/kata-runtime=true, so Kata was not fully installed; check with: sudo kubectl logs daemonset/kata-deploy --namespace kube-system"
fi

echo "Installed Kata Containers"

fi

echo "**************************************************************************************"
echo "Configuring image registry credentials"

# Credentials are recorded in containerd's registry configuration, keyed by the
# registry's host name, so no imagePullSecrets are needed in the workloads that
# pull from it. Note that this configures *credentials for* one named registry;
# it does not determine where images are pulled from, which is decided by the
# image names in the workload itself. Only a single registry is supported: a
# machine needing credentials for two private registries is not handled here.
if [[ -n "$IMAGE_REGISTRY" ]] && [[ -z "$IMAGE_REGISTRY_USERNAME" || -z "$IMAGE_REGISTRY_PASSWORD" ]]; then
  echo "No credentials given with --image-registry, so nothing to configure: pulls"
  echo "from $IMAGE_REGISTRY will be anonymous."
elif [[ -n "$IMAGE_REGISTRY" ]]; then
  IMAGE_REGISTRY=$(echo $IMAGE_REGISTRY | sed 's|https\?://||')
  BARE_IMAGE_REGISTRY=$(echo $IMAGE_REGISTRY | cut -d'/' -f1)

  # This file holds registry credentials, so create it unreadable to anyone else
  # up front rather than after it has been written and moved into place.
  registries_file=$(mktemp)
  chmod 600 "$registries_file"

  # No "mirrors" section: an endpoint of https://<host> is identical to the
  # default endpoint containerd already uses for that host, and k3s ignores
  # mirror endpoints that match the default endpoint.
  cat > "$registries_file" <<EOF
configs:
  $BARE_IMAGE_REGISTRY:
    auth:
      username: "$IMAGE_REGISTRY_USERNAME"
      password: "$IMAGE_REGISTRY_PASSWORD"
EOF

  sudo mv "$registries_file" /etc/rancher/k3s/registries.yaml
  sudo chown root:root /etc/rancher/k3s/registries.yaml
  sudo chmod 640 /etc/rancher/k3s/registries.yaml
  # registries.yaml is only read at startup
  sudo systemctl restart k3s
fi

# End of long if block: Skip the package install stuff if so directed
fi

# Message the user to check k3s is working for them
echo "Test that k3s is correctly installed and working by running the command below:"
echo
echo "sudo k3s kubectl get node"
echo

if [[ "$GATEWAY_API" == "true" ]]; then
  echo "**************************************************************************************"
  echo "This machine serves traffic through the Gateway API rather than the Ingress API."
  echo "Workloads should attach an HTTPRoute to the Gateway, and need not name traefik:"
  echo
  echo "  apiVersion: gateway.networking.k8s.io/v1"
  echo "  kind: HTTPRoute"
  echo "  metadata:"
  echo "    name: my-app"
  echo "  spec:"
  echo "    parentRefs:"
  echo "      - name: ${GATEWAY_NAME}"
  echo "        namespace: ${GATEWAY_NAMESPACE}"
  echo "        kind: Gateway"
  echo "    hostnames:"
  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    echo "      - my-app.${WILDCARD_DOMAIN}"
  else
    echo "      - my-app.example.com"
  fi
  echo "    rules:"
  echo "      - backendRefs:"
  echo "          - name: my-app"
  echo "            port: 80"
  echo
  echo "Check the Gateway's listeners are programmed with:"
  echo
  echo "  sudo k3s kubectl describe gateway ${GATEWAY_NAME} --namespace ${GATEWAY_NAMESPACE}"
  echo
  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    echo "The HTTPS listener serves a *.${WILDCARD_DOMAIN} certificate, which cert-manager"
    echo "obtains over DNS-01 into the ${WILDCARD_SECRET_NAME} secret. That takes a few minutes,"
    echo "and the listener stays unready until it lands. Watch it with:"
    echo
    echo "  sudo k3s kubectl get certificate --namespace ${GATEWAY_NAMESPACE} --watch"
    echo
    echo "Individual workloads need no certificate configuration of their own: any"
    echo "*.${WILDCARD_DOMAIN} hostname is already covered."
  else
    echo "No --wildcard-domain was given, so the Gateway starts with an HTTP listener"
    echo "only. HTTPS is provisioned per application: the stack utility adds an HTTPS"
    echo "listener for each application's hostname at deploy time, and cert-manager"
    echo "obtains its certificate from Let's Encrypt over HTTP-01. To serve HTTPS for"
    echo "a hand-deployed workload, add a listener for its hostname to the Gateway:"
    echo
    echo "    - name: my-app-https"
    echo "      port: 8443"
    echo "      protocol: HTTPS"
    echo "      hostname: my-app.example.com"
    echo "      allowedRoutes:"
    echo "        namespaces:"
    echo "          from: All"
    echo "      tls:"
    echo "        mode: Terminate"
    echo "        certificateRefs:"
    echo "          - name: my-app-tls"
  fi
  echo
fi

if [[ "$KATA" == "true" ]]; then
  echo "**************************************************************************************"
  echo "This machine can run pods inside lightweight VMs with Kata Containers. That is"
  echo "opt-in per pod: name a kata RuntimeClass in the pod spec, and only that pod gets a"
  echo "VM of its own."
  echo
  echo "  apiVersion: apps/v1"
  echo "  kind: Deployment"
  echo "  spec:"
  echo "    template:"
  echo "      spec:"
  echo "        runtimeClassName: kata"
  echo "        containers:"
  echo "          - name: my-app"
  echo "            image: my-app:latest"
  echo
  echo "Pods that say nothing about a runtime class -- including k3s's own system pods and"
  echo "everything this script installed -- keep running as ordinary containers."
  echo
  echo "See the runtime classes that were created with:"
  echo
  echo "  sudo k3s kubectl get runtimeclass"
  echo
  echo "\"kata\" is the one to name; it points at this machine's default hypervisor. A pod"
  echo "on it boots its own kernel, so it starts more slowly and uses more memory than an"
  echo "ordinary container. Check that it really is in a VM by comparing its kernel with"
  echo "the host's:"
  echo
  echo "  uname -r"
  echo "  sudo k3s kubectl exec <pod> -- uname -r"
  echo
fi
