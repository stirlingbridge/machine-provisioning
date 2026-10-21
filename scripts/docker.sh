#!/usr/bin/env bash
#
# docker.sh -- install Docker CE from the official Docker apt repository and
# add the invoking user to the docker group.
#
# Usage:
#   docker.sh [-f]
#
#   -f   Reinstall even if docker is already present (otherwise this script
#        does nothing when docker is already installed).
#
# Install only one of docker.sh and podman.sh on a given machine.
#
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_INSTALL="sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

which docker >/dev/null && rc=$? || rc=$?
if [[ $rc -eq 0 ]]; then
  echo "docker already installed."
  if [[ "$1" != "-f" ]]; then
    exit 0
  fi
fi

sudo apt update
$APT_INSTALL apt-transport-https ca-certificates curl software-properties-common curl

if [[ ! -f "/usr/share/keyrings/docker-archive-keyring.gpg" ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
$APT_INSTALL docker-ce

sudo usermod -aG docker ${USER}
