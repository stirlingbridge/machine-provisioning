#!/usr/bin/env bash
#
# record-demo.sh -- record docs/images/demo.gif from demo/demo.tape.
#
# The recording is a real run against a live DigitalOcean account: it creates a
# VM, provisions it with the scripts in this checkout (combine.sh running
# health.sh, fqdn.sh and k3s-node.sh), deploys the example todo application onto
# the resulting cluster with the stack utility, fetches it over HTTPS with a
# real Let's Encrypt certificate, and destroys the machine again. Nothing in the
# animation is faked or edited.
#
# This script only builds the environment the tape assumes, and cleans up after
# it:
#
#   * A scratch HOME at /tmp/provisioning-demo/home holding just the demo's
#     machine config, a copy of the ssh key and the registry credentials, so the
#     recording neither reads nor displays the real ~/.config/machine, and so
#     each run starts with a fresh session id (the session-scoped `machine list`
#     and `machine destroy` at the end then only ever see the demo's machine).
#   * The config file references the API token, ssh key name, DNS zone, project
#     and registry credentials by ${...} environment variable, so no secret
#     appears on screen even though the config file does.
#   * The application's container images, built off camera. Building three
#     containers is the stack utility's business and minutes of build log; the
#     recording is about how the machine got there.
#   * A best-effort sweep for a machine left behind by an aborted run.
#
# Which scripts get recorded is decided by a URL, exactly as in tests/: the VM
# downloads combine.sh from raw.githubusercontent.com on first boot, and by
# default that URL names the commit currently checked out. So commit and push
# before recording, or set MACHINE_PROVISIONING_URL.
#
# Costs money and about fifteen minutes: it creates and destroys a real VM, and
# obtains a real certificate, each time it runs.
#
# See demo/README.md for the environment it needs and for the Let's Encrypt rate
# limit to keep in mind when recording several takes.

set -euo pipefail

cd "$( dirname -- "${BASH_SOURCE[0]}" )/.."
REPO_ROOT=$PWD

# Deliberately outside $HOME: the recorded commands print absolute paths, and a
# scratch dir under $HOME would put the recorder's username in the recording.
SCRATCH=/tmp/provisioning-demo
DEMO_HOME=$SCRATCH/home
DEMO_SSH_KEY=$DEMO_HOME/.ssh/demo-key

MACHINE_NAME=${DEMO_MACHINE_NAME:-k3sdemo}
MACHINE_REGION=${MACHINE_REGION:-nyc3}
MACHINE_SIZE=${MACHINE_SIZE:-s-2vcpu-4gb}
MACHINE_IMAGE=${MACHINE_IMAGE:-ubuntu-24-04-x64}
MACHINE_USER=demo

fail () {
  echo "error: $*" >&2
  exit 1
}

# --- preconditions -----------------------------------------------------------

missing=()
for tool in vhs ttyd ffmpeg machine stack kubectl docker jq openssl curl git ssh; do
  command -v "$tool" > /dev/null || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "error: not on PATH: ${missing[*]}" >&2
  echo "  ffmpeg, ttyd: sudo apt-get install -y ffmpeg ttyd" >&2
  echo "  vhs:          https://github.com/charmbracelet/vhs/releases" >&2
  echo "  machine:      uv tool install git+https://github.com/stirlingbridge/machine.git" >&2
  echo "  stack:        https://github.com/bozemanpass/stack" >&2
  exit 1
fi

missing=()
for var in MACHINE_DO_TOKEN MACHINE_SSH_KEY_NAME MACHINE_SSH_KEY_FILE MACHINE_DNS_ZONE \
           MACHINE_PROJECT LETSENCRYPT_EMAIL \
           STACK_IMAGE_REGISTRY STACK_IMAGE_REGISTRY_USER STACK_IMAGE_REGISTRY_TOKEN; do
  [ -n "${!var:-}" ] || missing+=("$var")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "error: required environment not set: ${missing[*]}" >&2
  echo "  see demo/README.md" >&2
  exit 1
fi

[ -f "$MACHINE_SSH_KEY_FILE" ] \
  || fail "MACHINE_SSH_KEY_FILE $MACHINE_SSH_KEY_FILE does not exist (the recorded ssh needs it)"

MACHINE_FQDN=$MACHINE_NAME.$MACHINE_DNS_ZONE

