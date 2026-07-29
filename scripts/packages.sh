#!/usr/bin/env bash
#
# packages.sh -- install arbitrary distro packages with apt.
#
# Usage:
#   packages.sh <package> [<package> ...]
#
# All arguments are passed through to "apt install", e.g.
#   packages.sh build-essential jq
#
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_INSTALL="sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

sudo apt update
$APT_INSTALL $*
