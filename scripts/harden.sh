#!/usr/bin/env bash
if [[ -n "$MACHINE_SCRIPT_DEBUG" ]]; then
    set -x
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_INSTALL="sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y install"
APT_PURGE="sudo --preserve-env=DEBIAN_FRONTEND,NEEDRESTART_MODE apt -y purge"

set -eo pipefail  ## https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/

echo "***********************************************************************"
echo "* harden.sh"
echo "***********************************************************************"
echo "$0 called with $*"

# Defaults
SSH_PORT=22
SSH_ALLOW_FROM=""
SSH_USERS="${USER}"
REBOOT_TIME="04:00"
UPGRADE_ORIGINS=()
PRO_TOKEN=""
REMOVE_DROPLET_AGENT=false
KEEP_SNAPD=false

while (( "$#" )); do
   case $1 in
      --ssh-port)
         shift&&SSH_PORT="$1"||{ echo "Missing --ssh-port value"; exit 1; }
         ;;
      --ssh-allow-from)
         shift&&SSH_ALLOW_FROM="$1"||{ echo "Missing --ssh-allow-from value"; exit 1; }
         ;;
      --ssh-users)
         shift&&SSH_USERS="$1"||{ echo "Missing --ssh-users value"; exit 1; }
         ;;
      --reboot-time)
         shift&&REBOOT_TIME="$1"||{ echo "Missing --reboot-time value"; exit 1; }
         ;;
      --upgrade-origin)
         shift&&UPGRADE_ORIGINS+=("$1")||{ echo "Missing --upgrade-origin value"; exit 1; }
         ;;
      --pro-token)
         shift&&PRO_TOKEN="$1"||{ echo "Missing --pro-token value"; exit 1; }
         ;;
      --remove-droplet-agent)
         REMOVE_DROPLET_AGENT=true
         ;;
      --keep-snapd)
         KEEP_SNAPD=true
         ;;
      *)
         echo "Unrecognized argument: $1"
         ;;
   esac
   shift
done

# Validate arguments
if [[ -z "$SSH_ALLOW_FROM" ]]; then
    echo "Error: --ssh-allow-from is required (comma-separated list of addresses/CIDRs permitted to ssh in)"
    exit 1
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo "Error: invalid --ssh-port: $SSH_PORT"
    exit 1
fi
if ! [[ "$REBOOT_TIME" =~ ^[0-2][0-9]:[0-5][0-9]$ ]]; then
    echo "Error: invalid --reboot-time (expected HH:MM): $REBOOT_TIME"
    exit 1
fi

# Split the ssh allow list into IPv4 and IPv6 sets
SSH_ALLOW_V4=()
SSH_ALLOW_V6=()
IFS=',' read -ra ALLOW_ENTRIES <<< "$SSH_ALLOW_FROM"
for entry in "${ALLOW_ENTRIES[@]}"; do
    if [[ "$entry" == *:* ]]; then
        SSH_ALLOW_V6+=("$entry")
    else
        SSH_ALLOW_V4+=("$entry")
    fi
done

echo "***********************************************************************"
echo "* Installing packages"
echo "***********************************************************************"

sudo apt update
$APT_INSTALL nftables unattended-upgrades needrestart

echo "***********************************************************************"
echo "* Removing unneeded packages"
echo "***********************************************************************"

if [[ "$KEEP_SNAPD" != "true" ]] && dpkg -s snapd >/dev/null 2>&1; then
    $APT_PURGE snapd
fi
# droplet-agent provides the DigitalOcean web console. The recovery console still works without it.
if [[ "$REMOVE_DROPLET_AGENT" == "true" ]] && dpkg -s droplet-agent >/dev/null 2>&1; then
    $APT_PURGE droplet-agent
fi
sudo apt -y autoremove

echo "***********************************************************************"
echo "* Configuring firewall"
echo "***********************************************************************"

# We manage our own nftables table rather than the whole ruleset so that rules
# installed by docker (or anything else) are left alone.
if which ufw >/dev/null 2>&1; then
    sudo ufw --force disable
fi

