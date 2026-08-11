#!/usr/bin/env bash
#
# Static checks over the provisioning scripts and the tests themselves.
#
# Unlike the other tests here these create nothing, cost nothing and take
# seconds, so they run on every pull request rather than weekly. They catch the
# class of mistake that is otherwise only found by provisioning a whole machine
# and watching it fail twenty minutes in: a syntax error, an unquoted expansion
# in a path, a script added without documentation.
#
# Warnings from shellcheck are reported but do not fail the run: the scripts
# predate this suite and carry a few deliberate ones (packages.sh passes its
# arguments on unquoted on purpose). Errors do fail it -- at that severity the
# tool is reporting something that will not do what it appears to.
#
# (No comment line here may begin with the word "shellcheck", which the tool
# reads as a directive to itself.)
#
# Usage:
#   run-static-checks.sh
#
source "$( dirname -- "${BASH_SOURCE[0]}" )/lib/common.sh"

repo_dir=$( cd "$( dirname -- "${BASH_SOURCE[0]}" )/.." && pwd )
cd "$repo_dir"

failures=0

check_failed () {
  echo "FAILED: $*" 1>&2
  failures=$((failures + 1))
}

banner "static checks"

all_scripts=( scripts/*.sh tests/*.sh tests/lib/*.sh )

# --- syntax -------------------------------------------------------------------

for script in "${all_scripts[@]}"; do
  if ! bash -n "$script" 2>&1; then
    check_failed "$script has a syntax error"
  fi
done
pass "all ${#all_scripts[@]} scripts parse"

# --- shellcheck ---------------------------------------------------------------

if command -v shellcheck > /dev/null 2>&1; then
  if ! shellcheck --severity=error "${all_scripts[@]}"; then
    check_failed "shellcheck reported an error"
  else
    pass "shellcheck found no errors"
  fi
  echo "--- shellcheck warnings (advisory) ---"
  shellcheck --severity=warning "${all_scripts[@]}" || true
  echo "--------------------------------------"
else
  echo "SKIPPED: shellcheck is not installed"
fi

# --- conventions --------------------------------------------------------------

# Every script is fetched and run by a provisioning tool, which chmods what it
# downloads -- but combine.sh runs a local path as-is, and a script committed
# non-executable is a surprise waiting for whoever does that.
for script in scripts/*.sh; do
  if [ ! -x "$script" ]; then
    check_failed "$script is not executable"
  fi
done
pass "every script in scripts/ is executable"

# The comment block at the top of each script is its real documentation -- it
# is what someone reads when deciding what to put in script-args, and several
# scripts have options that appear nowhere else.
for script in scripts/*.sh; do
  if ! head -3 "$script" | grep -q "^#!.*sh"; then
    check_failed "$script has no shebang"
  fi
  if ! sed -n '2,6p' "$script" | grep -q "$( basename "$script" ) --"; then
    check_failed "$script has no '<name> -- <summary>' header comment"
  fi
done
pass "every script in scripts/ has a shebang and a header comment"

# lib/common.sh applies the suite-wide defaults (size, timeout, region) as it
# is sourced, so a test setting its own default afterwards has no effect and
# says so nowhere -- the error test silently ran on the wrong machine size and
# with the wrong timeout for exactly this reason. Such a default has to come
# before the source line.
#
# Only the variables common.sh actually defaults are a problem, so read the
# list out of it rather than hard-coding one that would drift: a test setting
# E2E_K3S_MODE after the source line is fine, because nothing else sets it.
defaulted=$( sed -nE 's/^(E2E_[A-Z0-9_]+)=\$\{\1:-.*/\1/p' tests/lib/common.sh | paste -sd'|' )
late_defaults=0
for script in tests/run-*-test.sh; do
  late=$( awk -v vars="$defaulted" '
    /^[[:space:]]*source .*common\.sh/ { sourced = 1; next }
    sourced && $0 ~ "^[[:space:]]*(" vars ")=\\$\\{" { print FILENAME ":" FNR ": " $0 }
  ' "$script" )
  if [ -n "$late" ]; then
    echo "$late"
    check_failed "$script sets an E2E_ default after sourcing common.sh, where it is ignored"
    late_defaults=1
  fi
done
[ $late_defaults -eq 0 ] && pass "no test sets a common.sh default after sourcing it"

# A script nobody knows about is a script nobody uses. The README is the only
# index of what this repository provides.
for script in scripts/*.sh; do
  if ! grep -q "^### $( basename "$script" )\$" README.md; then
    check_failed "$( basename "$script" ) has no '### <name>' section in README.md"
  fi
done
pass "every script in scripts/ is documented in README.md"

# --- result -------------------------------------------------------------------

if [ $failures -ne 0 ]; then
  banner "static checks: FAILED ($failures)"
  exit 1
fi
banner "static checks: PASSED"
