#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

DEFAULT_SCRIPT_URL_PREFIX="$(dirname ${MACHINE_SCRIPT_URL})"
if [[ -z "$DEFAULT_SCRIPT_URL_PREFIX" ]]; then
  DEFAULT_SCRIPT_URL_PREFIX="https://raw.githubusercontent.com/bozemanpass/machine-provisioning/refs/heads/main/scripts"
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "$0 called with $*"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

SCRIPTS=()
declare -A ARGS

while (( "$#" )); do
   case $1 in
      --script-url)
         shift&&SCRIPTS+=("$1")||die
         ;;
      --script-args)
        shift&&ARGS[$(( ${#SCRIPTS[@]} ))]="$1"||die
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

maybe_install wget

step=0
rc=0

for script in "${SCRIPTS[@]}"; do
  step=$((step + 1))
  echo "**************************************************************************************"
  echo "$script BEGIN"
  cmd=""

  # Local path
  if [[ $script == /* ]]; then
   cmd="$script"
  else
    script_url="$script"
    if [[ $script_url != http* ]]; then
      script_url="${DEFAULT_SCRIPT_URL_PREFIX}/${script}"
    fi
    echo "Downloading $script_url to /tmp/combine.script.$step ..."
    wget -q -O /tmp/combine.step.$step "$script_url"
    chmod 700 /tmp/combine.step.$step
    cmd=/tmp/combine.step.$step
  fi

  echo "Running: $cmd ${ARGS["$step"]}"
  $cmd ${ARGS["$step"]} && rc=$? || rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "$script FAILED rc=$rc"
  fi
  echo "$script END"
  echo "#####################################################################################"

  if [[ $rc != 0 ]]; then
    break
  fi
done

rm -f /tmp/combine.step.*

if [[ $rc -eq 0 ]]; then
  echo "All scripts completed successfully."
fi

exit $rc
