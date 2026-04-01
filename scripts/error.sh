#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

echo "THIS IS AN INTENTIONAL ERROR" 1>&2
exit 1
