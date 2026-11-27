#!/bin/sh
# Installs one profile on the firewall, then reboots into it.
# Usage (on the firewall):  sudo ./deploy.sh prod|bench [--no-reboot] [--minutes N]
#
# Safety:
#   1. validate.sh must pass.
#   2. Every file it replaces is saved in /var/backups/fw-deploy/<stamp>/ (plus the list of new files and unit states).
#   3. The guard is installed first and a pending marker is written. After the reboot, unless you run
#      fw-deploy-confirm within N minutes (default 15), fw-deploy-guard puts the old files back and reboots again.
#   4. If SSH is lost: plug a laptop into mgmt0 (DHCP 10.255.255.2, or set it by hand) and ssh fwadmin@10.255.255.1.
set -u
P=""
noreboot=0
mins=15
while [ $# -gt 0 ]; do
	case "$1" in
	prod | bench) P=$1 ;;
	--no-reboot) noreboot=1 ;;
	--minutes) shift; mins=${1:-15} ;;
	*) echo "usage: deploy.sh prod|bench [--no-reboot] [--minutes N]" >&2; exit 2 ;;
	esac
	shift
done
[ -n "$P" ] || { echo "usage: deploy.sh prod|bench [--no-reboot] [--minutes N]" >&2; exit 2; }
case "$mins" in '' | *[!0-9]*) echo "--minutes needs a number" >&2; exit 2 ;; esac
D=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
PATH=/usr/sbin:/usr/bin:/sbin:/bin

[ -f /var/lib/fw-deploy/pending ] && { echo "a deploy is still pending: run fw-deploy-confirm or fw-deploy-revert first" >&2; exit 1; }

"$D/validate.sh" "$P" || { echo "validate.sh failed; nothing installed" >&2; exit 1; }

S=$(mktemp -d /tmp/fw-deploy.XXXXXX)
trap 'rm -rf "$S"' EXIT
cp -a "$D/common/." "$S/"
cp -a "$D/profiles/$P/." "$S/"
find "$S" -type f -exec sed -i 's/\r$//' {} +

