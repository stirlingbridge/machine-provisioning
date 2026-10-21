#!/bin/bash
#
# fqdn.sh -- record the machine's fully qualified domain name on disk.
#
# Takes no arguments. If $MACHINE_FQDN is set in the environment (normally by
# the provisioning tool), its value is written to /etc/machine/fqdn, creating
# /etc/machine if necessary. Other scripts and applications can then read the
# machine's FQDN from that file.
#

if [[ ! -d "/etc/machine" ]]; then
  sudo mkdir -p /etc/machine
fi

if [[ -n "$MACHINE_FQDN" ]]; then
  fqdn_file=$(mktemp)
  echo "$MACHINE_FQDN" > "$fqdn_file"
  sudo mv "$fqdn_file" /etc/machine/fqdn
  # mktemp creates the file 0600, but anything on the machine may need to read it
  sudo chmod 644 /etc/machine/fqdn
fi

sudo chown -R root:root /etc/machine
