#!/usr/bin/env bash
#
# Shared helpers for the end-to-end tests.
#
# Source this as the first thing a test script does:
#
#     source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"
#
# Sourcing it turns on `set -e`, applies E2E_DEBUG (xtrace), and defines the
# helpers below.
#
# There is nothing to unit test in this repository: every script's job is to
# change the state of a real machine. So a test here provisions a real VM at
# DigitalOcean with the machine utility, pointing it at the scripts in *this*
# checkout, and then asserts over SSH (and, for k3s, over kubectl) that the
# machine ended up in the state the script promises. The VM is destroyed on
# exit, pass or fail.
#
# Anything needed by more than one test belongs here, and a difference between
# tests should be a parameter rather than a second copy -- the sibling suites
# in the machine and stack repositories both grew divergent copies of their
# wait loops that way.
#
# See tests/README.md for the environment variables and how to run these.

set -eo pipefail

if [ -n "$E2E_DEBUG" ]; then
  set -x
fi

# --- reporting ---------------------------------------------------------------

# Report a failure and exit non-zero. The EXIT trap still destroys the machine,
# so a test never has to clean up by hand before failing.
fail () {
  echo "FAILED: $*" 1>&2
  exit 1
}

# Report a passing check. Every assertion prints one of these, so a CI log
# reads as a list of what was actually verified rather than just "exit 0".
pass () {
  echo "PASSED: $*"
}

banner () {
  echo "=============================================================="
  echo "$*"
  echo "=============================================================="
}

# --- preconditions -----------------------------------------------------------

# Check that the utilities a test needs are on the PATH.
require_commands () {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
      fail "'$cmd' is not installed or not on the PATH"
    fi
  done
}

# Check that the named environment variables are all set, reporting every one
# that is missing rather than stopping at the first.
require_env () {
  local var missing=""
  for var in "$@"; do
    if [ -z "${!var}" ]; then
      missing="$missing $var"
    fi
  done
  if [ -n "$missing" ]; then
    fail "required environment not set:$missing (see tests/README.md)"
  fi
}

# --- configuration -----------------------------------------------------------

E2E_MACHINE_CMD=${E2E_MACHINE_CMD:-machine}
E2E_REGION=${E2E_REGION:-nyc3}
E2E_IMAGE=${E2E_IMAGE:-ubuntu-24-04-x64}
E2E_SIZE=${E2E_SIZE:-s-1vcpu-2gb}
E2E_NEW_USER=${E2E_NEW_USER:-e2euser}

# How long to allow for the VM to boot and for cloud-init to run the
# provisioning scripts, in seconds. Installing k3s, cert-manager and their
# images on a cold node is the slow case.
E2E_PROVISION_TIMEOUT=${E2E_PROVISION_TIMEOUT:-1800}

# Set to keep the VM after the test finishes, for debugging by hand. The DNS
# record is kept too, so remember to destroy it: machine destroy --delete-dns.
E2E_KEEP_MACHINE=${E2E_KEEP_MACHINE:-}

# Populated by e2e_init / provision_machine.
TEST_NAME=""
TEST_WORK_DIR=""
TEST_MACHINE_CONFIG=""
TEST_MACHINE_NAME=""
TEST_MACHINE_FQDN=""
TEST_MACHINE_ID=""
TEST_SESSION_ID=""

# Optionally the name of a function called during teardown of a failing test,
# for a test that can report more than the cloud-init log (the k3s test dumps
# the state of the cluster). The machine is destroyed immediately afterwards,
# so this is the last chance to capture anything from it.
TEST_DIAGNOSTICS_FN=""