for n in wan0 trunk0; do
	grep -l -s "^Name=$n\$" "$S"/etc/systemd/network/*.link >/dev/null ||
		{ echo "no .link file for $n: run tools/nic-macs.sh after the i350 is installed" >&2; exit 1; }
done

stamp=$(date +%Y%m%d-%H%M%S)
B=/var/backups/fw-deploy/$stamp
stop() { echo "$1; nothing installed" >&2; exit 1; }
mkdir -p "$B" && chmod 700 /var/backups/fw-deploy || stop "cannot create $B"
(cd "$S" && find . -type f | sed 's#^\./##' | sort) >"$B/files.list"
: >"$B/existed.list"
: >"$B/new.list"
while IFS= read -r f; do
	if [ -e "/$f" ]; then echo "$f" >>"$B/existed.list"; else echo "$f" >>"$B/new.list"; fi
done <"$B/files.list"
# The rollback archive must be complete and readable before anything is replaced.
if [ -s "$B/existed.list" ]; then
	tar -C / -cpf "$B/previous.tar" -T "$B/existed.list" || stop "could not save the files it replaces ($B/previous.tar)"
	tar -tf "$B/previous.tar" >/dev/null || stop "$B/previous.tar is not readable"
fi
UNITS="nftables.service dnsmasq.service unbound.service suricata.service wan-check.timer fw-health.timer fw-suricata-update.timer
fw-blocklists.timer fw-blocklists-load.service fw-dnsbl.timer fw-shaper.service fw-duckdb-update.timer
fw-flowd.service fw-ingest.timer fw-archive.timer fw-asn.timer fw-suricata-rotate.timer fw-report.timer fw-mail.path fw-mail.timer fw-bios-check.timer"
for u in $UNITS; do
	printf '%s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo not-found)"
done >"$B/units.list"
echo "profile=$P" >"$B/profile"
# Secrets in /etc/wan-event must never enter etckeeper's history.
grep -qx 'wan-event/' /etc/.gitignore 2>/dev/null || echo 'wan-event/' >>/etc/.gitignore
command -v etckeeper >/dev/null && etckeeper commit "before fw-deploy $P $stamp" >/dev/null 2>&1

# Guard first, so even a half-finished install is reverted after the reboot. No guard, no install.
for f in usr/local/sbin/fw-deploy-guard usr/local/sbin/fw-deploy-revert usr/local/sbin/fw-deploy-confirm; do
	install -D -m 0755 -o root -g root "$D/guard/$f" "/$f" && sed -i 's/\r$//' "/$f" || stop "could not install /$f"
done
install -D -m 0644 -o root -g root "$D/guard/etc/systemd/system/fw-deploy-guard.service" /etc/systemd/system/fw-deploy-guard.service &&
	sed -i 's/\r$//' /etc/systemd/system/fw-deploy-guard.service || stop "could not install fw-deploy-guard.service"
mkdir -p /var/lib/fw-deploy &&
	printf 'backup=%s\nminutes=%s\nprofile=%s\n' "$B" "$mins" "$P" >/var/lib/fw-deploy/pending || stop "could not write the pending marker"
systemctl daemon-reload
systemctl enable fw-deploy-guard.service >/dev/null 2>&1 ||
	{ rm -f /var/lib/fw-deploy/pending; stop "could not enable fw-deploy-guard.service"; }

# Install the profile.
while IFS= read -r f; do
	case "$f" in
	usr/local/sbin/* | usr/local/share/fw-analysis/tools/bin/*) mode=0755 ;;
	etc/nftables.conf) mode=0755 ;;
	etc/sudoers.d/*) mode=0440 ;;
	*) mode=0644 ;;
	esac
	install -D -m "$mode" -o root -g root "$S/$f" "/$f"
done <"$B/files.list"
install -d -m 0700 -o root -g root /etc/wan-event
install -d -m 0755 -o root -g root /var/lib/wan-event
[ -e /var/log/dnsmasq.log ] || install -m 0640 -o dnsmasq -g adm /dev/null /var/log/dnsmasq.log
[ -e /var/log/firewall.log ] || install -m 0640 -o root -g adm /dev/null /var/log/firewall.log
[ -e /var/log/dnsbl.log ] || install -m 0640 -o root -g adm /dev/null /var/log/dnsbl.log
install -d -m 0755 -o root -g root /var/lib/fw-blocklists /var/lib/fw-health
# unbound does not start if a blocklist zone file is missing: write empty ones until fw-dnsbl fills them.
/usr/local/sbin/fw-dnsbl seed
# Off-box backup: a locked system user; @@ADMIN_HOST@@ installs its key with tools/pull-fw-backup.ps1 -Setup.
id fwbackup >/dev/null 2>&1 ||
	useradd --system --user-group --home-dir /var/lib/fwbackup --create-home --shell /bin/sh fwbackup
install -d -m 0700 -o fwbackup -g fwbackup /var/lib/fwbackup/.ssh

# The database, the daily brief and the mail: users and folders.
/usr/local/sbin/fw-accounts

systemctl daemon-reload
sysctl --system >/dev/null
initrd=ok
update-initramfs -u >/dev/null || initrd=failed   # the initramfs carries the .link files (interface names)
for u in $UNITS; do systemctl enable "$u" >/dev/null 2>&1 || echo "could not enable $u" >&2; done
command -v etckeeper >/dev/null && etckeeper commit "fw-deploy $P $stamp" >/dev/null 2>&1
if [ "$initrd" = failed ]; then
	# Without the new .link files in the initramfs, a reboot would come up with the old interface names.
	logger -t fw-deploy -p daemon.err "installed profile $P (backup $B), but update-initramfs failed. Not rebooting."
	echo "installed profile $P, but update-initramfs failed. Not rebooting." >&2
	echo "Fix it and run  sudo update-initramfs -u , then reboot. Or undo:  sudo fw-deploy-revert --no-reboot" >&2
	exit 1
fi
logger -t fw-deploy "installed profile $P (backup $B); confirm within $mins min after the reboot"

echo "installed profile $P; backup in $B"
echo "after the reboot: ssh in, check, then run  sudo fw-deploy-confirm  within $mins minutes"
if [ $noreboot -eq 1 ]; then
	echo "--no-reboot: reboot when ready. Until then this box resolves DNS through 127.0.0.1, which is not running yet."
	exit 0
fi
systemctl reboot
