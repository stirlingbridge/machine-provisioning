# Provisioning scripts for the machine utility

These provisioning scripts are designed to be used in conjunction with any Linux machine provisioning
tool that can execute a script after first boot (typically via the `cloud-init` mechanism), for example
the [machine](https://github.com/stirlingbridge/machine) utility.

## Scripts

### combine.sh
Supports the execution of several other scripts together (useful because machine provisioning only allows one script to be executed).
### docker.sh
Installs Docker and performs associated system configuration.
### k3s-node.sh
Installs a single-node k8s cluster using k3s.
### podman.sh
Installs podman (only install one of: Docker and podman).
### stack.sh
Installs the [stack](https://github.com/bozemanpass/stack) application deployment utility.

## Example
Scripts can be used individually, or together to provision more complex machine configurations specifying arguments as shown in the following `~/.machine/config.yaml` example. It provisions a machine that has the `build-essential` package installed, then podman, the stack utility and finally a single node k8s cluster, with appropriate configuration for hosting applications with TLS:
```yaml
machines:
    k8s-stack-host:
        new-user-name: bpi
        script-dir: /opt/bpi
        script-url: https://raw.githubusercontent.com/bozemanpass/machine-provisioning/refs/heads/main/scripts/combine.sh
        script-path: /opt/bpi/combine.sh
        script-args: >-
          --script-url packages.sh --script-args "build-essential"
          --script-url podman.sh
          --script-url stack.sh
          --script-url k3s-node.sh
          --script-args "-y --letsencrypt-email user@example.com --do-dns-access-token ZZZZ --image-registry registry.digitalocean.com --image-registry-username user@example.com --image-registry-password YYYY"
```
