# Provisioning scripts for the machine utility

These provisioning scripts are designed to be used in conjunction with any Linux machine provisioning
tool that can execute a script after first boot (typically via the `cloud-init` mechanism), for example
the [machine](https://github.com/stirlingbridge/machine) utility.

## Scripts

### combine.sh
Supports the execution of several other scripts together (useful because machine provisioning only allows one script to be executed).
### docker.sh
Installs Docker and performs associated system configuration.
### error.sh
Always fails. A test script for checking that provisioning failures are detected and reported correctly.
### fqdn.sh
Writes the machine's fully qualified domain name (taken from the `MACHINE_FQDN` environment variable) to `/etc/machine/fqdn`, where other scripts and applications can read it.
### health.sh
Serves a provisioning status endpoint at `/cgi-bin/cloud-init-status` (port 4242 by default, set with `--port`), returning JSON of the form `{ "status": "INITIALIZING" | "UP" | "ERROR" }` so a remote caller can tell when provisioning has finished.
### k3s-node.sh
Installs a single-node k8s cluster using k3s.

By default the cluster serves application traffic through the [Gateway API](https://gateway-api.sigs.k8s.io/). k3s's bundled traefik is kept as the Gateway API implementation and a `Gateway` named `stack-gateway` is created for workloads to attach `HTTPRoute`s to, so no workload names a particular proxy and the implementation remains a property of the machine. HTTPS is provisioned per application: an HTTPS listener is added to the Gateway for each application's hostname (the [stack](https://github.com/bozemanpass/stack) utility does this at deploy time), and cert-manager obtains its certificate over ACME HTTP-01. The Gateway is deliberately created by the script rather than by the traefik helm chart, so that these dynamically-added listeners are not dropped when the chart is re-synced. Alternatively, adding `--wildcard-domain <domain>` (which also requires `--do-dns-access-token` and `--letsencrypt-email`) serves a single `*.<domain>` certificate from the Gateway's HTTPS listener, covering every application under that domain with no per-application listeners.

Whichever of those two is used, `--letsencrypt-staging` points the Gateway at Let's Encrypt's staging environment instead of production. Staging has far higher rate limits but issues certificates signed by an untrusted root, which clients reject, so it is for shaking out a machine's DNS, firewall and listener configuration without burning the production rate limit. Re-running the script without the option switches the machine back to production certificates.

Passing `--nginx-ingress` provisions the legacy Ingress API instead, using the nginx ingress controller with per-application Let's Encrypt certificates from cert-manager. Note that [ingress-nginx is retired upstream](https://www.kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) and no longer receives fixes of any kind, including security fixes.

Passing `--kata` additionally installs [Kata Containers](https://katacontainers.io/), so that a pod can be run inside its own lightweight VM with its own kernel rather than sharing the host's. It is opt-in per workload: the installation (upstream's `kata-deploy` helm chart, which knows how to reconfigure k3s's containerd) creates a `kata` RuntimeClass, and only a pod whose spec sets `runtimeClassName: kata` gets a VM. Everything else — k3s's own system pods, traefik, cert-manager, and any workload that says nothing about a runtime class — keeps running as an ordinary container, and the cluster is otherwise indistinguishable from one provisioned without the option. A VM needs hardware virtualization, so on a cloud machine the provider must allow nested virtualization; the script checks that the host really can create a VM before it installs anything, and fails there if it cannot.

The comment at the top of the script documents all of the script's options.
### packages.sh
Installs the distro packages named in its arguments, which are passed through to `apt install`.
### podman.sh
Installs podman (only install one of: Docker and podman).
### stack.sh
Installs the [stack](https://github.com/bozemanpass/stack) application deployment utility.
### web-shell.sh
Installs browser-based remote shell access using ttyd, Caddy (with Let's Encrypt TLS), and JWT authentication with asymmetric keys. Supports interactive terminal sessions and programmatic command execution from browser JavaScript. See [examples/web-shell/](examples/web-shell/) for a complete example app and detailed documentation.

## Tests
Because every script here exists to change the state of a machine, the tests in [tests/](tests/) provision real VMs at DigitalOcean with the [machine](https://github.com/stirlingbridge/machine) utility, run the scripts under test on them, and then assert over SSH (and, for `k3s-node.sh`, over `kubectl`) that the machine really ended up as documented. Each test destroys its VM on exit. `tests/run-static-checks.sh` costs nothing and runs on every pull request; the rest cost a VM apiece and run weekly or on demand. See [tests/README.md](tests/README.md).

## Example
Scripts can be used individually, or together to provision more complex machine configurations specifying arguments as shown in the following `~/.machine/config.yaml` example. It provisions a machine that has the `build-essential` package installed, then podman, the stack utility and finally a single node k8s cluster, with appropriate configuration for hosting applications with TLS:
```yaml
machines:
    k8s-stack-host:
        new-user-name: bpi
        script-dir: /opt/bpi
        script-url: https://raw.githubusercontent.com/stirlingbridge/machine-provisioning/refs/heads/main/scripts/combine.sh
        script-path: /opt/bpi/combine.sh
        script-args:
          - packages.sh build-essential
          - podman.sh
          - stack.sh
          - k3s-node.sh -y --letsencrypt-email user@example.com --do-dns-access-token ZZZZ --image-registry registry.digitalocean.com --image-registry-username user@example.com --image-registry-password YYYY
```
Each entry in the `script-args` list names one script followed by its arguments. An argument that itself contains spaces can be quoted inside the entry, e.g. `- 'motd.sh --message "hello world"'`.

The older flag-based syntax is still supported, with `script-args` given as a single string:
```yaml
        script-args: >-
          --script-url packages.sh --script-args "build-essential"
          --script-url podman.sh
          --script-url k3s-node.sh --script-args "-y --letsencrypt-email user@example.com"
```
