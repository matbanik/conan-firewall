#!/bin/sh
# Writes systemd .link files that name the i350 ports by their permanent MAC:
#   lowest PCI function -> wan0 (to the provider's ONT), next -> trunk0 (to the switch), then spare2, spare3.
# Run on the firewall after the NIC is installed:  sudo ./tools/nic-macs.sh
# It writes into this tree (common/etc/systemd/network/); deploy.sh installs them.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
D=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$D/common/etc/systemd/network}
mkdir -p "$OUT"
names="wan0 trunk0 spare2 spare3"
n=0
for dev in $(ls -d /sys/bus/pci/drivers/igb/0000:* 2>/dev/null | sort); do
	pci=${dev##*/}
	for net in "$dev"/net/*; do
		[ -e "$net" ] || continue
		ifc=${net##*/}
		mac=$(ethtool -P "$ifc" 2>/dev/null | awk '{ print $NF }')
		case "$mac" in '' | 00:00:00:00:00:00) mac=$(cat "$net/address") ;; esac
		n=$((n + 1))
		name=$(echo $names | cut -d ' ' -f $n)
		[ -n "$name" ] || name=spare$n
		f=$OUT/2$n-$name.link
		printf '# i350 PCI %s (was %s)\n[Match]\nPermanentMACAddress=%s\n\n[Link]\nName=%s\n' "$pci" "$ifc" "$mac" "$name" >"$f"
		echo "$name <- $pci $ifc $mac ($f)"
	done
done
[ $n -ge 2 ] || { echo "found $n igb (i350) ports; need at least 2. Is the card in?" >&2; exit 1; }
echo "To find a port on the card: sudo ethtool -p <current name> 10   (blinks that port LED for 10 s). Cable the provider's ONT to wan0 and the switch to trunk0."
