# Demo recording

`docs/images/demo.gif`, the animation at the top of the project README, is
recorded from `demo.tape` by [vhs](https://github.com/charmbracelet/vhs).

Nothing in it is faked or edited. Every command really runs: a VM is created at
DigitalOcean with the [machine](https://github.com/stirlingbridge/machine)
utility, cloud-init runs this repository's `combine.sh` on it with `health.sh`,
`fqdn.sh` and `k3s-node.sh`, and the resulting single-node Kubernetes cluster
then has the [example todo
application](https://github.com/bozemanpass/example-todo-list) deployed onto it
with the [stack](https://github.com/bozemanpass/stack) utility, reached over
HTTPS with a real Let's Encrypt certificate. The machine is destroyed on camera
at the end, along with the DNS record created for it.

```bash
./demo/record-demo.sh
```

One run creates and destroys one VM and takes about fifteen minutes, most of it
off camera.

## Requirements

* `vhs`, `ttyd`, `ffmpeg`, `machine`, `stack`, `kubectl`, `docker`, `jq`,
  `openssl`, `curl`, `git` and `ssh` on `PATH`
  (`sudo apt-get install -y ffmpeg ttyd`; vhs from its
  [releases page](https://github.com/charmbracelet/vhs/releases))
* A DigitalOcean account set up as `tests/README.md` describes — an API token
  with the same scopes, a registered SSH key with the matching private key on
  this machine, a DNS zone and a project — plus a container image registry the
  cluster can pull the application's images from.

### Environment

| Variable | Description |
|---|---|
| `MACHINE_DO_TOKEN` | DigitalOcean API token |
| `MACHINE_SSH_KEY_NAME` | Name of an SSH key registered at DigitalOcean |
| `MACHINE_SSH_KEY_FILE` | Path to the private key **matching that registered key** |
| `MACHINE_DNS_ZONE` | DNS zone hosted at DigitalOcean (e.g. `do.example.com`) |
| `MACHINE_PROJECT` | DigitalOcean project to assign the VM to |
| `LETSENCRYPT_EMAIL` | Let's Encrypt contact address |
| `STACK_IMAGE_REGISTRY` | Registry the images are pushed to and the cluster pulls from, including any org path |
| `STACK_IMAGE_REGISTRY_USER` | Username for that registry (for a DigitalOcean registry, the API token) |
| `STACK_IMAGE_REGISTRY_TOKEN` | Password for that registry (for a DigitalOcean registry, the API token) |

Optional:

| Variable | Default | Description |
|---|---|---|
| `DEMO_MACHINE_NAME` | `k3sdemo` | Machine name; its FQDN is this under the zone |
| `MACHINE_REGION` | `nyc3` | DigitalOcean region |
| `MACHINE_SIZE` | `s-2vcpu-4gb` | Machine size |
| `MACHINE_IMAGE` | `ubuntu-24-04-x64` | Machine image |
| `MACHINE_PROVISIONING_URL` | this commit's `combine.sh` | Which scripts to record |

These are the same names the [stack](https://github.com/bozemanpass/stack)
repository's own demo takes, because it provisions its Kubernetes host with
these scripts in exactly this way; a working setup for one works for the other.
The `E2E_*` names in `tests/` are the same values under the test suite's
convention.

Before creating anything, `record-demo.sh` checks the config against the
provider's API and checks that `MACHINE_SSH_KEY_FILE` really is the private half
of the key registered as `MACHINE_SSH_KEY_NAME`. Those two name the same key in
two different places, and if they drift apart the machine is built with one
key's public half while the recorded `ssh` offers the other's — which surfaces
as `Permission denied (publickey)` a quarter of an hour and one VM into a take,
with the rest of the recording carrying on against an empty kubeconfig.

## Which scripts get recorded

As in `tests/`, the VM downloads the scripts from `raw.githubusercontent.com` on
first boot, so what appears in the recording is decided by a URL and not by your
working tree. By default that URL names **the commit currently checked out**,
and the recorder refuses to run if the remote does not have it — otherwise the
animation would quietly show `main`'s scripts. So commit and push before
recording, or set `MACHINE_PROVISIONING_URL`.

## Nothing secret is on screen

The recording opens by displaying the machine config file, which is the point of
it: the machine type, its `script-url` and its `script-args` are the whole
configuration. So the API token, SSH key name, DNS zone, project and registry
credentials are written into that file as `${...}` environment variable
references, which the machine utility expands when it loads the config. What is
filmed is the reference; the value never appears.

For the same reason the recording runs with `HOME` pointed at a scratch home
under `/tmp/provisioning-demo`, holding only the demo's config, a copy of the
SSH key and the registry login. That keeps the real `~/.config/machine` out of
the recording, keeps the recorder's username out of the paths on screen, and
gives each run a fresh session id — so the `machine list` and `machine destroy`
at the end can only see the machine this recording made.

## How the recording stays short

Provisioning a machine really does take several minutes, and this is an
animation in a README. Two things are prepared or skipped off camera, and
nothing else is:

* The application's container images are built by `record-demo.sh` before
  recording starts, and pushed to the registry from a throwaway deployment in a
  hidden block once the cluster exists. Building three containers is the stack
  utility's business, not this repository's, and it is minutes of build log. The
  `push-images` that is on camera is a real push with nothing left to upload.
* The waits that cannot be prepared away happen in `Hide` blocks: cloud-init
  installing k3s and cert-manager, and later the pods starting, the Gateway
  routing to them and cert-manager completing the ACME exchange. Each of those
  blocks ends with a `clear` *inside* the block — `Hide` stops recording frames
  but the terminal still holds the line that was typed, so without it the wait
  loop would sit on screen for the rest of the recording.

The `machine create` itself, the provisioning status going to `UP`, every
`kubectl` call, the deployment and the HTTPS requests are all recorded as they
happened.

## The tape is a template

The machine's name, its FQDN and the image registry are only known once the
environment is read, so `demo.tape` carries them as `@@...@@` placeholders.
`record-demo.sh` substitutes them into a rendered copy under
`/tmp/provisioning-demo` and runs vhs against that. Run vhs against the rendered
copy, not against `demo.tape` itself.

## Retakes

Each take is a fresh machine, a fresh cluster and therefore a fresh certificate
for the same hostname. Let's Encrypt allows five certificates per week for an
identical set of names, so a run of retakes can hit that limit and start
failing at the HTTPS step. Set `DEMO_MACHINE_NAME` to something else for further
takes — a different hostname is a different certificate as far as the limit is
concerned.

If a run is interrupted before the recorded `machine destroy`, the next one
sweeps up a machine of the same name before it starts; a machine left behind
under a *different* name has to be destroyed by hand:

```bash
machine list --all
machine destroy --delete-dns <machine id>
```