# The URL of the combine.sh that the VM downloads on first boot. Everything
# these tests exercise is fetched from the network by the VM, so this is what
# decides *which* version of the scripts is under test -- the point of the
# whole suite is that it is this checkout and not whatever is on main.
#
# raw.githubusercontent.com serves any pushed commit by its SHA, so the default
# is this commit, and the check below refuses to run against a commit the
# remote does not have (which would silently test main's scripts instead).
provisioning_url () {
  if [ -n "$E2E_PROVISIONING_URL" ]; then
    echo "$E2E_PROVISIONING_URL"
    return
  fi
  local remote slug sha url
  remote=$( git config --get remote.origin.url ) \
    || fail "no git remote 'origin'; set E2E_PROVISIONING_URL to the combine.sh to test"
  # Accept both git@github.com:org/repo.git and https://github.com/org/repo.git
  slug=$( echo "$remote" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' )
  sha=$( git rev-parse HEAD )
  url="https://raw.githubusercontent.com/${slug}/${sha}/scripts/combine.sh"
  if ! curl -fsI "$url" > /dev/null; then
    fail "$url is not fetchable.
The VM downloads the scripts under test from that URL, so this commit has to be
pushed to the remote before it can be tested. Push the branch, or point
E2E_PROVISIONING_URL at the combine.sh you mean to test."
  fi
  echo "$url"
}

# --- machine lifecycle -------------------------------------------------------

# Run the machine CLI against this test's config and session id.
machine_cmd () {
  $E2E_MACHINE_CMD --config-file "$TEST_MACHINE_CONFIG" --session-id "$TEST_SESSION_ID" "$@"
}

# Start a test: check the common preconditions, make a working directory, pick
# a unique machine name and register the teardown. $1 is a short test name used
# in the machine name and in log output.
#
# A machine-unique name gives a unique FQDN, which keeps concurrent runs
# independent, avoids a stale DNS record from a previous run being used, and
# keeps Let's Encrypt duplicate-certificate rate limits out of the picture.
e2e_init () {
  TEST_NAME=$1

  require_commands "$E2E_MACHINE_CMD" curl git jq ssh
  require_env E2E_DO_TOKEN E2E_SSH_KEY E2E_SSH_KEY_FILE E2E_DO_DNS_ZONE E2E_PROJECT

  if [ ! -f "$E2E_SSH_KEY_FILE" ]; then
    fail "E2E_SSH_KEY_FILE $E2E_SSH_KEY_FILE does not exist"
  fi

  TEST_WORK_DIR=$( mktemp -d )
  TEST_MACHINE_CONFIG=$TEST_WORK_DIR/config.yml
  TEST_SESSION_ID=${E2E_SESSION_ID:-$( random_suffix )}
  TEST_MACHINE_NAME="e2etest-${TEST_NAME}-$( random_suffix )"
  TEST_MACHINE_FQDN="${TEST_MACHINE_NAME}.${E2E_DO_DNS_ZONE}"

  trap _e2e_exit_handler EXIT

  banner "e2e test: ${TEST_NAME}"
  echo "machine:          $TEST_MACHINE_FQDN"
  echo "session id:       $TEST_SESSION_ID"
  echo "region/size:      $E2E_REGION / $E2E_SIZE"
  echo "provisioning url: $( provisioning_url )"
}

random_suffix () {
  head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Destroy the machine and delete its DNS record, then check that nothing this
# session created outlived the test.
#
# The leak check is deliberately a failure and not a warning: in the machine
# repository a destroy that quietly failed left one VM running per CI run until
# the provider's instance limit was reached, and nothing reported it.
_e2e_exit_handler () {
  local rc=$?
  trap - EXIT
  set +e

  if [ $rc -ne 0 ] && [ -n "$TEST_DIAGNOSTICS_FN" ]; then
    $TEST_DIAGNOSTICS_FN
  fi

  if [ -n "$TEST_MACHINE_ID" ] && [ -z "$E2E_KEEP_MACHINE" ]; then
    echo "Destroying machine $TEST_MACHINE_NAME ($TEST_MACHINE_ID)"
    machine_cmd --verbose destroy --no-confirm --delete-dns "$TEST_MACHINE_ID"
  elif [ -n "$E2E_KEEP_MACHINE" ]; then
    echo "E2E_KEEP_MACHINE is set; leaving $TEST_MACHINE_FQDN running."
    echo "Destroy it with: $E2E_MACHINE_CMD --session-id $TEST_SESSION_ID destroy --delete-dns $TEST_MACHINE_ID"
  fi

  if [ -z "$E2E_KEEP_MACHINE" ]; then
    local leaked
    leaked=$( machine_cmd list --output json 2> /dev/null | jq -r '.[] | "\(.name) (\(.id))"' )
    if [ -n "$leaked" ]; then
      echo "LEAKED: these machines outlived the test and must be destroyed by hand:" 1>&2
      echo "$leaked" 1>&2
      rc=1
    fi
  fi

  rm -rf "$TEST_WORK_DIR"
  if [ $rc -eq 0 ]; then
    banner "e2e test ${TEST_NAME}: PASSED"
  else
    banner "e2e test ${TEST_NAME}: FAILED (exit $rc)"
  fi
  exit $rc
}

# Create the VM, running the provisioning scripts named on stdin. Each line of
# stdin is one entry of combine.sh's script-args list: a script name followed
# by its arguments, e.g.
#
#     provision_machine <<EOF
#     health.sh
#     fqdn.sh
#     packages.sh jq
#     EOF
#
# health.sh should be first in almost every case: it serves the status endpoint
# that wait_for_provisioning polls, and starting it first means a later script
# failing is still reported rather than looking like a machine that never came
# up.
#
# Note that script arguments end up in the VM's cloud-init user data, which is
# readable from the provider's API, so nothing secret should be passed that is
# not already a test-only credential.
provision_machine () {
  local script_args
  script_args=$( sed 's/^/          - /' )

  cat > "$TEST_MACHINE_CONFIG" <<EOF
digital-ocean:
    access-token: ${E2E_DO_TOKEN}
    ssh-key: ${E2E_SSH_KEY}
    dns-zone: ${E2E_DO_DNS_ZONE}
    machine-size: ${E2E_SIZE}
    image: ${E2E_IMAGE}
    region: ${E2E_REGION}
    project: ${E2E_PROJECT}
machines:
    ${TEST_NAME}-host:
        new-user-name: ${E2E_NEW_USER}
        script-dir: /opt/e2etest
        script-url: $( provisioning_url )
        script-path: /opt/e2etest/combine.sh
        script-args:
${script_args}
EOF

  echo "Provisioning with:"
  echo "$script_args"

  machine_cmd create --name "$TEST_MACHINE_NAME" --type "${TEST_NAME}-host" --wait-for-ip \
    || fail "machine create failed"

  TEST_MACHINE_ID=$( machine_cmd list --name "$TEST_MACHINE_NAME" --output json | jq -r '.[0].id' )
  if [ -z "$TEST_MACHINE_ID" ] || [ "$TEST_MACHINE_ID" == "null" ]; then
    fail "could not determine the id of the created machine"
  fi
  echo "Machine created with id $TEST_MACHINE_ID"
}

# Wait until the machine's provisioning status reaches $1 ("UP" or "ERROR"),
# which is served by health.sh and polled by "machine status".
#
# Reaching the other terminal status is a failure, not something to keep
# waiting through: a test that wants UP has already failed once the status is
# ERROR, and the cloud-init log is dumped so the CI log says why.
wait_for_provisioning () {
  local want=${1:-UP}
  local start=$SECONDS
  local status="UNKNOWN"

  echo "Waiting for provisioning to reach $want (up to ${E2E_PROVISION_TIMEOUT}s)..."
  while [ $((SECONDS - start)) -lt "$E2E_PROVISION_TIMEOUT" ]; do
    # A failed poll is normal early on -- the endpoint is not up yet, and the
    # provider's API is not perfectly reliable either -- so it must not end the
    # test. Only the timeout above decides that.
    status=$( machine_cmd status --id "$TEST_MACHINE_ID" --output json 2>/dev/null \
                | jq -r '.[0]["cloud-init-status"] // "UNKNOWN"' ) || status="UNKNOWN"
    if [ "$status" == "$want" ]; then
      pass "provisioning status is $want (after $((SECONDS - start))s)"
      return
    fi
    if [ "$status" == "UP" ] || [ "$status" == "ERROR" ]; then
      dump_cloud_init_log
      fail "provisioning status is $status, expected $want"
    fi
    sleep 15
  done

  dump_cloud_init_log
  fail "timed out waiting for provisioning status $want (last status: $status)"
}

# --- ssh ---------------------------------------------------------------------

ssh_machine () {
  ssh -i "$E2E_SSH_KEY_FILE" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$TEST_WORK_DIR/known_hosts" \
      -o BatchMode=yes \
      -o ConnectTimeout=15 \
      "${E2E_NEW_USER}@${TEST_MACHINE_FQDN}" "$@"
}

# Wait until the machine accepts SSH. The DNS record was only just created and
# sshd is not up the instant the provider reports an IP, so the first
# connection of a test is a race without this.
wait_for_ssh () {
  local tries=${1:-60}
  local try=0
  echo "Waiting for ssh to ${TEST_MACHINE_FQDN}..."
  while [ $try -lt "$tries" ]; do
    try=$((try + 1))
    if ssh_machine true > /dev/null 2>&1; then
      pass "ssh to $TEST_MACHINE_FQDN"
      return
    fi
    sleep 10
  done
  fail "could not ssh to $TEST_MACHINE_FQDN after $((tries * 10))s"
}

dump_cloud_init_log () {
  echo "----- last 200 lines of /var/log/cloud-init-output.log -----"
  ssh_machine "sudo tail -200 /var/log/cloud-init-output.log" || echo "(could not fetch the log)"
  echo "-----------------------------------------------------------"
}

# --- kubernetes --------------------------------------------------------------
#
# For the tests of machines provisioned with k3s-node.sh. Everything here talks
# to the cluster from *here*, over a kubeconfig fetched from the machine, rather
# than over ssh -- which is the point: it asserts on the cluster as a user of it
# would see it, and not on what the provisioning script believes it did.

# Fetch a kubeconfig from the machine and export KUBECONFIG so that every
# kubectl call after this one talks to it.
#
# The kubeconfig k3s writes names the local address. Substituting the machine's
# FQDN yields one that works remotely -- but only because k3s-node.sh put
# $MACHINE_FQDN in the API server's certificate as a tls-san, so every kubectl
# call a test makes is also an assertion that it did.
fetch_kubeconfig () {
  local kube_config=$TEST_WORK_DIR/kubeconfig
  ssh_machine "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${TEST_MACHINE_FQDN}/g" > "$kube_config"
  chmod 600 "$kube_config"
  export KUBECONFIG=$kube_config

  if ! grep -q "$TEST_MACHINE_FQDN" "$kube_config"; then
    fail "could not fetch a usable kubeconfig from the machine"
  fi
  pass "fetched a kubeconfig from the machine"
}

# Assert that the output of a kubectl invocation matches an extended regular
# expression. $1 is the argument line (deliberately word-split), $2 the pattern,
# $3 the label reported.
assert_kubectl_output () {
  local args=$1
  local pattern=$2
  local label=$3
  local out
  # shellcheck disable=SC2086  # $args is a deliberately word-split command line
  out=$( kubectl $args 2>&1 ) || true
  if echo "$out" | grep -Eq "$pattern"; then
    pass "$label"
  else
    echo "output of 'kubectl $args' was:"
    echo "$out"
    fail "$label - '$pattern' not found in the output"
  fi
}

# What the cluster was doing when something failed. Register it with
# TEST_DIAGNOSTICS_FN: the VM is destroyed on exit, so this is the only chance
# to capture it.
dump_cluster_state () {
  echo "----- cluster state at failure -----"
  kubectl get nodes -o wide || true
  kubectl get pods -A -o wide || true
  kubectl get gateway,httproute -A || true
  kubectl get ingress -A || true
  kubectl get clusterissuer,certificate,order,challenge -A || true
  kubectl get runtimeclass || true
  kubectl describe gateway -A || true
  echo "------------------------------------"
}

# Deploy the whoami workload into its own namespace. $1 is the namespace to
# create and use, and $2 optionally names a RuntimeClass to run it on -- the
# kata test runs this same workload in a VM, and it has to end up reachable in
# exactly the same way as an ordinary one.
#
# Pair it with route_whoami_gateway or route_whoami_ingress, which route to it
# and then fetch it from here: everything a "kubectl get" can tell you is that
# the pieces exist, and those say that they work.
deploy_whoami () {
  local namespace=$1
  local runtime_class=${2:-}
  local runtime_class_field=""

  if [ -n "$runtime_class" ]; then
    runtime_class_field="      runtimeClassName: ${runtime_class}"
  fi

  kubectl create namespace "$namespace" > /dev/null

  # whoami echoes the request back, so "Hostname:" in the body is proof that a
  # request reached the pod rather than being answered by the proxy.
  kubectl apply -f - <<EOF > /dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: e2e-whoami
  namespace: ${namespace}
spec:
  selector:
    matchLabels:
      app: e2e-whoami
  template:
    metadata:
      labels:
        app: e2e-whoami
    spec:
${runtime_class_field}
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: e2e-whoami
  namespace: ${namespace}
spec:
  selector:
    app: e2e-whoami
  ports:
    - port: 80
      targetPort: 80
EOF

  # A pod in a VM has a guest kernel and a rootfs to boot before the container
  # starts, on a machine whose nested virtualization is not fast, so allow
  # longer than the plain-container case would need.
  kubectl wait --for=condition=Available deployment/e2e-whoami --namespace "$namespace" --timeout=600s > /dev/null \
    || fail "the test workload did not become available"
  pass "the test workload is running${runtime_class:+ on RuntimeClass $runtime_class}"
}

# Route the whoami workload in namespace $1 through the Gateway that
# k3s-node.sh creates, and fetch it from here by the machine's hostname over the
# public internet.
route_whoami_gateway () {
  local namespace=$1

  # sectionName names the Gateway's HTTP listener, which k3s-node.sh calls
  # "web"; this is the same shape of HTTPRoute the stack utility creates.
  kubectl apply -f - <<EOF > /dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: e2e-whoami
  namespace: ${namespace}
spec:
  parentRefs:
    - name: stack-gateway
      namespace: kube-system
      sectionName: web
  hostnames:
    - ${TEST_MACHINE_FQDN}
  rules:
    - backendRefs:
        - name: e2e-whoami
          port: 80
EOF
  kubectl wait --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True \
    httproute/e2e-whoami --namespace "$namespace" --timeout=120s > /dev/null \
    || fail "the HTTPRoute was not accepted by the Gateway"
  pass "the HTTPRoute was accepted by the stack-gateway Gateway"

  assert_url_content "http://${TEST_MACHINE_FQDN}/" "^Hostname:" \
    "the workload is served over HTTP at ${TEST_MACHINE_FQDN}"
}

# The nginx counterpart of route_whoami_gateway, for a machine provisioned with
# k3s-node.sh --nginx-ingress.
route_whoami_ingress () {
  local namespace=$1

  kubectl apply -f - <<EOF > /dev/null
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: e2e-whoami
  namespace: ${namespace}
spec:
  ingressClassName: nginx
  rules:
    - host: ${TEST_MACHINE_FQDN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: e2e-whoami
                port:
                  number: 80
EOF
  pass "created an Ingress for the test workload"

  assert_url_content "http://${TEST_MACHINE_FQDN}/" "^Hostname:" \
    "the workload is served over HTTP at ${TEST_MACHINE_FQDN}"
}

# --- assertions --------------------------------------------------------------

# Assert that a command run on the machine succeeds. $1 is the command, $2 the
# label reported.
assert_ssh_succeeds () {
  local cmd=$1
  local label=$2
  local out
  if ! out=$( ssh_machine "$cmd" 2>&1 ); then
    echo "command output was:"
    echo "$out"
    fail "$label - '$cmd' exited non-zero"
  fi
  pass "$label"
}

# Assert that a command run on the machine fails. Used to check that a script
# that should not have run did not, e.g. after an intentional failure.
assert_ssh_fails () {
  local cmd=$1
  local label=$2
  local out
  if out=$( ssh_machine "$cmd" 2>&1 ); then
    echo "command output was:"
    echo "$out"
    fail "$label - '$cmd' unexpectedly succeeded"
  fi
  pass "$label"
}

# Assert that the output of a command run on the machine matches an extended
# regular expression. $1 command, $2 pattern, $3 label.
#
# The output is printed on failure: in CI it is the only evidence of what the
# machine actually looked like, and the VM is destroyed moments later.
assert_ssh_output () {
  local cmd=$1
  local pattern=$2
  local label=$3
  local out
  out=$( ssh_machine "$cmd" 2>&1 ) || true
  if echo "$out" | grep -Eq "$pattern"; then
    pass "$label"
  else
    echo "output of '$cmd' was:"
    echo "$out"
    fail "$label - '$pattern' not found in the output"
  fi
}

# Wait until $1 (a URL) responds with a body matching the extended regular
# expression $2. $3 overrides the number of 5-second attempts (default 60).
#
# Serving takes a moment longer than the resource existing -- a Gateway reports
# itself programmed before traefik has a route to the new endpoints -- so a
# single fetch here is a race.
assert_url_content () {
  local url=$1
  local pattern=$2
  local label=$3
  local tries=${4:-60}
  local try=0
  local body=""
  while [ $try -lt "$tries" ]; do
    try=$((try + 1))
    body=$( curl -sS --max-time 10 "$url" 2>&1 ) || true
    if echo "$body" | grep -Eq "$pattern"; then
      pass "$label"
      return
    fi
    sleep 5
  done
  echo "last response from $url was:"
  echo "$body"
  fail "$label - '$pattern' not served at $url"
}

# Wait for the machine's FQDN to resolve locally. The authoritative record was
# created moments ago by "machine create", and anything addressing the machine
# by name (rather than the kubeconfig's IP) needs it first.
wait_for_dns () {
  local tries=${1:-60}
  local try=0
  echo "Waiting for $TEST_MACHINE_FQDN to resolve..."
  while [ $try -lt "$tries" ]; do
    try=$((try + 1))
    if getent hosts "$TEST_MACHINE_FQDN" > /dev/null; then
      pass "$TEST_MACHINE_FQDN resolves"
      return
    fi
    sleep 5
  done
  fail "$TEST_MACHINE_FQDN did not resolve after $((tries * 5))s"
}
