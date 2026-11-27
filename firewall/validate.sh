#!/bin/sh
# Checks one profile on the box with each tool's own config test. Applies nothing and changes nothing in /etc.
# Usage (on the firewall):  sudo ./validate.sh prod|bench
set -u
P=${1:-}
D=$(cd "$(dirname "$0")" && pwd)
case "$P" in prod | bench) ;; *) echo "usage: validate.sh prod|bench" >&2; exit 2 ;; esac
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
PATH=/usr/sbin:/usr/bin:/sbin:/bin

T=$(mktemp -d /tmp/fw-validate.XXXXXX)
trap 'rm -rf "$T"' EXIT
S=$T/stage
mkdir -p "$S"
cp -a "$D/common/." "$S/"
cp -a "$D/profiles/$P/." "$S/"
cp -a "$D/guard/." "$S/"
find "$S" -type f -exec sed -i 's/\r$//' {} +   # in case a file picked up CRLF on Windows
# A public tree that was not rendered still has placeholders. deploy.sh runs this script first, so it stops too.
if grep -rlE '@@[A-Z][A-Z0-9_]*@@' "$S" >&2; then
	echo "validate.sh: these files still have placeholders. Render the site first: python tools/render-site.py site/<name>" >&2
	exit 2
fi
chown -R root:root "$S"   # logrotate ignores files not owned by root
chmod 755 "$T"            # chronyd reads its config after dropping to _chrony

fail=0
warn=0
ok() { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; sed 's/^/      /' "$T/out" | head -n 40; fail=1; }
note() { printf 'WARN  %s\n' "$1"; warn=1; }
run() { # name command...
	n=$1
	shift
	if "$@" >"$T/out" 2>&1; then ok "$n"; else bad "$n"; fi
}

echo "== profile $P"

# nftables: syntax and semantics against the running kernel, with the include pointed at the staged profile.
sed "s#/etc/nftables.d/#$S/etc/nftables.d/#" "$S/etc/nftables.conf" >"$T/nftables.conf"
run "nft -c (ruleset)" nft -c -f "$T/nftables.conf"

# Blocklist sets: the parsers, then a sets file in fw-blocklists' format against the staged ruleset.
run "fw-blocklists selftest" sh "$S/usr/local/sbin/fw-blocklists" selftest
{
	cat "$T/nftables.conf"
	echo "flush set inet fw bl_v4"
	echo "add element inet fw bl_v4 { 1.10.16.0/20, 1.10.20.0/22, 50.16.16.211 }"
	echo "flush set inet fw geo_drop_v4"
	echo "add element inet fw geo_log_v4 { 1.0.1.0/24 }"
} >"$T/nftables-bl.conf"
run "nft -c (ruleset + blocklist sets)" nft -c -f "$T/nftables-bl.conf"

# Every log prefix must have the form that rsyslog (30-firewall.conf) and fw-ingest recognise.
grep -o 'log prefix "[^"]*"' "$S/etc/nftables.conf" | sed 's/log prefix "//; s/"$//' >"$T/prefixes"
badp=$(grep -v -E '\bDROP(_[A-Z]+)?\b|\bACCEPT\b' "$T/prefixes" || true)
for p in $(sed 's/ /_/g' "$T/prefixes"); do
	# DROP_A_B is not matched by \bDROP(_[A-Z]+)?\b
	echo "$p" | grep -q -E '^DROP_[A-Z]+_[A-Z]' && badp="$badp $p"
done
if [ -z "$badp" ]; then ok "log prefixes match the parsers"; else echo "$badp" >"$T/out"; bad "log prefixes"; fi

# dnsmasq
run "dnsmasq --test" dnsmasq --test --conf-file=/dev/null --conf-dir="$S/etc/dnsmasq.d"

# unbound: Debian's own conf.d files plus ours, with the RPZ zone files pointed at test copies.
run "fw-dnsbl selftest" sh "$S/usr/local/sbin/fw-dnsbl" selftest
U=$(mktemp -d /var/lib/unbound/fw-validate.XXXXXX)   # AppArmor lets unbound read /var/lib/unbound, not /tmp
trap 'rm -rf "$T" "$U"' EXIT
printf '$TTL 300\n@ SOA localhost. root.localhost. 1 3600 600 86400 300\n  NS localhost.\n' >"$U/empty.rpz"
{ cat "$U/empty.rpz"; printf '%s\n' 'example.com CNAME .' '*.example.com CNAME .' \
	'deb.debian.org CNAME .'; } >"$U/test.rpz"
