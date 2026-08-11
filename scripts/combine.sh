#!/usr/bin/env bash
#
# combine.sh -- run several provisioning scripts in sequence.
#
# Useful because most machine provisioning mechanisms only allow a single
# script to be executed after first boot.
#
# Usage (positional form):
#   combine.sh "<script> [args...]" ["<script> [args...]" ...]
#
#   Each argument names one script to run, optionally followed by its
#   arguments, all in a single shell word. Arguments containing spaces may be
#   quoted within the entry, e.g.:
#     combine.sh "packages.sh build-essential" podman.sh \
#                "k3s-node.sh -y --letsencrypt-email user@example.com"
#
# Usage (legacy flag form, selected when the first argument starts with --):
#   combine.sh --script-url <script> [--script-args "<args>"] [--script-url ... ]
#
#   --script-url   Script to run. Repeat for each script to run.
#   --script-args  Arguments for the immediately preceding --script-url.
#
# In both forms a script is either an absolute local path, a full URL, or a
# bare file name resolved relative to the directory part of
# $MACHINE_SCRIPT_URL (falling back to this repo's scripts directory on
# GitHub).
#
# Scripts run in the order given, and execution stops at the first failure.
# Exits with the exit status of the last script run.
#
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

# Where a bare script name is resolved from: the directory part of the URL this
# script was itself fetched from, so that a machine provisioned from a branch
# runs that branch's scripts throughout. $MACHINE_SCRIPT_URL is set by the
# provisioning tool; falling back to main covers running this script by hand.
#
# Test the variable rather than the result of dirname: with the variable empty
# dirname yields "." if its argument is quoted and an error if it is not, and
# neither is a directory to resolve scripts from.
if [[ -z "$MACHINE_SCRIPT_URL" ]]; then
  DEFAULT_SCRIPT_URL_PREFIX="https://raw.githubusercontent.com/stirlingbridge/machine-provisioning/refs/heads/main/scripts"
else
  DEFAULT_SCRIPT_URL_PREFIX="$(dirname "$MACHINE_SCRIPT_URL")"
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

echo "$0 called with $*"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

SCRIPTS=()
declare -A ARGS

if [[ "$1" == --* ]]; then
  # Legacy flag form
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
else
  # Positional form: each argument is "<script> [args...]" in one word
  for entry in "$@"; do
    [[ -z "${entry// }" ]] && continue
    script="${entry%%[[:space:]]*}"
    SCRIPTS+=("$script")
    ARGS[${#SCRIPTS[@]}]="${entry#"$script"}"
  done
fi

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

  # Split the argument string into words, honoring any quoting inside it
  eval "set -- ${ARGS["$step"]}"
  echo "Running: $cmd $*"
  "$cmd" "$@" && rc=$? || rc=$?
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