set_elements() {
    local IFS=','
    if (( $# > 0 )); then
        echo "elements = { $* }"
    fi
}

cat >/tmp/harden.nft.$$ <<EOF
#!/usr/sbin/nft -f
# Managed by machine-provisioning harden.sh -- changes will be overwritten

table inet harden
delete table inet harden

table inet harden {
    set ssh_allow_v4 {
        type ipv4_addr
        flags interval
        $(set_elements "${SSH_ALLOW_V4[@]}")
    }

    set ssh_allow_v6 {
        type ipv6_addr
        flags interval
        $(set_elements "${SSH_ALLOW_V6[@]}")
    }

    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept

        icmp type echo-request limit rate 5/second accept
        meta l4proto ipv6-icmp accept

        tcp dport ${SSH_PORT} ip saddr @ssh_allow_v4 ct state new accept
        tcp dport ${SSH_PORT} ip6 saddr @ssh_allow_v6 ct state new accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;

        # Containers have no business talking to the cloud metadata service (it serves user-data).
        ip daddr 169.254.169.254 drop
    }
}
EOF

sudo nft -c -f /tmp/harden.nft.$$
sudo install -m 644 -o root -g root /tmp/harden.nft.$$ /etc/nftables.conf
rm -f /tmp/harden.nft.$$

# The stock unit flushes the entire ruleset on stop, which would also wipe docker's rules.
sudo mkdir -p /etc/systemd/system/nftables.service.d
sudo tee /etc/systemd/system/nftables.service.d/harden.conf > /dev/null <<EOF
[Service]
ExecStop=
ExecStop=-/usr/sbin/nft delete table inet harden
EOF
sudo systemctl daemon-reload
sudo systemctl enable nftables
sudo nft -f /etc/nftables.conf

echo "***********************************************************************"
echo "* Configuring sshd"
echo "***********************************************************************"

# sshd uses the first value it sees for most options, and the Include of
# sshd_config.d is at the top of sshd_config, so 00- wins.
sudo tee /etc/ssh/sshd_config.d/00-harden.conf > /dev/null <<EOF
# Managed by machine-provisioning harden.sh -- changes will be overwritten
Port ${SSH_PORT}
AllowUsers ${SSH_USERS//,/ }
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
PermitTunnel no
PermitUserEnvironment no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sudo mkdir -p /run/sshd
sudo sshd -t

# Ubuntu 24.04 socket-activates sshd. Switch to the plain service so the Port
# setting above is all that determines what sshd listens on.
if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    sudo systemctl disable --now ssh.socket
fi
sudo systemctl enable ssh.service
sudo systemctl restart ssh.service

sudo passwd -l root

echo "***********************************************************************"
echo "* Configuring kernel parameters"
echo "***********************************************************************"

sudo tee /etc/sysctl.d/90-harden.conf > /dev/null <<EOF
# Managed by machine-provisioning harden.sh -- changes will be overwritten
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
fs.suid_dumpable = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
EOF
sudo sysctl --system > /dev/null

echo "***********************************************************************"
echo "* Configuring automatic updates"
echo "***********************************************************************"

sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

{
    echo "// Managed by machine-provisioning harden.sh -- changes will be overwritten"
    if (( ${#UPGRADE_ORIGINS[@]} > 0 )); then
        echo "Unattended-Upgrade::Origins-Pattern {"
        for origin in "${UPGRADE_ORIGINS[@]}"; do
            echo "    \"${origin}\";"
        done
        echo "};"
    fi
    echo "Unattended-Upgrade::Automatic-Reboot \"true\";"
    echo "Unattended-Upgrade::Automatic-Reboot-WithUsers \"true\";"
    echo "Unattended-Upgrade::Automatic-Reboot-Time \"${REBOOT_TIME}\";"
    echo "Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";"
    echo "Unattended-Upgrade::Remove-Unused-Dependencies \"true\";"
} | sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-harden > /dev/null

# Restart services using upgraded libraries without prompting
sudo mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" | sudo tee /etc/needrestart/conf.d/harden.conf > /dev/null

sudo unattended-upgrade --dry-run > /dev/null

if [[ -n "$PRO_TOKEN" ]]; then
    echo "***********************************************************************"
    echo "* Attaching Ubuntu Pro and enabling Livepatch"
    echo "***********************************************************************"
    if ! sudo pro status --format json | grep -q '"attached": true'; then
        sudo pro attach "$PRO_TOKEN"
    fi
    sudo pro enable livepatch --assume-yes || echo "Warning: unable to enable livepatch (it may already be enabled)"
fi

echo "***********************************************************************"
echo "* Hardening summary"
echo "***********************************************************************"
sudo sshd -T | grep -E '^(port|allowusers|permitrootlogin|passwordauthentication) '
sudo nft list table inet harden
