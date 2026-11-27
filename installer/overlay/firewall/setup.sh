#!/bin/sh
# Runs inside the new system (chroot) at the end of the install.
# Log: /var/log/firewall-bootstrap.log
set -eu
B=/opt/firewall-bootstrap
echo "firewall bootstrap $(date -u +%FT%TZ)"

# DuckDB CLI (not packaged in Debian)
install -m 0755 "$B/duckdb" /usr/local/bin/duckdb

# SSH: key login only, for fwadmin only
install -d -m 0700 -o fwadmin -g fwadmin /home/fwadmin/.ssh
install -m 0600 -o fwadmin -g fwadmin "$B/authorized_keys" /home/fwadmin/.ssh/authorized_keys
install -m 0644 "$B/sshd-firewall.conf" /etc/ssh/sshd_config.d/10-firewall.conf

# Passwordless sudo so the managing agent can work non-interactively over SSH
echo 'fwadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-fwadmin
chmod 0440 /etc/sudoers.d/10-fwadmin
visudo -cf /etc/sudoers.d/10-fwadmin

# Rule changes go through fw-apply (auto-rollback) and fw-confirm
install -m 0755 "$B/fw-apply" /usr/local/sbin/fw-apply
install -m 0755 "$B/fw-confirm" /usr/local/sbin/fw-confirm
install -d -m 0700 /var/lib/fw-apply

# Bench host firewall: SSH and ping from private ranges, nothing forwarded
install -m 0644 "$B/bench.nft" /etc/nftables.conf
# nft -c needs nf_tables in the running kernel. The installer kernel has none, so nft exits 3
# ("cannot open Netlink socket"); then nftables.service loads the file at first boot instead.
rc=0; nft -c -f /etc/nftables.conf || rc=$?
case $rc in
  0) echo "nftables.conf: check OK" ;;
  3) echo "nftables.conf: not checked here (no nf_tables in the installer kernel); it loads at boot" ;;
  *) exit "$rc" ;;
esac
systemctl enable nftables

# The onboard I219 is eno2 while the CNVi Wi-Fi is on in the BIOS and eno1 while it is off (the BIOS numbers
# both as onboard Ethernet). The installer configures only the name it saw, so configure both: a BIOS toggle
# must not leave the box without an address. deploy.sh later pins the name by MAC (10-mgmt0.link).
for n in eno1 eno2; do
  grep -q "^iface $n " /etc/network/interfaces ||
    printf '\n# onboard I219 (see setup.sh)\nallow-hotplug %s\niface %s inet dhcp\n' "$n" "$n" >> /etc/network/interfaces
done
grep -E '^(allow-hotplug|auto|iface)' /etc/network/interfaces

# Services that stay off until they are configured
for s in dnsmasq unbound; do systemctl disable "$s" || true; done
# unbound's DNSSEC root key is normally made the first time unbound starts. It stays off here, so make the key now:
# validate.sh (unbound-checkconf) fails without it (found 2026-11-22 after the reinstall).
/usr/libexec/unbound-helper root_trust_anchor_update || echo "WARNING: unbound root.key not created"

# Suricata 8 from trixie-backports, disabled until configured
if DEBIAN_FRONTEND=noninteractive apt-get install -y -t trixie-backports suricata; then
  systemctl disable suricata || true
  echo "suricata: $(dpkg-query -W -f='${Version}' suricata)"
else
  echo "WARNING: suricata install failed; install it after first boot"
fi

# Claude Code CLI from Anthropic's signed apt repo (stable channel).
# Key fingerprint 31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE, checked before the build.
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$B/claude-code.asc" /etc/apt/keyrings/claude-code.asc
echo 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main' \
  > /etc/apt/sources.list.d/claude-code.list
# Let unattended-upgrades keep it current along with Debian security updates
cat > /etc/apt/apt.conf.d/52claude-code-unattended <<'EOF'
Unattended-Upgrade::Origins-Pattern { "origin=Anthropic,label=Anthropic"; };
EOF
# Refresh only this source: during the install the installer's cdrom entry is still active in sources.list, and
# a full `apt-get update` fails on it ("does not have a Release file"), which stopped this step on 2026-11-22.
if apt-get update -o Dir::Etc::sourcelist=sources.list.d/claude-code.list -o Dir::Etc::sourceparts=- \
     -o APT::Get::List-Cleanup=0 &&
   DEBIAN_FRONTEND=noninteractive apt-get install -y claude-code; then
  echo "claude-code: $(dpkg-query -W -f='${Version}' claude-code)"
else
  echo "WARNING: claude-code install failed; install it after first boot"
fi

# Fleet member user for the analysis jobs: no sudo, no SSH login, read access to logs (adm, systemd-journal).
# The member loop and claude -p run as this user, so session history and the DuckDB data stay on this box.
if ! id fleet >/dev/null 2>&1; then
  adduser --system --group --home /home/fleet --shell /usr/sbin/nologin fleet
fi
usermod -a -G adm,systemd-journal fleet
install -d -m 0700 -o fleet -g fleet /home/fleet /home/fleet/.agent /home/fleet/.agent/fleet \
  /home/fleet/.agent/fleet/credentials
install -d -m 0750 -o fleet -g fleet /var/lib/fw-analysis /var/lib/fw-analysis/reports /var/lib/fw-analysis/runs
install -m 0644 "$B/fleet-member.service" /etc/systemd/system/fleet-member.service
# Enabled now; it stays inactive until pairing writes member.json (ConditionPathExists)
systemctl enable fleet-member

# etckeeper takes the author from the sudo user's ~/.gitconfig (root's for unattended runs).
# Use the public noreply identity, not user@hostname.
for h in /root /home/fwadmin; do
  git config -f "$h/.gitconfig" user.name @@ETC_GIT_NAME@@
  git config -f "$h/.gitconfig" user.email @@ETC_GIT_EMAIL@@
done
chown fwadmin:fwadmin /home/fwadmin/.gitconfig

# Persistent journal
install -d -m 2755 -g systemd-journal /var/log/journal || true

etckeeper commit "firewall bootstrap from USB installer" || true
echo "bootstrap done"
