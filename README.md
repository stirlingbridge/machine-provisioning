# Provisioning scripts for the machine utility

These provisioning scripts are designed to be used in conjunction with any Linux machine provisioning
tool that can execute a script after first boot (typically via the `cloud-init` mechanism), for example
the [machine](https://github.com/stirlingbridge/machine) utility.

## Scripts

### combine.sh
Supports the execution of several other scripts together (useful because machine provisioning only allows one script to be executed).
### docker.sh
Installs Docker and performs associated system configuration.
### harden.sh
Locks down a host that should accept nothing but ssh from a known set of addresses. Run it last, after any other scripts. It:
* Installs an nftables `inet harden` table that drops all inbound traffic except ssh from `--ssh-allow-from`. The table stands alone, so docker's rules are left in place.
* Blocks containers from reaching the cloud metadata service, which serves the machine's user-data (including these script arguments).
* Restricts sshd to public keys, `--ssh-users` (default: the provisioning user) and `--ssh-port`, with no root login and no forwarding. It also switches Ubuntu 24.04 from socket-activated sshd to the plain service.
* Applies kernel sysctl hardening.
* Enables unattended upgrades with an automatic reboot at `--reboot-time` (default `04:00`) when one is required. Extra repositories can be added with `--upgrade-origin` (e.g. `origin=Docker`).
* Optionally attaches Ubuntu Pro and enables Livepatch (`--pro-token`). Note that the token is then visible in the machine's user-data.
* Purges snapd (`--keep-snapd` to skip) and optionally the DigitalOcean web console agent (`--remove-droplet-agent`).

`--ssh-allow-from` is required and takes a comma-separated list of IPv4/IPv6 addresses or CIDRs. If it's wrong you will be locked out and need the provider's recovery console.

This script only controls inbound traffic. Restrict outbound traffic with the provider's cloud firewall (e.g. a DigitalOcean Cloud Firewall), which also covers container traffic.
### k3s-node.sh
Installs a single-node k8s cluster using k3s.
### podman.sh
Installs podman (only install one of: Docker and podman).
### stack.sh
Installs the [stack](https://github.com/bozemanpass/stack) application deployment utility.
### web-shell.sh
Installs browser-based remote shell access using ttyd, Caddy (with Let's Encrypt TLS), and JWT authentication with asymmetric keys. Supports interactive terminal sessions and programmatic command execution from browser JavaScript. See [examples/web-shell/](examples/web-shell/) for a complete example app and detailed documentation.

## Example
Scripts can be used individually, or together to provision more complex machine configurations specifying arguments as shown in the following `~/.machine/config.yaml` example. It provisions a machine that has the `build-essential` package installed, then podman, the stack utility and finally a single node k8s cluster, with appropriate configuration for hosting applications with TLS:
```yaml
machines:
    k8s-stack-host:
        new-user-name: bpi
        script-dir: /opt/bpi
        script-url: https://raw.githubusercontent.com/stirlingbridge/machine-provisioning/refs/heads/main/scripts/combine.sh
        script-path: /opt/bpi/combine.sh
        script-args: >-
          --script-url packages.sh --script-args "build-essential"
          --script-url podman.sh
          --script-url stack.sh
          --script-url k3s-node.sh
          --script-args "-y --letsencrypt-email user@example.com --do-dns-access-token ZZZZ --image-registry registry.digitalocean.com --image-registry-username user@example.com --image-registry-password YYYY"
```
