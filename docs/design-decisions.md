# Design decisions

Why the firewall is built the way it is. Each entry says what was chosen, why, and where to change it. None
of this is the only right answer; it is one house's answer, kept as a worked example.

## Scope

**Plain Debian, not a firewall product.** pfSense and OPNsense are good products, and they are the right
choice when you want a web interface, VLANs and a VPN server from a menu. This repository takes the other
road for three reasons.
- An agent works with files and commands. Every part here has a plain config file and its own checker
  (`nft -c`, `unbound-checkconf`, `dnsmasq --test`, `suricata -T`), so a change is tested before it is
  installed. A product keeps its settings in one file that its web interface owns.
- Stock Debian means the fixes come from the Debian security team through `unattended-upgrades`, and the
  programs are the ones that run on Debian servers everywhere. What you learn here is useful on any Linux
  machine.
- Only what the house needs is installed. There is no web server and no settings page to protect.

The cost: nothing is a click. Each feature you add is a file that you or your agent write and test.

**One flat LAN.** No VLANs, no guest or IoT network. A flat network is easy to reason about and needs no
managed-switch setup. The cost: a compromised device can reach every other device. If you need separation,
this repository is a start and not a finish.

**IPv4 only.** IPv6 is switched off in sysctl and dropped in nftables. Two address families mean two rule
sets to get right, and a rule set that covers only one of them is worse than none.

**DHCP on the WAN side only.** No PPPoE and no static WAN address.

**No web interface.** The repository is the configuration, a deploy is the only way to change the box, and
every change is in git twice (here, and `/etc` on the box).

## Hardware

**A used small-form-factor PC with an Intel i350 card.** The example is a Lenovo ThinkCentre M920q with a
four-port i350-T4 on a riser. Any x86-64 machine with a TPM 2.0 chip and three or more Ethernet ports does the
same work; `installer/BUILD.md`, "Other hardware", lists what to change.

**1 Gbit/s ports.** The example line is slower than 1 Gbit/s. With a faster line the card is the limit.

**The onboard port is the rescue port.** `mgmt0` has its own tiny network (`10.255.255.0/30`) with DHCP for
one laptop and nothing routed. It works when every other part of the configuration is wrong.

**Port names by MAC address.** systemd `.link` files name the ports `wan0`, `trunk0`, `mgmt0`. Kernel names
change with a BIOS setting or a card in another slot; a rule set written for the wrong port is an open door.

**Power saving at Debian's defaults.** The CPU's sleep states are not tuned. Measured latency was fine and the
box is idle most of the time.

## Routing and firewall

**nftables, default drop.** One table, chains named for the direction (`in_wan`, `in_lan`, `in_mgmt`,
`forward`). Nothing from the internet reaches the box itself except DHCP replies.

**No flowtable, no hardware offload.** Every packet passes the rule set. It costs CPU that this box has to
spare, and it means every counter, log line and Suricata alert is complete. Many consumer routers bypass
their own firewall for established connections; rules added there do not see that traffic.

**The WAN MAC address is cloned** from the old router (`WAN_CLONE_MAC`), with a MAC-based DHCP client ID and
no host name. The provider sees the same client, so the lease and the public address stay.

**No ping from the internet, and no log line for the commonest scan ports** (`wan_noise_tcp`). The internet
scans every address all day. Logging each try hides what matters. Other refused packets are logged with a
rate limit.

**No UPnP, no NAT-PMP, no ALGs.** A device on the LAN must not open ports by itself. A request to do so is
recorded as a signal. If a phone adapter has one-way audio after the cutover, look here first: it needs a
setting on the adapter (a keep-alive, or STUN), not a helper on the firewall.

**A port forward always has a source address.** The example has one forward (a self-hosted remote-desktop
server) from one remote site. A forward open to the whole internet is found by scanners within hours.

**A hairpin rule** lets LAN clients use the public name for the forwarded service.

## DNS

**Clients ask dnsmasq, dnsmasq asks unbound.** dnsmasq knows the LAN names and logs each question with the
client's address. unbound validates DNSSEC and applies the block zones.

**DNS over TLS to Quad9.** The provider cannot read or change the questions. Quad9 can read them; choose
another upstream in unbound's `forward-zone` if you trust another one more.

**Plain DNS to any other server is redirected to the firewall.** A device with a fixed DNS server (many TVs
and speakers) gets the same filter as the rest.

