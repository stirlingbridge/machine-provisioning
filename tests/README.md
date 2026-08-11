# Tests

Nothing in this repository runs on the machine you are reading it from: every
script here changes the state of a freshly provisioned VM, and most of what
they do (install k3s, obtain a certificate, start a container engine) cannot be
faked convincingly enough to be worth faking. So the tests provision real VMs
at DigitalOcean with the [machine](https://github.com/stirlingbridge/machine)
utility, pointing it at the scripts in the checkout under test, and then assert
from the outside that the machine ended up in the state the script promises.

Each test destroys its VM — and its DNS record — on exit, pass or fail.

Only DigitalOcean is tested. These scripts are provider-agnostic (they see a
Debian or Ubuntu machine and a handful of `MACHINE_*` environment variables),
so testing a second provider would be re-testing the machine utility's own
provider support, which the machine repository's e2e suite already covers.

| Test | Costs | Covers |
|---|---|---|
| `run-static-checks.sh` | nothing | syntax, shellcheck, script conventions, README coverage |
| `run-combine-test.sh` | 1 VM, ~10 min | `combine.sh`, `health.sh`, `fqdn.sh`, `packages.sh`, `podman.sh`, `stack.sh` |
| `run-error-test.sh` | 1 VM, ~5 min | `error.sh`, and `combine.sh` stopping at the first failure |
| `run-k3s-test.sh` | 1 VM, ~20 min | `k3s-node.sh` (Gateway API by default, nginx ingress with `E2E_K3S_MODE=ingress`) |

`docker.sh` and `web-shell.sh` are not yet covered. `docker.sh` is an
alternative to `podman.sh` and needs a machine of its own (installing both on
one machine is explicitly unsupported); `web-shell.sh` needs a browser-side
JWT to exercise properly.

## Which scripts get tested

The VM downloads the scripts from `raw.githubusercontent.com` on first boot, so
what is under test is decided by a URL, not by your working tree. By default
that URL names **the commit currently checked out**, and the test refuses to
run if the remote does not have it — otherwise a run would quietly test `main`
and pass while your change was broken.

So: commit and push before running a test. To test something else, set
`E2E_PROVISIONING_URL` to the `combine.sh` you mean to test.

## Prerequisites

- [machine](https://github.com/stirlingbridge/machine) on the PATH
  (`uv tool install git+https://github.com/stirlingbridge/machine.git`)
- `curl`, `git`, `jq`, `ssh`, and for the k3s test `kubectl`
- A DigitalOcean account with an API token, a registered SSH key **and the
  matching private key on this machine** (the tests ssh in to assert), a DNS
  zone hosted at DigitalOcean, and a project to assign the VMs to

The API token needs the same scopes as the machine utility's own e2e tests:

| Scope | Access |
|---|---|
| `droplet` | read, create, delete |
| `ssh_key` | read |
| `domain` | read, create, delete |
| `project` | read, update |
| `tag` | read, create |

## Environment

### Required

| Variable | Description |
|---|---|
| `E2E_DO_TOKEN` | DigitalOcean API token |
| `E2E_SSH_KEY` | Name of an SSH key registered at DigitalOcean |
| `E2E_SSH_KEY_FILE` | Path to the matching private key file |
| `E2E_DO_DNS_ZONE` | DNS zone hosted at DigitalOcean (e.g. `do.example.com`) |
| `E2E_PROJECT` | DigitalOcean project to assign the VMs to |
| `E2E_LETSENCRYPT_EMAIL` | Let's Encrypt contact address (`run-k3s-test.sh` only) |

The names follow the machine repository's `E2E_*` convention, with
`E2E_SSH_KEY_FILE` added: those tests only drive the CLI, whereas these ssh
into the machine they made.

### Optional

| Variable | Default | Description |
|---|---|---|
| `E2E_REGION` | `nyc3` | DigitalOcean region |
| `E2E_IMAGE` | `ubuntu-24-04-x64` | Machine image |
| `E2E_SIZE` | `s-1vcpu-2gb` (`s-2vcpu-4gb` for k3s) | Machine size |
| `E2E_NEW_USER` | `e2euser` | User the provisioning scripts run as |
| `E2E_PROVISION_TIMEOUT` | `1800` | Seconds to allow for cloud-init |
| `E2E_PROVISIONING_URL` | this commit's `combine.sh` | Which scripts to test |
| `E2E_K3S_MODE` | `gateway` | `gateway` or `ingress` (`run-k3s-test.sh`) |
| `E2E_MACHINE_CMD` | `machine` | The machine command to run |
| `E2E_SESSION_ID` | random | Session id tagged onto the VMs |
| `E2E_KEEP_MACHINE` | unset | Set to leave the VM running for debugging |
| `E2E_DEBUG` | unset | Set for `set -x` |

## Running

```bash
export E2E_DO_TOKEN="dop_v1_..."
export E2E_SSH_KEY="my-do-key"
export E2E_SSH_KEY_FILE="$HOME/.ssh/my-do-key"
export E2E_DO_DNS_ZONE="do.example.com"
export E2E_PROJECT="my-project"
export E2E_LETSENCRYPT_EMAIL="me@example.com"

./tests/run-all-tests.sh                # everything
./tests/run-all-tests.sh --static-only  # the free checks only
./tests/run-all-tests.sh k3s            # one test
./tests/run-k3s-test.sh                 # the same, directly
```

`run-all-tests.sh` skips the VM tests entirely when `E2E_DO_TOKEN` is unset, so
running it with no environment at all is a useful pre-commit check.

When a test fails it prints the machine's cloud-init log (and, for the k3s
test, the state of the cluster) before destroying the VM, because in CI that is
the only evidence of what went wrong. To poke at a failure by hand, re-run with
`E2E_KEEP_MACHINE=1` and the VM is left up — with its DNS record, so remember
to destroy it:

```bash
machine --session-id <the id the test printed> destroy --delete-dns <machine id>
```

## Leaked machines

After destroying its VM each test lists whatever is still tagged with its
session id, and **fails** if it finds anything, even if every assertion passed.
A destroy that quietly fails is not a warning: in the machine repository one
such failure leaked a VM per CI run until the account's droplet limit was
reached, with nothing reporting it ([machine#102]).

[machine#102]: https://github.com/stirlingbridge/machine/issues/102

## CI

| Workflow | Runs |
|---|---|
| `.github/workflows/static-checks.yml` | every push and pull request |
| `.github/workflows/e2e-test.yml` | weekly, and on demand (`workflow_dispatch`) |

The e2e workflow runs one job per test in parallel, in the `e2e` GitHub
environment, which needs:

| Kind | Name |
|---|---|
| Secrets | `E2E_DO_TOKEN`, `E2E_SSH_PRIVATE_KEY` |
| Variables | `E2E_SSH_KEY`, `E2E_DO_DNS_ZONE`, `E2E_PROJECT`, `E2E_LETSENCRYPT_EMAIL` |

`E2E_SSH_PRIVATE_KEY` is the private key matching the registered key named by
`E2E_SSH_KEY`; the workflow writes it to a file and sets `E2E_SSH_KEY_FILE`.

The e2e workflow is not run per pull request: each run costs real money and
half an hour, and a pull request from a fork has neither the secrets nor a
commit that `raw.githubusercontent.com` will serve from this repository. Run it
from the Actions tab against a pushed branch instead.

## Cost

The smallest workable machine size is used for each test and the VMs are
destroyed as soon as the assertions finish, so a full run is a few cents.
`k3s-node.sh` is tested with `--letsencrypt-staging`, so a run cannot consume
the production certificate rate limit.