cp "$S/etc/unbound/rpz-allow.zone" "$U/allow.zone"
cp "$S/etc/unbound/blocked.zone" "$U/blocked.zone"
sed -e "s#zonefile: /etc/unbound/rpz-allow.zone#zonefile: $U/allow.zone#" \
	-e "s#zonefile: /etc/unbound/blocked.zone#zonefile: $U/blocked.zone#" \
	-e "s#zonefile: /var/lib/unbound/rpz/hagezi-pro.rpz#zonefile: $U/test.rpz#" \
	-e "s#zonefile: /var/lib/unbound/rpz/.*#zonefile: $U/empty.rpz#" \
	"$S/etc/unbound/unbound.conf.d/firewall-rpz.conf" >"$U/firewall-rpz.conf"
: >"$T/unbound.conf"
for f in /etc/unbound/unbound.conf.d/*.conf; do
	[ -e "$S/etc/unbound/unbound.conf.d/$(basename "$f")" ] || echo "include-toplevel: \"$f\"" >>"$T/unbound.conf"
done
echo "include-toplevel: \"$S/etc/unbound/unbound.conf.d/firewall.conf\"" >>"$T/unbound.conf"
echo "include-toplevel: \"$U/firewall-rpz.conf\"" >>"$T/unbound.conf"
run "unbound-checkconf" unbound-checkconf "$T/unbound.conf"

# unbound, live test: a second instance on 127.0.0.1@5399 with the staged config and the test zones.
# A blocked name must be logged as an RPZ hit, an allowlisted name must not, and the Firefox canary is NXDOMAIN.
# The blocked name is a real domain. unbound itself answers NXDOMAIN for names under test. (RFC 6761),
# before RPZ runs, so a test. name proves nothing.
if command -v dig >/dev/null; then
	sed 's#interface: 127.0.0.1@5335#interface: 127.0.0.1@5399#' "$S/etc/unbound/unbound.conf.d/firewall.conf" >"$U/firewall.conf"
	# Debian's files are left out: the live unbound owns the trust anchor file and the control socket.
	{
		echo "include-toplevel: \"$U/firewall.conf\""
		echo "include-toplevel: \"$U/firewall-rpz.conf\""
		printf 'server:\n\tchroot: ""\n\tusername: ""\n\tpidfile: "%s/pid"\n\tuse-syslog: no\n\tlogfile: ""\n' "$U"
		printf 'remote-control:\n\tcontrol-enable: no\n'
	} >"$U/unbound.conf"
	unbound -d -c "$U/unbound.conf" >"$U/log" 2>&1 &
	upid=$!
	i=0
	until dig +time=1 +tries=1 -p 5399 @127.0.0.1 use-application-dns.net >/dev/null 2>&1 || [ $i -ge 15 ]; do
		i=$((i + 1))
		sleep 1
	done
	c1=$(dig +time=3 +tries=1 -p 5399 @127.0.0.1 use-application-dns.net A | sed -n 's/.*status: \([A-Z]*\).*/\1/p')
	c2=$(dig +short +time=3 +tries=1 -p 5399 @127.0.0.1 ads.example.com A | tail -n 1)
	c3=$(dig +time=5 +tries=1 -p 5399 @127.0.0.1 deb.debian.org A | sed -n 's/.*status: \([A-Z]*\).*/\1/p')
	kill "$upid" 2>/dev/null
	wait "$upid" 2>/dev/null
	cp "$U/log" "$T/out"
	echo "canary=$c1 blocked=$c2 allowlisted=$c3" >>"$T/out"
	if [ "$c1" = NXDOMAIN ] && [ "$c2" = 0.0.0.0 ] && grep -q 'rpz: applied \[hagezi-pro\] .* ads\.example\.com\. A IN' "$U/log" &&
		! grep -q 'rpz: applied.*deb.debian.org' "$U/log"; then
		ok "unbound RPZ test instance ($(tail -n 1 "$T/out"))"
	else
		bad "unbound RPZ test instance"
	fi
else
	note "dig is missing: unbound RPZ test instance skipped"
fi

