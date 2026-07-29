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
  echo "$MACHINE_FQDN" > /tmp/fqdn.??
  sudo mv /tmp/fqdn.?? /etc/machine/fqdn
fi

sudo chown -R root:root /etc/machine
