#!/usr/bin/env bash
#
# End-to-end test for k3s-node.sh.
#
# Provisions a DigitalOcean VM running combine.sh with health.sh, fqdn.sh and
# k3s-node.sh, then verifies from the outside -- with kubectl, over a
# kubeconfig fetched from the machine -- that the machine really is running a
# Kubernetes cluster arranged the way the script's documentation says it is:
#
#   * a Ready node, reachable by the machine's FQDN (which only works if
#     k3s-node.sh added it to the API server certificate as a tls-san)
#   * cert-manager available, with the Let's Encrypt ClusterIssuers ready
#   * the routing arrangement for the mode under test: the stack-gateway
#     Gateway and the Gateway API CRDs by default, or the nginx ingress
#     controller with --nginx-ingress
#   * an actual workload, deployed and reached over HTTP by hostname through
#     that routing arrangement -- the part that a "kubectl get" of each
#     resource cannot tell you
#
# Certificate issuance itself is not asserted on: it depends on Let's Encrypt
# and on the DNS record propagating to their resolvers, which would make the
# test flaky for reasons that have nothing to do with this repository.
# --letsencrypt-staging is passed anyway, so that whatever the machine does
# attempt cannot burn the production rate limit.
#
# See tests/README.md for the environment variables this needs.
#
# Extra environment (beyond the common ones):
#   E2E_LETSENCRYPT_EMAIL  Let's Encrypt contact address (required)
#   E2E_K3S_MODE           "gateway" (default) tests the Gateway API
#                          arrangement, which is k3s-node.sh's own default;
#                          "ingress" tests the legacy nginx arrangement
#                          (k3s-node.sh --nginx-ingress)
#
# k3s, cert-manager and their images need more than the default test machine.
# This has to be set *before* common.sh is sourced: it applies the suite-wide
# defaults at source time, so anything set after it arrives too late to win and
# is silently ignored.
E2E_SIZE=${E2E_SIZE:-s-2vcpu-4gb}

source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

E2E_K3S_MODE=${E2E_K3S_MODE:-gateway}

require_commands kubectl
require_env E2E_LETSENCRYPT_EMAIL

case "$E2E_K3S_MODE" in
  gateway) k3s_mode_args="" ;;
  ingress) k3s_mode_args="--nginx-ingress" ;;
  *)       fail "E2E_K3S_MODE must be gateway or ingress, not $E2E_K3S_MODE" ;;
esac

e2e_init "k3s-${E2E_K3S_MODE}"

provision_machine <<EOF
health.sh
fqdn.sh
k3s-node.sh -y ${k3s_mode_args} --letsencrypt-email ${E2E_LETSENCRYPT_EMAIL} --letsencrypt-staging
EOF

wait_for_provisioning UP
wait_for_ssh
wait_for_dns

# --- fqdn.sh -----------------------------------------------------------------

assert_ssh_output "cat /etc/machine/fqdn" "^${TEST_MACHINE_FQDN}\$" \
  "fqdn.sh wrote the machine's FQDN to /etc/machine/fqdn"

# --- a kubeconfig that works from here ----------------------------------------

fetch_kubeconfig

# Dump what the cluster was doing if anything below fails: the VM is destroyed
# on exit, so this is the only chance to capture it.
# shellcheck disable=SC2034  # read by the teardown in lib/common.sh
TEST_DIAGNOSTICS_FN=dump_cluster_state

# --- the cluster itself -------------------------------------------------------

kubectl wait --for=condition=Ready node --all --timeout=300s > /dev/null \
  || fail "the node did not become Ready"
pass "the cluster has a Ready node, reachable at ${TEST_MACHINE_FQDN}:6443"

assert_kubectl_output "get --raw /version" '"gitVersion".*k3s' \
  "the API server reports a k3s version"

# --- cert-manager and the ClusterIssuers --------------------------------------

kubectl wait --for=condition=Available deployment --all --namespace cert-manager --timeout=300s > /dev/null \
  || fail "cert-manager did not become available"
pass "cert-manager is available"

for issuer in letsencrypt-prod letsencrypt-staging; do
  kubectl wait --for=condition=Ready "clusterissuer/$issuer" --timeout=180s > /dev/null \
    || fail "ClusterIssuer $issuer did not become Ready"
  pass "ClusterIssuer $issuer is Ready"
done

# --- the routing arrangement ---------------------------------------------------

if [ "$E2E_K3S_MODE" == "gateway" ]; then
  assert_kubectl_output "get crd gateways.gateway.networking.k8s.io" "gateways.gateway.networking.k8s.io" \
    "the Gateway API CRDs are installed"

  # The name and namespace are a contract with the stack utility, which
  # attaches routes to this Gateway and adds HTTPS listeners to it, so assert
  # on them exactly rather than on "a gateway exists".
  kubectl wait --for=condition=Programmed gateway/stack-gateway --namespace kube-system --timeout=300s > /dev/null \
    || fail "the stack-gateway Gateway was not programmed"
  pass "the stack-gateway Gateway in kube-system is Programmed"

  assert_kubectl_output "get gateway stack-gateway --namespace kube-system -o jsonpath={.spec.gatewayClassName}" \
    "^traefik\$" "the Gateway's class is traefik"

  # Routes are attached from application namespaces, so a Gateway that only
  # accepted routes from its own would be useless to every workload.
  assert_kubectl_output \
    "get gateway stack-gateway --namespace kube-system -o jsonpath={.spec.listeners[0].allowedRoutes.namespaces.from}" \
    "^All\$" "the Gateway accepts routes from all namespaces"

  assert_kubectl_output "get pods --namespace kube-system -l app.kubernetes.io/name=traefik" "Running" \
    "traefik is running"
else
  kubectl wait --for=condition=Available deployment/ingress-nginx-controller --namespace ingress-nginx --timeout=300s > /dev/null \
    || fail "the nginx ingress controller did not become available"
  pass "the nginx ingress controller is available"

  assert_kubectl_output "get ingressclass nginx -o jsonpath={.metadata.annotations}" "is-default-class.*true" \
    "the nginx ingress class is the default"

  # traefik is disabled in this mode; if it were running it would be bound to
  # the ports the nginx controller needs.
  if kubectl get pods --namespace kube-system -o name 2>/dev/null | grep -q traefik; then
    fail "traefik is running, but --nginx-ingress should have disabled it"
  fi
  pass "traefik is not running (disabled by --nginx-ingress)"
fi

# --- a real workload, reached by hostname --------------------------------------

# Everything above says the pieces exist. This says they work: a deployment in
# an ordinary namespace, exposed through whichever routing arrangement the mode
# provisions, fetched from here by the machine's hostname over the public
# internet.
banner "Deploying a workload and reaching it through the cluster"

deploy_whoami e2e-test

if [ "$E2E_K3S_MODE" == "gateway" ]; then
  route_whoami_gateway e2e-test
else
  route_whoami_ingress e2e-test
fi
