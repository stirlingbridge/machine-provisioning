#!/usr/bin/env bash
#
# End-to-end test for k3s-node.sh --kata.
#
# Provisions a DigitalOcean VM running combine.sh with health.sh, fqdn.sh and
# k3s-node.sh --kata, then verifies from the outside -- with kubectl, over a
# kubeconfig fetched from the machine -- that the machine is a cluster that
# behaves like any other k3s machine this repository provisions, except that a
# pod which asks for a kata RuntimeClass really does end up inside its own VM:
#
#   * the k3s baseline still holds: a Ready node, cert-manager available, the
#     stack-gateway Gateway programmed
#   * kata-deploy installed Kata on the node, which the node's own
#     katacontainers.io/kata-runtime label is the authority on, and the "kata"
#     and "kata-qemu-runtime-rs" RuntimeClasses exist
#   * the isolation itself: two pods of the same image report their kernel
#     version, and the one on the kata RuntimeClass reports a kernel that is not
#     the host's, while the one without a RuntimeClass reports one that is. A
#     container shares the host kernel and cannot do otherwise, so a different
#     kernel means a different machine
#   * corroborated from the host side, where a hypervisor process is running for
#     the sandbox
#   * and, the point of the exercise: a workload on the kata RuntimeClass is
#     reached over HTTP by hostname through the Gateway, exactly as an ordinary
#     one is
#
# This needs a machine whose provider allows nested virtualization. DigitalOcean
# does not document or support it, but does allow it. If that ever changes the
# provisioning fails at k3s-node.sh's virtualization check, with a message
# saying so, rather than here.
#
# See tests/README.md for the environment variables this needs.
#
# Extra environment (beyond the common ones):
#   E2E_LETSENCRYPT_EMAIL  Let's Encrypt contact address (required)
#
# Each pod is a VM with its own kernel and its own memory, on top of the k3s and
# cert-manager images that the k3s test already needs a larger machine for. And
# nested virtualization at DigitalOcean is slow, so kata-deploy unpacking its
# artifacts and restarting k3s takes longer than a normal provisioning run.
#
# These have to be set *before* common.sh is sourced: it applies the suite-wide
# defaults at source time, so anything set after it arrives too late to win and
# is silently ignored.
E2E_SIZE=${E2E_SIZE:-s-4vcpu-8gb}
E2E_PROVISION_TIMEOUT=${E2E_PROVISION_TIMEOUT:-2700}

source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

require_commands kubectl
require_env E2E_LETSENCRYPT_EMAIL

e2e_init "kata"

provision_machine <<EOF
health.sh
fqdn.sh
k3s-node.sh -y --kata --letsencrypt-email ${E2E_LETSENCRYPT_EMAIL} --letsencrypt-staging
EOF

wait_for_provisioning UP
wait_for_ssh
wait_for_dns

# --- a kubeconfig that works from here ----------------------------------------

fetch_kubeconfig

dump_kata_state () {
  dump_cluster_state
  echo "----- kata state at failure -----"
  kubectl logs daemonset/kata-deploy --namespace kube-system --tail=200 || true
  ssh_machine "ls -l /dev/kvm; ps -ef | grep -E 'qemu|kata' | grep -v grep" || true
  echo "---------------------------------"
}
# shellcheck disable=SC2034  # read by the teardown in lib/common.sh
TEST_DIAGNOSTICS_FN=dump_kata_state

# --- the k3s baseline ----------------------------------------------------------

# Not a copy of the whole k3s test: just enough to say that adding --kata did
# not cost us the cluster the other test asserts on in full.

kubectl wait --for=condition=Ready node --all --timeout=300s > /dev/null \
  || fail "the node did not become Ready"
pass "the cluster has a Ready node, reachable at ${TEST_MACHINE_FQDN}:6443"

kubectl wait --for=condition=Available deployment --all --namespace cert-manager --timeout=300s > /dev/null \
  || fail "cert-manager did not become available"
pass "cert-manager is available"

kubectl wait --for=condition=Programmed gateway/stack-gateway --namespace kube-system --timeout=300s > /dev/null \
  || fail "the stack-gateway Gateway was not programmed"
pass "the stack-gateway Gateway in kube-system is Programmed"

# --- kata is installed ---------------------------------------------------------

banner "Checking that Kata Containers was installed on the node"

kubectl rollout status daemonset/kata-deploy --namespace kube-system --timeout=600s > /dev/null \
  || fail "the kata-deploy DaemonSet is not ready"
pass "the kata-deploy DaemonSet is ready"

