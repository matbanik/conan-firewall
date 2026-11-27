#!/bin/sh
# Runs in the installer environment at the end of the install.
# Copies the bootstrap bundle into the new system and runs setup.sh inside it.
set -e
mkdir -p /target/opt/firewall-bootstrap
cp -r /cdrom/firewall/. /target/opt/firewall-bootstrap/
# Redirect inside the chroot: in-target sends the command's own output to the installer syslog, not to stdout.
in-target sh -c 'sh /opt/firewall-bootstrap/setup.sh > /var/log/firewall-bootstrap.log 2>&1'