# rsyslog: the installed rsyslog.conf, with rsyslog.d swapped for the installed files plus ours.
mkdir -p "$T/rsyslog.d"
for f in /etc/rsyslog.d/*.conf; do
	[ -f "$f" ] && [ ! -e "$S/etc/rsyslog.d/$(basename "$f")" ] && cp "$f" "$T/rsyslog.d/"
done
cp "$S"/etc/rsyslog.d/*.conf "$T/rsyslog.d/"
sed "s#^\$IncludeConfig /etc/rsyslog.d/\*.conf#\$IncludeConfig $T/rsyslog.d/*.conf#" /etc/rsyslog.conf >"$T/rsyslog.conf"
grep -q "$T/rsyslog.d" "$T/rsyslog.conf" || note "rsyslog.conf IncludeConfig line not found; checked without 30-firewall.conf"
run "rsyslogd -N1" rsyslogd -N1 -f "$T/rsyslog.conf"

# sshd: the installed sshd_config, with sshd_config.d swapped for the installed files plus ours.
# Both users must be allowed: fwadmin (admin) and fwbackup (backup pull from @@ADMIN_HOST@@).
if [ -d "$S/etc/ssh/sshd_config.d" ]; then
	mkdir -p "$T/sshd.d"
	cp /etc/ssh/sshd_config.d/*.conf "$T/sshd.d/" 2>/dev/null
	cp "$S"/etc/ssh/sshd_config.d/*.conf "$T/sshd.d/"
	sed "s#^Include /etc/ssh/sshd_config.d/\*.conf#Include $T/sshd.d/*.conf#" /etc/ssh/sshd_config >"$T/sshd_config"
	run "sshd -t" sshd -t -f "$T/sshd_config"
	a=$(sshd -T -f "$T/sshd_config" -C user=fwbackup,host=@@ADMIN_HOST_LC@@,addr=@@LAN_PREFIX@@.5 2>&1 | sed -n 's/^allowusers //p' | tr '\n' ' ')
	if echo " $a " | grep -q ' fwadmin ' && echo " $a " | grep -q ' fwbackup '; then
		ok "sshd AllowUsers: $a"
	else
		echo "allowusers: $a" >"$T/out"
		bad "sshd AllowUsers must name fwadmin and fwbackup"
	fi
fi

# systemd units. Missing /usr/local/sbin programs are fine when the stage provides them.
systemd-analyze verify "$S"/etc/systemd/system/*.service "$S"/etc/systemd/system/*.timer "$S"/etc/systemd/system/*.path >"$T/out" 2>&1
grep -v -E "/usr/local/sbin/($(ls "$S/usr/local/sbin" | tr '\n' '|' | sed 's/|$//'))" "$T/out" |
	grep -v -E '^\s*$' >"$T/out2" || true
if [ -s "$T/out2" ]; then mv "$T/out2" "$T/out"; bad "systemd-analyze verify"; else ok "systemd-analyze verify"; fi

# Database programs: their own parser tests
run "fw-flowd selftest" python3 -B "$S/usr/local/sbin/fw-flowd" selftest
run "fw-ingest selftest" python3 -B "$S/usr/local/sbin/fw-ingest" selftest
run "fw-archive selftest" python3 -B "$S/usr/local/sbin/fw-archive" selftest
if command -v duckdb >/dev/null; then
	run "fwdb schema.sql + detect.sql" sh -c 'cat "$1/schema.sql" "$1/detect.sql" | duckdb -bail' sh "$S/usr/local/share/fwdb"
fi

# Scripts: Python ones are compiled, the others checked by sh
for f in "$S"/usr/local/sbin/* "$S/etc/dhcpcd.exit-hook" "$S"/etc/default/fw-* "$D/deploy.sh" "$D/validate.sh" "$D"/tools/*.sh; do
	[ -f "$f" ] || continue
	if head -n 1 "$f" | grep -q python3; then
		run "python $(basename "$f")" python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$f"
		continue
	fi
	run "sh -n $(basename "$f")" sh -n "$f"
done

# ifupdown: parse the staged interfaces file and check each interface.
if ifquery -i "$S/etc/network/interfaces" --list >"$T/out" 2>&1; then
	ok "ifquery: $(tr '\n' ' ' <"$T/out")"
else
	bad "ifquery"
fi
for i in wan0 trunk0 mgmt0; do
	run "ifquery $i" ifquery -i "$S/etc/network/interfaces" "$i"
done

# chrony (AppArmor stops chronyd -p from reading a temp file, so check the two-line format directly;
# confdir in the installed chrony.conf must point at /etc/chrony/conf.d).
grep -v -E '^[[:space:]]*(#|$)' "$S/etc/chrony/conf.d/lan.conf" |
	grep -v -E '^allow [0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' >"$T/out" || true
if [ -s "$T/out" ]; then bad "chrony lan.conf lines"; else ok "chrony lan.conf lines"; fi
if grep -q '^confdir /etc/chrony/conf.d' /etc/chrony/chrony.conf; then ok "chrony.conf reads conf.d"; else
	echo "confdir line missing" >"$T/out"; bad "chrony.conf reads conf.d"; fi

# CAKE shaper: start and stop fw-shaper on a dummy wan0 in a scratch network namespace.
N=fwval$$
printf 'SHAPER_ENABLE=1\nEGRESS_KBIT=900000\nINGRESS_KBIT=900000\nSHAPER_OPTS="ethernet"\n' >"$T/shaper"
if ip netns add "$N" 2>"$T/out"; then
	ip -n "$N" link add wan0 type dummy && ip -n "$N" link set wan0 up
	ip netns exec "$N" env FW_SHAPER_CONF="$T/shaper" sh "$S/usr/local/sbin/fw-shaper" start >"$T/out" 2>&1
	{ ip netns exec "$N" tc qdisc show dev wan0; ip netns exec "$N" tc qdisc show dev ifb4wan0; } >>"$T/out" 2>&1
	if [ "$(grep -c 'qdisc cake' "$T/out")" -eq 2 ] && grep -q 'qdisc ingress' "$T/out"; then
		ip netns exec "$N" env FW_SHAPER_CONF="$T/shaper" sh "$S/usr/local/sbin/fw-shaper" stop >/dev/null 2>&1
		if ip netns exec "$N" tc qdisc show dev wan0 | grep -q cake; then
			echo "cake still on wan0 after stop" >"$T/out"
			bad "fw-shaper (CAKE) start/stop"
		else
			ok "fw-shaper (CAKE) start/stop on a dummy wan0"
		fi
	else
		bad "fw-shaper (CAKE) start"
	fi
	ip netns del "$N"
else
	bad "ip netns add (for the shaper test)"
fi

# RustDesk remote: a LAN client must reach it even when a blocklist or a country set covers its address.
# Three scratch namespaces: a LAN client, the firewall with the staged ruleset, and the WAN side with the
# remote's address plus one more address in the same /24. The /24 goes into bl_v4, then into geo_drop_v4.
R=$(sed -n 's/^define RUSTDESK_REMOTE = //p' "$S/etc/nftables.d/profile.nft")
O=${R%.*}.7
[ "$O" = "$R" ] && O=${R%.*}.8
L=fwvl$$ F=fwvf$$ W=fwvw$$
rd_ping() { ip netns exec "$L" ping -c 1 -W 1 "$1" >/dev/null 2>&1; }
rd_case() { # set-name
	: >"$T/out"
	nft_ok=1
	printf 'flush set inet fw bl_v4\nflush set inet fw geo_drop_v4\nadd element inet fw %s { %s.0/24 }\n' "$1" "${R%.*}" |
		ip netns exec "$F" nft -f - >>"$T/out" 2>&1 || nft_ok=0
	if [ $nft_ok -eq 1 ] && rd_ping "$R" && ! rd_ping "$O"; then
		ok "RustDesk remote $R reachable from the LAN when its /24 is in $1 ($O dropped)"
	else
		echo "set $1: ping $R must answer and ping $O must not" >>"$T/out"
		bad "RustDesk remote exempt from $1 (LAN to WAN)"
	fi
}
if ip netns add "$L" 2>"$T/out" && ip netns add "$F" 2>>"$T/out" && ip netns add "$W" 2>>"$T/out"; then
	{
		ip -n "$F" link add trunk0 type veth peer name eth0 netns "$L" &&
			ip -n "$F" link add wan0 type veth peer name eth0 netns "$W" &&
			ip -n "$F" addr add 192.0.2.1/24 dev trunk0 && ip -n "$F" addr add "${R%.*}.1/24" dev wan0 &&
			ip -n "$L" addr add 192.0.2.10/24 dev eth0 && ip -n "$W" addr add "$R/24" dev eth0 &&
			ip -n "$W" addr add "$O/24" dev eth0 &&
			ip -n "$L" link set eth0 up && ip -n "$W" link set eth0 up &&
			ip -n "$F" link set trunk0 up && ip -n "$F" link set wan0 up &&
			ip -n "$L" route add default via 192.0.2.1 &&
			ip netns exec "$F" sysctl -qw net.ipv4.ip_forward=1 &&
			ip netns exec "$F" nft -f "$T/nftables.conf"
	} >"$T/out" 2>&1
	if rd_ping "$R" && rd_ping "$O"; then
		rd_case bl_v4
		rd_case geo_drop_v4
	else
		echo "the test network does not forward before any set is filled" >>"$T/out"
		bad "RustDesk remote test setup"
	fi
	ip netns del "$L"; ip netns del "$F"; ip netns del "$W"
else
	bad "ip netns add (for the RustDesk remote test)"
	ip netns del "$L" 2>/dev/null; ip netns del "$F" 2>/dev/null; ip netns del "$W" 2>/dev/null
fi

# sudoers and needrestart drop-ins
run "visudo -cf fw-backup" visudo -cf "$S/etc/sudoers.d/fw-backup"
if command -v needrestart >/dev/null; then
	run "perl -c needrestart 50-firewall.conf" perl -c "$S/etc/needrestart/conf.d/50-firewall.conf"
else
	note "needrestart is not installed: apt install needrestart"
fi
for p in intel-microcode curl python3 git etckeeper suricata-update; do
	dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || note "package $p is not installed"
done

# logrotate (debug mode does nothing)
run "logrotate -d" logrotate -d -s "$T/logrotate.state" "$S/etc/logrotate.d/firewall"

# sysctl keys exist in this kernel
missing=""
for k in $(sed -n 's/^\([a-z0-9_.]*\) *=.*/\1/p' "$S/etc/sysctl.d/90-router.conf"); do
	[ -e "/proc/sys/$(echo "$k" | tr . /)" ] || missing="$missing $k"
