#!/usr/bin/env bash
#
# End-to-end test for failure reporting: error.sh, and combine.sh stopping at
# the first failure.
#
# This is the test that error.sh exists for. Provisioning a machine is
# unattended and unwatched, so a script failing silently -- or worse, the
# remaining scripts running on a half-provisioned machine -- is the failure
# mode that matters most and the one that is easiest to introduce by accident.
#
# The machine is provisioned with a script list that fails in the middle:
#
#     health.sh   -- must run, so that the failure can be reported at all
#     error.sh    -- always fails
#     fqdn.sh     -- must NOT run
#
# so the test asserts both halves of combine.sh's contract: the failure is
# reported as ERROR, and nothing after the failing script ran.
#
# This machine is small and quick -- the failure is reported within a minute or
# two of boot, long before anything expensive would have happened.
#
# See tests/README.md for the environment variables this needs.
#
# This test's own defaults, which have to be set *before* common.sh is sourced:
# it applies the suite-wide defaults at source time, so anything set after it
# arrives too late to win and is silently ignored.
E2E_SIZE=${E2E_SIZE:-s-1vcpu-1gb}
# A failure is meant to be reported quickly; if it takes longer than this
# something is wrong with the reporting, which is the thing under test.
E2E_PROVISION_TIMEOUT=${E2E_PROVISION_TIMEOUT:-600}

source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

e2e_init error

provision_machine <<EOF
health.sh
error.sh
fqdn.sh
EOF

# --- the failure is reported ---------------------------------------------------

# wait_for_provisioning fails the test if the status reaches UP instead, so
# this asserts that a failed provisioning is never reported as a healthy
# machine -- not merely that ERROR eventually appears.
wait_for_provisioning ERROR
wait_for_ssh

# --- combine.sh stopped at the failure -----------------------------------------

# fqdn.sh is the script after the failing one. If it ran, combine.sh carried on
# past a failure and every "provisioned" machine in the fleet is suspect.
assert_ssh_fails "test -e /etc/machine/fqdn" \
  "combine.sh did not run fqdn.sh, the script after the failing one"

# The reason has to be in the log a human will actually read.
assert_ssh_output "sudo grep -c 'THIS IS AN INTENTIONAL ERROR' /var/log/cloud-init-output.log" "^[1-9]" \
  "error.sh's message is in the cloud-init log"
assert_ssh_output "sudo grep 'error.sh FAILED' /var/log/cloud-init-output.log" "rc=1" \
  "combine.sh reported which script failed, and with what status"
