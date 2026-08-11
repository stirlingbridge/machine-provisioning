#!/usr/bin/env bash
#
# End-to-end test for combine.sh and the scripts it is usually asked to run:
# health.sh, fqdn.sh, packages.sh, podman.sh and stack.sh.
#
# These are cheap enough to check on one machine, and running them together is
# the arrangement that actually matters: combine.sh's job is to run several
# scripts in sequence, and a script that only works when it is the only one on
# the machine is broken for every real use of this repository.
#
# The scripts are ordered so that a later one depends on an earlier one having
# worked: podman.sh needs the apt state that packages.sh leaves behind, and
# nothing at all is reported unless health.sh came up first.
#
# See tests/README.md for the environment variables this needs.
#
source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

e2e_init combine

provision_machine <<EOF
health.sh
fqdn.sh
packages.sh jq build-essential
podman.sh
stack.sh
EOF

# --- health.sh ----------------------------------------------------------------

# Reaching UP at all is health.sh working: the status this polls is served by
# the endpoint health.sh installs. It is also combine.sh working, since the
# status only becomes UP once every script in the list has run and cloud-init
# has finished.
wait_for_provisioning UP
wait_for_ssh
wait_for_dns

# ... and the endpoint itself, fetched directly rather than through the machine
# utility, so that the JSON contract in health.sh's documentation is checked
# and not just whatever machine happens to parse out of it.
assert_url_content "http://${TEST_MACHINE_FQDN}:4242/cgi-bin/cloud-init-status" \
  '"status":[[:space:]]*"UP"' \
  "health.sh serves {\"status\": \"UP\"} on port 4242"

# --- fqdn.sh ------------------------------------------------------------------

assert_ssh_output "cat /etc/machine/fqdn" "^${TEST_MACHINE_FQDN}\$" \
  "fqdn.sh wrote the machine's FQDN to /etc/machine/fqdn"

# The file is written for anything on the machine to read, and fqdn.sh chmods
# it precisely because mktemp would otherwise have left it 0600.
assert_ssh_output "stat -c '%U %a' /etc/machine/fqdn" "^root 644\$" \
  "/etc/machine/fqdn is owned by root and world readable"

# --- packages.sh --------------------------------------------------------------

assert_ssh_succeeds "jq --version" "packages.sh installed jq"
assert_ssh_succeeds "dpkg -s build-essential" \
  "packages.sh installed build-essential (a second package in one invocation)"

# --- podman.sh ----------------------------------------------------------------

assert_ssh_succeeds "podman --version" "podman.sh installed podman"

# podman.sh installs the docker CLI shim when no real docker is present, which
# is what lets a caller's docker-shaped tooling work on a podman machine.
assert_ssh_output "docker --version" "podman" \
  "podman.sh installed podman-docker (docker resolves to podman)"

# Without this, "podman run nginx" fails to resolve the image at all.
assert_ssh_output "cat /etc/containers/registries.conf" '^unqualified-search-registries.*docker\.io' \
  "podman.sh enabled docker.io as an unqualified search registry"

# The point of installing a container engine is running containers, so run one.
assert_ssh_output "podman run --rm docker.io/library/alpine echo e2e-container-ok" "e2e-container-ok" \
  "podman can pull and run a container"

# --- stack.sh -----------------------------------------------------------------

assert_ssh_succeeds "test -x /usr/local/bin/stack" "stack.sh installed /usr/local/bin/stack"
assert_ssh_output "stack version" "[0-9]" "the installed stack utility runs and reports a version"

# --- re-running is not an error ------------------------------------------------

# docker.sh, podman.sh and stack.sh all guard against reinstalling, and a
# machine's provisioning being re-run (or a second combine.sh naming the same
# script) has to be safe.
#
# MACHINE_SCRIPT_URL is set explicitly because combine.sh resolves a bare
# script name relative to it, and nothing sets it outside cloud-init. Without
# it combine.sh falls back to the scripts on main, which would quietly make
# this a test of main rather than of the commit under test.
assert_ssh_succeeds \
  "MACHINE_SCRIPT_URL='$( provisioning_url )' /opt/e2etest/combine.sh podman.sh stack.sh" \
  "re-running combine.sh over already-installed scripts succeeds"
assert_ssh_succeeds "podman --version && /usr/local/bin/stack version" \
  "podman and stack still work after the re-run"