done
if [ -z "$missing" ]; then ok "sysctl keys"; else echo "$missing" >"$T/out"; bad "sysctl keys"; fi

# apt: our file parses and adds the backports origin
if apt-config -c "$S/etc/apt/apt.conf.d/52firewall-unattended" dump >"$T/out" 2>&1 &&
	grep -q 'Debian Backports' "$T/out" && grep -q 'origin=Anthropic' "$T/out" &&
	grep -q 'codename=${distro_codename}-updates' "$T/out"; then
	ok "apt-config (unattended-upgrades: updates, backports, Anthropic)"
else
	bad "apt-config"
fi
# The Anthropic origin must match the Release file apt has for the Claude Code repository.
if ls /var/lib/apt/lists/*claude*Release >/dev/null 2>&1; then
	if grep -h -q '^Origin: Anthropic' /var/lib/apt/lists/*claude*Release; then ok "Claude Code repo origin is Anthropic"; else
		grep -h -E '^(Origin|Label):' /var/lib/apt/lists/*claude*Release >"$T/out"; bad "Claude Code repo origin"; fi
else
	note "no Claude Code apt list found; check the unattended-upgrades origin by hand"
fi

# Suricata: test the config with the include (an empty rule file, so the test does not need downloaded rules;
# suricata-update tests the real rules itself), and show which interface af-packet uses.
: >"$T/empty.rules"
run "suricata -T --include" suricata -T -c /etc/suricata/suricata.yaml --include "$S/etc/suricata/firewall.yaml" -S "$T/empty.rules"
suricata --dump-config -c /etc/suricata/suricata.yaml --include "$S/etc/suricata/firewall.yaml" 2>/dev/null |
	grep -E '^af-packet\.[0-9]+\.interface' >"$T/out"
if grep -q '^af-packet.0.interface = trunk0' "$T/out"; then ok "suricata af-packet: $(tr '\n' ' ' <"$T/out")"; else bad "suricata af-packet override"; fi

# Interface names: wan0 and trunk0 need .link files from tools/nic-macs.sh (after the i350 is installed).
for n in wan0 trunk0; do
	grep -l -s "^Name=$n\$" "$S"/etc/systemd/network/*.link >/dev/null ||
		note "no .link file names $n yet: run tools/nic-macs.sh once the i350 is in (deploy.sh refuses without it)"
done

# Secrets never live in this tree. Not secrets: User= in a systemd unit, and the lines of claude_job.py that read a token file.
grep -r -n -i -E '^[[:space:]]*(user|pass|password|secret|token)[[:space:]]*[=:]' "$S" 2>/dev/null |
	grep -v -E '/etc/systemd/system/[^:]*\.service:[0-9]+:User=[a-z]+$' |
	grep -v -E '/claude_job\.py:[0-9]+:[[:space:]]+token = (path\.read_text\(encoding="utf-8-sig"\)\.strip\(\)|""|read_token\(\))$' |
	cut -d: -f1,2 >"$T/out"
if [ -s "$T/out" ]; then bad "no secrets in the tree"; else ok "no secrets in the tree"; fi

echo
if [ $fail -ne 0 ]; then echo "RESULT: FAIL ($P)"; exit 1; fi
if [ $warn -ne 0 ]; then echo "RESULT: OK with warnings ($P)"; else echo "RESULT: OK ($P)"; fi
exit 0
