#!/usr/bin/env bash
#
# Run the whole test suite.
#
# The static checks run first and always. The end-to-end tests each provision a
# real VM at DigitalOcean, so they cost real money and real minutes; they are
# skipped unless the environment they need is set (see tests/README.md).
#
# Tests run in sequence, and a failing one does not stop the others: with a VM
# per test, finding out that two tests fail is worth the extra few minutes.
# CI runs them as a matrix instead, one job per test, in parallel.
#
# Usage:
#   run-all-tests.sh [--static-only] [<test> ...]
#
#   --static-only  Run only the checks that cost nothing.
#   <test>         Name of a test to run (k3s, combine, error). The default is
#                  all of them.
#
tests_dir=$( cd "$( dirname -- "${BASH_SOURCE[0]}" )" && pwd )

static_only=false
requested=()
for arg in "$@"; do
  case $arg in
    --static-only) static_only=true ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             requested+=("$arg") ;;
  esac
done
if [ ${#requested[@]} -eq 0 ]; then
  requested=(combine error k3s)
fi

failed=()
passed=()
skipped=()

if "${tests_dir}/run-static-checks.sh"; then
  passed+=(static-checks)
else
  failed+=(static-checks)
fi

if [ "$static_only" != "true" ]; then
  for name in "${requested[@]}"; do
    script="${tests_dir}/run-${name}-test.sh"
    if [ ! -x "$script" ]; then
      echo "No such test: $name ($script)" 1>&2
      failed+=("$name")
      continue
    fi
    # A missing token means the environment was never set up, which is a skip.
    # A missing DNS zone with a token set is a half-configured environment,
    # which the test itself reports as a failure.
    if [ -z "$E2E_DO_TOKEN" ]; then
      skipped+=("$name")
      continue
    fi
    if "$script"; then
      passed+=("$name")
    else
      failed+=("$name")
    fi
  done
fi

echo
echo "=============================================================="
echo "test summary"
echo "=============================================================="
[ ${#passed[@]}  -gt 0 ] && echo "passed:  ${passed[*]}"
[ ${#skipped[@]} -gt 0 ] && echo "skipped: ${skipped[*]} (E2E_DO_TOKEN is not set)"
[ ${#failed[@]}  -gt 0 ] && echo "failed:  ${failed[*]}"

if [ ${#failed[@]} -gt 0 ]; then
  exit 1
fi
exit 0
