#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

FORCE="false"
VER=""
BUILD="false"

while getopts "bfv:" arg; do
  case $arg in
    f)
      FORCE=true
      ;;
    b)
      BUILD=true
      ;;
    v)
      VER=$OPTARG
      ;;
  esac
done

set -euo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

if [[ -x "/usr/local/bin/stack" ]]; then
  echo "/usr/local/bin/stack already exists"
  if [[ "$FORCE" != "true" ]]; then
    exit 0
  fi
fi

OS_VER=`lsb_release -r | awk '{ print $2 }'`

if [[ "$OS_VER" != "24.04" ]] && [[ "$OS_VER" != "22.04" ]]; then
  echo "Build required on $OS_VER"
  BUILD="true"
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


if [[ "true" == "$BUILD" ]]; then
  maybe_install git python3-venv
  TMPD=`mktemp -d`
  cd $TMPD
  
  git clone https://github.com/bozemanpass/stack.git
  cd stack
  if [[ -n "$VER" ]] && [[ "$VER" != "latest" ]]; then
    git checkout $VER
  fi
  
  scripts/developer-mode-setup.sh
  . venv/bin/activate
  scripts/build_shiv_package.sh
  
  sudo mv package/stack-* /usr/local/bin/stack

  rm -rf $TMPD
else
  maybe_install wget
  if [[ -z "$VER" ]] || [[ "$VER" == "latest" ]]; then
    wget -O /tmp/stack.$$ https://github.com/bozemanpass/stack/releases/latest/download/stack
  else
    wget -O /tmp/stack.$$ https://github.com/bozemanpass/stack/releases/download/${VER}/stack
  fi
  sudo mv /tmp/stack.$$ /usr/local/bin/stack
fi

sudo chmod a+x /usr/local/bin/stack
