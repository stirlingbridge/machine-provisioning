#!/usr/bin/env bash
#
# End-to-end test for harden.sh, on a machine also provisioned with docker.sh.
#
# Docker is there because coexisting with it is the hard part of harden.sh:
# docker installs nftables rules of its own, which the firewall must leave
# alone (including when the nftables service is restarted), and containers must
# not reach the metadata service. It also makes this the test of docker.sh.
#
# The machine is provisioned with:
#
#     health.sh   -- serves a port that harden.sh must then block
#     docker.sh
#     harden.sh   -- sshd on a non-standard port, from this host's address
#
# harden.sh blocks health.sh's status endpoint, so this test can't wait on
# "machine status" as the others do. It waits for sshd to answer on the new
# port instead, watching cloud-init on port 22 in the meantime so a failure
# before harden.sh moves sshd is reported straight away. A failure after that
# point can leave nothing reachable, and then only the timeout reports it.
#
# The machine is rebooted once, because unattended-upgrades will reboot it and
# everything harden.sh sets up has to come back.
#
# See tests/README.md for the environment variables this needs.
#
source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

HARDENED_SSH_PORT=2222

# The addresses from the TEST-NET and documentation ranges are never seen, but
# exercise the list handling: more than one entry, and the IPv6 set.
OTHER_ALLOWED_V4=192.0.2.0/24
OTHER_ALLOWED_V6=2001:db8::/32

e2e_init harden
require_commands timeout

