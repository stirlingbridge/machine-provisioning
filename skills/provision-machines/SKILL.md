---
name: provision-machines
description: >-
  Select and compose machine-provisioning scripts to turn a freshly created VM
  into a configured host — a Docker/podman host running the stack deployment
  tool, or a single-node Kubernetes (k3s) cluster ready to serve applications
  with automatic HTTPS. Use when authoring the `machines:` section of a
  machine-utility config, when the user wants a new VM set up for hosting
  ("configure a server for my app", "set up k8s on my VM"), or when choosing
  cloud-init provisioning scripts. Pairs with the `machine` CLI (creates the
  VM) and `stack` (deploys applications onto the result).
---

# Provision machines

This repo is a library of provisioning scripts, executed once on a VM's first
boot (cloud-init). You don't run them by hand: you *select and compose* them in
the `machines:` section of `~/.machine/config.yml`, and the
[machine](https://github.com/stirlingbridge/machine) utility runs them when it
creates a VM. Each script is self-documenting — its options are in the comment
block at the top of the file.

## Composing scripts

Machine provisioning runs exactly one script, so `combine.sh` is the entry
point: it takes a list where each entry names one script plus its arguments.

```yaml
machines:
  app-host:
    new-user-name: deploy
    script-dir: /opt/bpi
    script-url: https://raw.githubusercontent.com/stirlingbridge/machine-provisioning/refs/heads/main/scripts/combine.sh
    script-path: /opt/bpi/combine.sh
    script-args:
      - health.sh
      - docker.sh
      - stack.sh
```

Rules:

- Order matters: scripts run top to bottom. Put `health.sh` first so status is
  observable during the rest of provisioning.
- Provisioning is unattended — any script that prompts needs its
  auto-confirm flag (`k3s-node.sh -y`).
- **Never put secrets literally in the config file.** The machine config
  supports `${VAR}` environment substitution; use it for registry passwords
  and API tokens.
- An argument containing spaces is quoted inside its entry:
  `- 'motd.sh --message "hello world"'`.

## Script catalog, by goal

| Goal | Script | Notes |
| --- | --- | --- |
| Observe provisioning progress remotely | `health.sh` | Serves `{"status": "INITIALIZING"\|"UP"\|"ERROR"}` at `:4242/cgi-bin/cloud-init-status`; poll it before using the machine |
| Container runtime | `docker.sh` or `podman.sh` | Install exactly one, not both |
| Install the stack deploy tool | `stack.sh` | For hosts that will run `stack` deployments |
| Single-node Kubernetes | `k3s-node.sh` | See below — this is the big one |
| Distro packages | `packages.sh <pkg>...` | Args pass through to `apt install` |
| Record the FQDN on the machine | `fqdn.sh` | Writes `$MACHINE_FQDN` to `/etc/machine/fqdn` |
| Browser-based shell access | `web-shell.sh` | ttyd + Caddy + JWT auth; see `examples/web-shell/` |
| Test failure reporting | `error.sh` | Always fails; test fixture only |

Standard roles:

- **Compose host** (deploy one app with `stack --deploy-to compose`):
  `health.sh`, `docker.sh`, `stack.sh`
- **k8s host** (deploy apps with `stack --deploy-to k8s`):
  `health.sh`, `podman.sh` (or `docker.sh`), `stack.sh`, `k3s-node.sh -y ...`

## k3s-node.sh: the choices that matter

`k3s-node.sh` installs a single-node k3s cluster **already satisfying the
cluster contract that stack's HTTPS deployment expects**: a Gateway named
`stack-gateway` (traefik as the Gateway API implementation), cert-manager with
Gateway API support, and Let's Encrypt ClusterIssuers. stack attaches each
application's HTTPRoute and HTTPS listener to that Gateway at deploy time, and
certificates are issued per application over ACME HTTP-01. If an agent is ever
working with a cluster *not* built by this script, it must verify that contract
(see stack's `docs/gateway-api.md`) rather than assume it.

Decision guidance:

- **Default (no extra flags beyond `-y --letsencrypt-email <addr>`)** —
  per-application HTTP-01 certificates. The right choice when the machine's DNS
  is managed by hand or by the machine utility's `dns-zone`; requires no DNS
  API access. Choose this unless the user says otherwise.
- **`--wildcard-domain <domain>`** (requires `--do-dns-access-token` and
  `--letsencrypt-email`) — one `*.<domain>` DNS-01 certificate covering every
  app. For the roll-your-own-Vercel case: many apps under one domain,
  hostnames created dynamically.
- **`--nginx-ingress`** — legacy Ingress API instead of Gateway API. Only for
  compatibility needs: ingress-nginx is retired upstream and receives no fixes,
  including security fixes. Do not choose this for new machines.
- **`--image-registry <host> --image-registry-username <u>
  --image-registry-password <p>`** — wires registry credentials into the
  cluster (`/etc/rancher/k3s/registries.yaml`) so it can pull the images that
  `stack manage push-images` pushes. A stack k8s deployment needs this; use
  `${VAR}` substitution for the password.
- **Omitting `--letsencrypt-email`** leaves the ClusterIssuers as template
  files in `$HOME` to finish by hand — fine for experiments, wrong for an
  unattended production host.

`$MACHINE_FQDN` (set by the machine utility when a `dns-zone` is configured) is
automatically included in the Kubernetes API server certificate, which is what
makes remote `kubectl`/stack access by hostname work later.

## What provisioning hands to the next stage

| Artifact | Where | Consumed by |
| --- | --- | --- |
| Readiness signal | `http://<fqdn>:4242/cgi-bin/cloud-init-status` → `{"status": "UP"}` | anything waiting to use the machine; on `ERROR` read `/var/log/cloud-init-output.log` |
| stack CLI on the host | on `$PATH` for the configured user | compose-target deployments, run on the VM over ssh |
| kubeconfig | `/etc/rancher/k3s/k3s.yaml` on the VM (addressed to `127.0.0.1` — copy it off and rewrite the server address to the FQDN) | `stack init --deploy-to k8s --kube-config ...` and `kubectl`, run from a workstation |
| `stack-gateway` Gateway + cert-manager + ClusterIssuers | in-cluster | stack's HTTPS route/listener creation at deploy time |
| Registry pull credentials | `/etc/rancher/k3s/registries.yaml` | the cluster, pulling images pushed by `stack manage push-images` |

The end-to-end sequence across machine → these scripts → stack lives in the
`deploy-on-your-own-vm` skill (no-paas toolchain plugin); this skill is the
script-selection layer it defers to.
