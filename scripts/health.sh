#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "$0 called with $*"

set -eo pipefail

PORT=4242

while (( "$#" )); do
   case $1 in
      --port)
         shift&&PORT="$1"||die
         ;;
         *)
         echo "Unrecognized argument: $1"
         ;;
   esac
   shift
done

function maybe_install {
  local todo=""
  while (( "$#" )); do
    local exists=false
    which $1 >/dev/null && exists=true || exists=false
    if [[ "true" != "$exists" ]]; then
      todo="$todo $1"
    fi
    shift
  done
  if [[ ! -z "$todo" ]]; then
    echo "**************************************************************************************"
    echo "Installing required packages"
    sudo apt -y update
    sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install $todo
  fi
}

maybe_install python3

sudo mkdir -p /var/opt/machine/health/cgi-bin

cat >/tmp/machine.health.$$ <<EOF
#!/bin/bash
CLOUD_INIT_LOG=/var/log/cloud-init-output.log
STATUS="INITIALIZING"

sudo grep 'Failed to run module scripts_user' \$CLOUD_INIT_LOG >/dev/null
if [ \$? -eq 0 ]; then
  STATUS="ERROR"
else
  sudo grep '^Cloud-init v' \$CLOUD_INIT_LOG | grep 'finished at' | grep 'Up.*seconds' >/dev/null
  if [ \$? -eq 0 ]; then
    STATUS="UP"
  fi
fi

echo "Content-Type: application/json"
echo ""
echo "{ \"status\": \"\$STATUS\" }"
EOF
sudo mv /tmp/machine.health.$$ /var/opt/machine/health/cgi-bin/cloud-init-status
sudo chmod -R a+rX /var/opt/machine
sudo chmod -R a+x /var/opt/machine/health/cgi-bin/cloud-init-status

nohup python3 -m http.server --cgi --directory /var/opt/machine/health $PORT &