**DNS over TLS from LAN devices is refused** (TCP 853, reset), and the "use-application-dns.net" name is
answered "does not exist", which tells Firefox not to switch to DNS over HTTPS by itself. DNS over HTTPS that
an app sets up itself cannot be stopped this way; it is recorded as a signal where the server is known.

**unbound answers from its cache when the upstream is down** (`serve-expired`, up to a day). A short outage
of the upstream does not stop the house.

**Block lists: Hagezi Pro and Threat Intelligence Feeds (medium).** Chosen for few false alarms. A new copy
that is far too small is refused, and the last good copy stays. Exceptions go into `rpz-allow.zone`.

**Rebind protection is on.** An outside name must not resolve to a LAN address. Media servers that depend on
such names get an exception (`rebind-domain-ok`).

## IP block lists and countries

**Four small lists** (Spamhaus DROP, Feodo Tracker, Emerging Threats compromised, DShield top) in one nftables
set. From the WAN they are dropped without a log line; a LAN device that tries to reach one is logged
(`DROP_BLOUT`), because that is worth knowing.

**Last good copy.** A failed or malformed download changes nothing. The sets are filled from disk when
nftables starts, so a reboot without internet still has them.

**Country lists are empty by default.** Blocking countries breaks ordinary sites in ways that are hard to
trace. If you use them, start with `GEO_ACTION=log` and read the report for a week.

**The forward's remote address is exempt** from both, so that a list mistake cannot cut your own remote
access. `validate.sh` tests this.

## Detection

**Suricata detects and does not block** (IDS, not IPS). An inline IPS that fails or mis-fires takes the
house offline; an IDS that fails only stops reporting. It listens on `trunk0`, so it sees LAN addresses and
not the NAT address.

**Rule sources:** Emerging Threats Open, and abuse.ch Feodo Tracker and URLhaus. A rule set that fails
Suricata's own test is not loaded.

**Suricata 8 from Debian backports**, because the version in the stable release had open security issues
when this was built.

## Records, report and brief

**Traffic records come from the kernel's connection table** (`fw-flowd`), not from packet capture: bytes and
packets per connection, with the address before NAT.

**DuckDB, one file, on the box.** No server process, plain SQL, and it handles months of a house's traffic.
The database is capped (85 GB by default); the oldest detail goes first, and weekly Parquet archives are
pulled off the box before that.

**Signals are plain SQL** in `detect.sql`, with a table of known remote-access and tunnel services in
`signatures.tsv`. You can read every rule that raises a signal.

**The daily report is the same queries every day.** No judgement in it. The brief is separate: one model
session that reads the report, may ask the database read-only, and writes a short mail. If the session fails,
the report is mailed instead, so silence never means "all fine".

**The brief runs as a user without sudo, in a sandbox, with no network tools.** Report contents come from
the network and are treated as data written by strangers.

**Mail has one fixed recipient.** Any program on the box may queue a message; only one service can read the
login, and that login is encrypted with the TPM. A compromised program cannot send mail elsewhere.

## Operation

**Every deploy undoes itself.** A wrong rule on a router locks you out of the thing you need to fix it. So a
deploy saves the old files, arms a guard, and needs a confirm from a new session. The guard is installed
before the profile and is never part of a revert.

**A bench profile.** The same files run first behind the present router, for one test client. The switch to
the real network is a profile change, tested before.

**Updates are automatic.** Security fixes, point releases, backports that are installed, and Claude Code,
through unattended-upgrades. A reboot only when a kernel or microcode update needs it, at 04:30. A router that
waits for a person to update it stays unpatched.

**DuckDB updates within the same major version only**, with a checksum. A new major version may change the
file format, so it is reported and left to you. **BIOS updates are reported and never installed.**

**DDNS update errors are logged and mailed, and the record is compared with the real address.** Supported
providers are those with a simple update URL (deSEC, DuckDNS, dynv6). The update URL is a secret and lives
only on the box.

**Mail through a mail provider's app password,** from an account made for the firewall. No mail server runs
on the box.

**The shaper is off until you measure.** CAKE helps when the line is the bottleneck and the delay grows under
load. On a line that does not show that, it only costs throughput.

**Backup is pulled, not pushed.** The admin PC fetches it with a key that can run one command. The firewall
holds no credential for any other machine.

**The image is built from checked downloads,** not shipped. `installer/` pins the Debian ISO and every other
input by checksum or signing key, so you can see what goes into your router.