# kata-deploy labels the node katacontainers.io/kata-runtime=false while it is
# working and promotes it to "true" only once the node can actually run kata
# workloads, so this is its own verdict on the install and not ours.
assert_kubectl_output "get nodes -o jsonpath={.items[0].metadata.labels.katacontainers\.io/kata-runtime}" \
  "^true\$" "the node is labelled katacontainers.io/kata-runtime=true"

# "kata" is the name a workload should use -- it points at the machine's default
# hypervisor without naming it, the same reasoning as the Gateway not being
# named traefik by workloads. The shim-specific name is what it resolves to.
for runtime_class in kata kata-qemu-runtime-rs; do
  assert_kubectl_output "get runtimeclass $runtime_class" "^$runtime_class " \
    "the $runtime_class RuntimeClass exists"
done

# --- the isolation itself ------------------------------------------------------

banner "Checking that a pod on the kata RuntimeClass runs in a VM"

kubectl create namespace e2e-kata > /dev/null

# Run one pod of a stock image, and report the kernel it sees. $1 names the pod,
# $2 optionally the RuntimeClass to run it on.
kernel_in_pod () {
  local name=$1
  local runtime_class=${2:-}
  local runtime_class_field=""

  if [ -n "$runtime_class" ]; then
    runtime_class_field="  runtimeClassName: ${runtime_class}"
  fi

  kubectl apply -f - > /dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: e2e-kata
spec:
  restartPolicy: Never
${runtime_class_field}
  containers:
    - name: kernel
      image: busybox
      command: ["uname", "-r"]
EOF

  # A kata pod boots a kernel and a rootfs before the container starts, on a
  # machine whose nested virtualization is not fast.
  if ! kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${name}" \
      --namespace e2e-kata --timeout=600s > /dev/null 2>&1; then
    echo "pod ${name} did not run to completion:" 1>&2
    kubectl describe "pod/${name}" --namespace e2e-kata 1>&2 || true
    return 1
  fi

  kubectl logs "pod/${name}" --namespace e2e-kata
}

host_kernel=$( ssh_machine "uname -r" ) || fail "could not read the host's kernel version"
echo "the machine's own kernel is $host_kernel"

# The control. Without it, "the kata pod reports a different kernel" would also
# be satisfied by a broken comparison, and this additionally says that ordinary
# pods were left alone by the kata installation -- which is the whole basis of
# the opt-in arrangement.
runc_kernel=$( kernel_in_pod e2e-kernel-runc ) \
  || fail "the pod without a RuntimeClass did not run"
if [ "$runc_kernel" != "$host_kernel" ]; then
  fail "a pod with no RuntimeClass reported kernel '$runc_kernel', but the host runs '$host_kernel' - an ordinary container shares the host kernel, so something is wrong with this comparison"
fi
pass "a pod with no RuntimeClass shares the host's kernel ($host_kernel), as an ordinary container does"

kata_kernel=$( kernel_in_pod e2e-kernel-kata kata ) \
  || fail "the pod on the kata RuntimeClass did not run"
if [ "$kata_kernel" == "$host_kernel" ]; then
  fail "a pod on the kata RuntimeClass reported the host's kernel '$kata_kernel', so it was not running in a VM"
fi
pass "a pod on the kata RuntimeClass runs its own kernel ($kata_kernel), not the host's ($host_kernel)"

# --- the same workload as every other machine, in a VM -------------------------

# A different kernel proves the isolation. This proves it is still a Kubernetes
# cluster: the workload the k3s test deploys, deployed the same way on the kata
# RuntimeClass, routed through the same Gateway, and fetched from here by the
# machine's hostname over the public internet.
deploy_whoami e2e-kata-workload kata

# With that workload running, the host must have a kata shim and a hypervisor
# process for its sandbox. The kernel comparison above is the assertion; these
# say what is underneath it, and are the thing to look at first when this test
# fails. The hypervisor pattern covers every VMM kata can be configured with,
# rather than only the one this machine is expected to use, so that a change of
# hypervisor upstream reads as a change and not as a loss of isolation.
assert_ssh_output "ps -ef | grep -c '[c]ontainerd-shim-kata-v2'" "^[1-9]" \
  "the kata shim is running on the host for the sandbox"
assert_ssh_output "ps -ef | grep -cE '[q]emu-system|[c]loud-hypervisor|[f]irecracker|[s]tratovirt'" "^[1-9]" \
  "a hypervisor process is running on the host for the sandbox"

route_whoami_gateway e2e-kata-workload