# The machine is reached by its A record, so it sees this host's IPv4 address.
runner_ip=$( curl -4 -fsS --max-time 15 https://api.ipify.org ) \
  || fail "could not determine this host's public IPv4 address"
echo "this host's address: $runner_ip"

harden_args="--ssh-port ${HARDENED_SSH_PORT}"
harden_args+=" --ssh-allow-from ${runner_ip}/32,${OTHER_ALLOWED_V4},${OTHER_ALLOWED_V6}"
harden_args+=" --upgrade-origin origin=Docker --remove-droplet-agent"

provision_machine <<EOF
health.sh
docker.sh
harden.sh ${harden_args}
EOF

# The cloud-init log, from whichever port sshd is on by now.
dump_log_any_port () {
  TEST_SSH_PORT=$HARDENED_SSH_PORT
  if ! ssh_machine true > /dev/null 2>&1; then
    TEST_SSH_PORT=22
  fi
  dump_cloud_init_log
}
TEST_DIAGNOSTICS_FN=dump_log_any_port

# Succeeds if something accepts a TCP connection on port $1 of the machine.
# A port the firewall drops doesn't refuse, it just never answers, hence the
# timeout.
port_answers () {
  timeout 10 bash -c "exec 3<>/dev/tcp/${TEST_MACHINE_FQDN}/$1" 2> /dev/null
}

assert_port_answers () {
  if port_answers "$1"; then
    pass "$2"
  else
    fail "$2 - nothing answered on port $1"
  fi
}

assert_port_blocked () {
  if port_answers "$1"; then
    fail "$2 - port $1 answered"
  fi
  pass "$2"
}

wait_for_hardened_ssh () {
  local start=$SECONDS status
  echo "Waiting for sshd on port $HARDENED_SSH_PORT (up to ${E2E_PROVISION_TIMEOUT}s)..."
  while [ $((SECONDS - start)) -lt "$E2E_PROVISION_TIMEOUT" ]; do
    TEST_SSH_PORT=$HARDENED_SSH_PORT
    if ssh_machine true > /dev/null 2>&1; then
      pass "ssh on port $HARDENED_SSH_PORT (after $((SECONDS - start))s)"
      return
    fi
    TEST_SSH_PORT=22
    status=$( ssh_machine "cloud-init status" 2> /dev/null ) || true
    if echo "$status" | grep -q "status: error"; then
      fail "provisioning failed before harden.sh moved sshd"
    fi
    sleep 10
  done
  fail "timed out waiting for sshd on port $HARDENED_SSH_PORT"
}

wait_for_dns
wait_for_hardened_ssh
TEST_SSH_PORT=$HARDENED_SSH_PORT

# harden.sh moves sshd partway through, so cloud-init may still be running.
assert_ssh_output "cloud-init status --wait" "status: done" \
  "provisioning finished without errors"

# --- the firewall, from outside -----------------------------------------------

assert_port_answers "$HARDENED_SSH_PORT" "port $HARDENED_SSH_PORT answers this host"
assert_port_blocked 22 "port 22 does not answer"

# health.sh is still serving, so it is the firewall that stops it being reached.
assert_ssh_output "curl -fsS http://localhost:4242/cgi-bin/cloud-init-status" '"status"' \
  "health.sh is serving on the machine"
assert_port_blocked 4242 "health.sh's port does not answer from outside"

assert_ssh_output "sudo nft list set inet harden ssh_allow_v4" "${runner_ip}.*${OTHER_ALLOWED_V4}|${OTHER_ALLOWED_V4}.*${runner_ip}" \
  "both IPv4 addresses are in the ssh allow list"
assert_ssh_output "sudo nft list set inet harden ssh_allow_v6" "${OTHER_ALLOWED_V6}" \
  "the IPv6 address is in the ssh allow list"

# --- sshd -----------------------------------------------------------------------

# Every port sshd is configured with, on one line, so another one can't hide
# beside the right one.
assert_ssh_output "sudo sshd -T | grep '^port ' | paste -sd ," "^port ${HARDENED_SSH_PORT}\$" \
  "sshd is configured for port $HARDENED_SSH_PORT and no other"
assert_ssh_output "sudo sshd -T" "^permitrootlogin no\$" "sshd does not permit root logins"
assert_ssh_output "sudo sshd -T" "^passwordauthentication no\$" "sshd does not permit password logins"
assert_ssh_output "sudo sshd -T" "^allowusers ${E2E_NEW_USER}\$" "sshd allows only ${E2E_NEW_USER}"

# Fails showing what is listening, if anything.
assert_nothing_listens_on_22 () {
  local out
  out=$( ssh_machine "sudo ss -Htlnp 'sport = :22'" 2>&1 ) || fail "$1 - could not run ss on the machine: $out"
  if [ -n "$out" ]; then
    echo "listening on port 22:"
    echo "$out"
    echo "----- sshd processes and units -----"
    ssh_machine "uptime; ps -o pid,ppid,lstart,unit,args -C sshd; systemctl status ssh.socket ssh.service --no-pager; sudo journalctl -b -u ssh.socket -u ssh.service --no-pager | tail -60" 2>&1 || true
    echo "------------------------------------"
    fail "$1"
  fi
  pass "$1"
}

# sshd -T is the configuration; these are what it actually does.
assert_nothing_listens_on_22 "nothing listens on port 22"
assert_ssh_output "systemctl is-enabled ssh.socket" "disabled" "socket-activated sshd is disabled"
assert_ssh_output "systemctl is-enabled ssh.service" "^enabled" "ssh.service is enabled"

# The machine utility puts the key in root's authorized_keys too, so this is
# sshd refusing root rather than root having no key.
out=$( ssh_machine_as root true 2>&1 ) && fail "root can log in with the provisioning key"
if echo "$out" | grep -q "Permission denied"; then
  pass "root cannot log in"
else
  echo "ssh output was: $out"
  fail "root cannot log in - expected 'Permission denied'"
fi

out=$( ssh -p "$HARDENED_SSH_PORT" -o PubkeyAuthentication=no -o BatchMode=yes \
         -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$TEST_WORK_DIR/known_hosts" \
         "${E2E_NEW_USER}@${TEST_MACHINE_FQDN}" true 2>&1 ) || true
if echo "$out" | grep -q "Permission denied (publickey)"; then
  pass "sshd offers only public key authentication"
else
  echo "ssh output was: $out"
  fail "sshd offers only public key authentication"
fi

# --- the rest of the machine ----------------------------------------------------

assert_ssh_output "sudo passwd -S root" "^root L" "the root password is locked"
assert_ssh_output "sysctl -n kernel.kptr_restrict" "^2\$" "kernel hardening settings are applied"
assert_ssh_succeeds "! dpkg -s snapd > /dev/null 2>&1" "snapd is removed"
assert_ssh_succeeds "! dpkg -s droplet-agent > /dev/null 2>&1" "droplet-agent is removed"
assert_ssh_output "apt-config dump" '^Unattended-Upgrade::Automatic-Reboot "true";' \
  "unattended-upgrades reboots when it needs to"
assert_ssh_output "apt-config dump" '^Unattended-Upgrade::Origins-Pattern:: "origin=Docker";' \
  "unattended-upgrades includes the Docker repository"

# --- docker -----------------------------------------------------------------------

assert_ssh_output "docker run --rm alpine echo e2e-container-ok" "e2e-container-ok" \
  "docker.sh installed docker, and a container runs"

# Says which, rather than failing, so docker itself failing isn't mistaken for
# the metadata service being blocked.
METADATA_PROBE="wget -q -T 10 -O /dev/null http://169.254.169.254/metadata/v1/id && echo REACHED || echo BLOCKED"

# The host reaching the metadata service shows it is the firewall that stops
# the container, not the service being unavailable.
assert_ssh_succeeds "curl -fsS --max-time 10 http://169.254.169.254/metadata/v1/id" \
  "the host can reach the metadata service"
check_metadata_blocked () {
  assert_ssh_output "docker run --rm alpine sh -c '$METADATA_PROBE'" "^BLOCKED\$" "$1"
}
check_metadata_blocked "a container cannot reach the metadata service"

check_container_network () {
  assert_ssh_output "docker run --rm alpine wget -q -T 15 -O - http://example.com/" "Example Domain" \
    "$1"
}
check_container_network "a container can reach the internet"

# The stock nftables service flushes the whole ruleset when stopped, taking
# docker's rules with it; harden.sh's drop-in makes it remove only its own table.
assert_ssh_succeeds "sudo systemctl restart nftables" "the nftables service restarts"
assert_ssh_succeeds "sudo nft list table inet harden" "the harden table is back after the restart"
check_container_network "a container can still reach the internet after nftables restarts"

# --- re-running ---------------------------------------------------------------------

# As in the combine test, MACHINE_SCRIPT_URL keeps this a test of this commit.
assert_ssh_succeeds \
  "MACHINE_SCRIPT_URL='$( provisioning_url )' /opt/e2etest/combine.sh 'harden.sh ${harden_args}'" \
  "re-running harden.sh succeeds"
assert_ssh_succeeds "true" "ssh still works after the re-run"

# --- after a reboot -----------------------------------------------------------------

echo "Rebooting..."
ssh_machine "sudo systemctl reboot" > /dev/null 2>&1 || true
# Long enough for sshd to have gone, so the wait below can't see the old one.
sleep 30
wait_for_ssh

assert_port_blocked 22 "port 22 does not answer after a reboot"
assert_ssh_output "sudo nft list set inet harden ssh_allow_v4" "${runner_ip}" \
  "the firewall is loaded after a reboot"
assert_nothing_listens_on_22 "nothing listens on port 22 after a reboot"
check_container_network "a container can reach the internet after a reboot"
check_metadata_blocked "a container cannot reach the metadata service after a reboot"
