#!/usr/bin/env bash
#
# error.sh -- always fails. Takes no arguments.
#
# A test script used to check that provisioning failures are detected and
# reported correctly (e.g. that combine.sh stops on error).
#
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

echo "THIS IS AN INTENTIONAL ERROR" 1>&2
exit 1
