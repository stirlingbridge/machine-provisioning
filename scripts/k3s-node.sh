#!/usr/bin/env bash
#
# k3s-node.sh -- install a single-node Kubernetes cluster using k3s, ready for
# hosting applications with TLS.
#
# By default, installs k3s (with the bundled traefik ingress disabled), the
# nginx ingress controller, and cert-manager, then creates Let's Encrypt
# ClusterIssuers. Debian and Ubuntu only.
#
# With --gateway-api, the Gateway API is provisioned instead of the Ingress API:
# k3s's bundled traefik is kept and used as the Gateway API implementation, and
# a Gateway is created for workloads to attach their HTTPRoutes to. See the
# notes above the --gateway-api option below.
#
# The latest release of each component is installed rather than a pinned
# version.
#
# Usage:
#   k3s-node.sh [-y] [--letsencrypt-email <email>]
#               [--do-dns-access-token <token>]
#               [--tls-san <name>]
#               [--gateway-api] [--wildcard-domain <domain>]
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
#   --do-dns-access-token       DigitalOcean API token, enabling an additional
#                               DNS-01 ClusterIssuer (needed for wildcard certs).
#   --gateway-api               Provision the Gateway API rather than the Ingress
#                               API. The nginx ingress controller is not
#                               installed; k3s's bundled traefik is kept instead
#                               and its Gateway API provider enabled, which also
#                               brings in the Gateway API CRDs. A Gateway named
#                               "traefik-gateway" is created in the kube-system
#                               namespace, accepting routes from all namespaces,
#                               and cert-manager's Gateway API support is turned
#                               on.
#
#                               Workloads then attach an HTTPRoute to that
#                               Gateway with a parentRef, rather than creating an
#                               Ingress. Nothing in a workload names traefik, so
#                               the choice of implementation stays a property of
#                               the machine and can be changed here later.
#
#                               Note that the traffic-routing resources are
#                               stable (GA), but cert-manager's Gateway API
#                               support is beta.
#   --wildcard-domain           Domain to obtain a wildcard certificate for, e.g.
#                               "example.com" for a "*.example.com" certificate,
#                               served by the Gateway's HTTPS listener. Only
#                               meaningful with --gateway-api, and requires
#                               --do-dns-access-token, because a wildcard
#                               certificate can only be issued over DNS-01.
#
#                               In the Gateway API the certificate belongs to the
#                               Gateway's listener rather than to each workload,
#                               so one wildcard certificate covers every
#                               application on the machine. Without this option
#                               the Gateway serves HTTP only.
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
NEEDS_WARN=true
TLS_SAN_ARGS=""
GATEWAY_API=false
WILDCARD_DOMAIN=""

# Where the traefik chart puts the Gateway it deploys for us, and the name of the
# secret its HTTPS listener reads the wildcard certificate from.
GATEWAY_NAME="traefik-gateway"
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
      --gateway-api)
         GATEWAY_API=true
         ;;
      --wildcard-domain)
         shift&&WILDCARD_DOMAIN="$1"||die "--wildcard-domain requires a value"
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
    die "--wildcard-domain requires --gateway-api"
  fi
  if [[ -z "$DO_TOKEN" ]]; then
    die "--wildcard-domain requires --do-dns-access-token, since a wildcard certificate can only be issued over DNS-01"
  fi
  if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
    die "--wildcard-domain requires --letsencrypt-email"
  fi
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
  # The chart deploys the Gateway for us: listeners are declared here rather than
  # as a separate manifest so that the ports stay consistent with the ones the
  # chart declares for the traefik service (web 8000, websecure 8443, which the
  # service exposes as 80 and 443).
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
      enabled: true
EOF

  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    # cert-manager watches for this annotation on a Gateway and issues a
    # Certificate covering the listeners' hostnames into the secret named by
    # certificateRefs. The DNS-01 issuer is required for the wildcard.
    cat >> "$traefik_config_file" <<EOF
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod-dns
EOF
  fi

  cat >> "$traefik_config_file" <<EOF
      listeners:
        web:
          port: 8000
          protocol: HTTP
          namespacePolicy:
            from: All
EOF

  if [[ -n "$WILDCARD_DOMAIN" ]]; then
    cat >> "$traefik_config_file" <<EOF
        websecure:
          port: 8443
          protocol: HTTPS
          hostname: "*.${WILDCARD_DOMAIN}"
          namespacePolicy:
            from: All
          certificateRefs:
            - name: ${WILDCARD_SECRET_NAME}
EOF
  fi

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
  else
    echo "No DigitalOcean access token specified, so a DNS-based ClusterIssuer's could not be created.  Template files created at $HOME/digitalocean-dns.yml and $HOME/letsencrypt-prod-dns01.yml"
  fi
else
  echo "No e-mail specified, so ClusterIssuer's could not be created.  Template files created at $HOME/letsencrypt-prod.yml and $HOME/letsencrypt-stage.yml"
fi

echo "Installed cert-manager"

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
    echo "No --wildcard-domain was given, so the Gateway serves HTTP only. Add a TLS"
    echo "listener to it, or re-provision with --wildcard-domain, to serve HTTPS."
  fi
  echo
fi