# The VM fetches the scripts it is provisioned with from this URL, so it decides
# which version of them the animation actually shows. raw.githubusercontent.com
# serves any pushed commit by its SHA, so the default is this commit -- and the
# check below refuses to record against a commit the remote does not have, which
# would quietly show main's scripts instead.
provisioning_url () {
  if [ -n "${MACHINE_PROVISIONING_URL:-}" ]; then
    echo "$MACHINE_PROVISIONING_URL"
    return
  fi
  local remote slug sha url
  remote=$( git config --get remote.origin.url ) \
    || fail "no git remote 'origin'; set MACHINE_PROVISIONING_URL to the combine.sh to record"
  slug=$( echo "$remote" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' )
  sha=$( git rev-parse HEAD )
  url=https://raw.githubusercontent.com/$slug/$sha/scripts/combine.sh
  if ! curl -fsI "$url" > /dev/null; then
    fail "$url is not fetchable.
The VM downloads the scripts it is provisioned with from that URL, so this
commit has to be pushed before it can be recorded. Push the branch, or point
MACHINE_PROVISIONING_URL at the combine.sh you mean to record."
  fi
  echo "$url"
}

SCRIPT_URL=$( provisioning_url )

echo "==> Recording $MACHINE_FQDN ($MACHINE_SIZE in $MACHINE_REGION)"
echo "    provisioning url: $SCRIPT_URL"
echo "    image registry:   $STACK_IMAGE_REGISTRY"

# --- the scratch home --------------------------------------------------------

echo "==> Building the scratch home"
rm -rf "$SCRATCH"
mkdir -p "$DEMO_HOME/.config/machine" "$DEMO_HOME/.ssh" "$DEMO_HOME/.docker" "$SCRATCH/repos"
install -m 600 "$MACHINE_SSH_KEY_FILE" "$DEMO_SSH_KEY"

# Every secret is a ${...} reference rather than a value, because the tape cats
# this file on camera. The machine utility expands them from the environment
# when it loads the config, including inside the script-args entries.
cat > "$DEMO_HOME/.config/machine/config.yml" <<EOF
digital-ocean:
    access-token: \${MACHINE_DO_TOKEN}
    ssh-key: \${MACHINE_SSH_KEY_NAME}
    dns-zone: \${MACHINE_DNS_ZONE}
    project: \${MACHINE_PROJECT}
    machine-size: ${MACHINE_SIZE}
    image: ${MACHINE_IMAGE}
    region: ${MACHINE_REGION}

machines:
    k3s-host:
        new-user-name: ${MACHINE_USER}
        script-dir: /opt/demo
        script-url: ${SCRIPT_URL}
        script-path: /opt/demo/combine.sh
        script-args:
          - health.sh
          - fqdn.sh
          - k3s-node.sh -y --letsencrypt-email \${LETSENCRYPT_EMAIL}
            --image-registry \${STACK_IMAGE_REGISTRY}
            --image-registry-username \${STACK_IMAGE_REGISTRY_USER}
            --image-registry-password \${STACK_IMAGE_REGISTRY_TOKEN}
EOF

export STACK_REPO_BASE_DIR=$SCRATCH/repos

# --- preflight ---------------------------------------------------------------

# Read-only API calls: the token authenticates, and the ssh key, DNS zone,
# project, region and image named in the config all exist at the provider.
echo "==> Checking the config against the provider"
HOME=$DEMO_HOME machine check || fail "the demo's machine config does not check out"

# The one thing `machine check` cannot check: that MACHINE_SSH_KEY_FILE is the
# private half of the *registered* key named by MACHINE_SSH_KEY_NAME. Those two
# name the same key in two different places, and nothing else here would notice
# them drifting apart -- the machine would be built with one key's public half
# and the recorded ssh would offer the other's, which is a "Permission denied
# (publickey)" fifteen minutes and one VM into a take, with the recording
# carrying on regardless against an empty kubeconfig.
#
# The provider reports MD5 fingerprints, so ask ssh-keygen for the same form.
echo "==> Checking the ssh key matches the one registered as $MACHINE_SSH_KEY_NAME"
local_fingerprint=$( ssh-keygen -E md5 -lf "$MACHINE_SSH_KEY_FILE" | awk '{ print $2 }' | sed 's/^MD5://' )
registered_fingerprint=$( HOME=$DEMO_HOME machine ssh-keys | awk -v want="$MACHINE_SSH_KEY_NAME" '
  { line = $0
    sub(/^[0-9]+: /, "", line)
    i = index(line, " (")
    if (i == 0) next
    name = substr(line, 1, i - 1)
    fingerprint = substr(line, i + 2)
    sub(/\)$/, "", fingerprint)
    if (name == want) { print fingerprint; exit }
  }' )

if [ -z "$registered_fingerprint" ]; then
  fail "no ssh key named '$MACHINE_SSH_KEY_NAME' is registered at the provider"
fi
if [ "$local_fingerprint" != "$registered_fingerprint" ]; then
  fail "MACHINE_SSH_KEY_NAME and MACHINE_SSH_KEY_FILE are different keys.
  registered as '$MACHINE_SSH_KEY_NAME': $registered_fingerprint
  $MACHINE_SSH_KEY_FILE: $local_fingerprint
The machine would be built with the first and the recorded ssh would offer the
second, so the recording would fail to fetch a kubeconfig from it. Point both at
the same key. The private key's comment is usually a good hint which one that is:
  $( ssh-keygen -lf "$MACHINE_SSH_KEY_FILE" | awk '{ print $3 }' )"
fi
echo "    ssh key ok ($registered_fingerprint)"

# --- the application's images, off camera ------------------------------------

# docker login runs against the scratch home too, so the recorder's own
# ~/.docker/config.json is neither read nor written, and the recorded
# push-images still finds credentials for the registry.
echo "==> Logging in to ${STACK_IMAGE_REGISTRY%%/*} (off camera)"
echo "$STACK_IMAGE_REGISTRY_TOKEN" | HOME=$DEMO_HOME docker login "${STACK_IMAGE_REGISTRY%%/*}" \
  --username "$STACK_IMAGE_REGISTRY_USER" --password-stdin

echo "==> Building the application's images (off camera)"
HOME=$DEMO_HOME stack fetch repo bozemanpass/example-todo-list
HOME=$DEMO_HOME stack prepare --stack todo

# --- leftovers from an aborted run -------------------------------------------

# --all is needed because a previous run had its own session id, which this
# run's scratch home does not share.
sweep_leftovers () {
  local ids
  ids=$( HOME=$DEMO_HOME machine list --all --name "$MACHINE_NAME" -q 2>/dev/null || true )
  if [ -n "$ids" ]; then
    echo "==> Destroying leftover $MACHINE_NAME machine(s): $ids"
    # shellcheck disable=SC2086  # deliberately word-split: destroy takes a list
    HOME=$DEMO_HOME machine destroy --all --no-confirm --delete-dns $ids || true
  fi
}

sweep_leftovers

# ssh resolves ~/.ssh from the passwd entry rather than from $HOME, so the
# recorded ssh adds the throwaway machine's host key to the *real* known_hosts.
# Put it back as it was rather than picking the new entries out afterwards.
KNOWN_HOSTS=$HOME/.ssh/known_hosts
KNOWN_HOSTS_BACKUP=$SCRATCH/known_hosts.backup
if [ -f "$KNOWN_HOSTS" ]; then
  cp -p "$KNOWN_HOSTS" "$KNOWN_HOSTS_BACKUP"
fi
restore_known_hosts () {
  if [ -f "$KNOWN_HOSTS_BACKUP" ]; then
    cp -p "$KNOWN_HOSTS_BACKUP" "$KNOWN_HOSTS"
  fi
}
trap restore_known_hosts EXIT

# --- record ------------------------------------------------------------------

echo "==> Rendering the tape"
rendered_tape=$SCRATCH/demo.tape
sed -e "s|@@MACHINE_NAME@@|$MACHINE_NAME|g" \
    -e "s|@@FQDN@@|$MACHINE_FQDN|g" \
    -e "s|@@IMAGE_REGISTRY@@|$STACK_IMAGE_REGISTRY|g" \
    demo/demo.tape > "$rendered_tape"

mkdir -p "$REPO_ROOT/docs/images"

echo "==> Recording (creates and destroys a real VM, ~15 minutes)"
# vhs resolves the tape's Output path against its own cwd, so stay at the repo
# root even though the rendered tape lives under the scratch dir.
vhs "$rendered_tape"

echo "==> Cleaning up"
sweep_leftovers
restore_known_hosts
rm -rf "$SCRATCH"

echo
echo "Wrote $REPO_ROOT/docs/images/demo.gif"
ls -lh "$REPO_ROOT/docs/images/demo.gif"
