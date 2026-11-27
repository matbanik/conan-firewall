# Features

Everything the firewall does, by area. For why each choice was made, read
[design-decisions.md](design-decisions.md). For how to check that each service works, read
[../firewall/SERVICES.md](../firewall/SERVICES.md).

## Routing and firewall

- **nftables** firewall, default drop on input and forward, NAT for one LAN.
- **Port forwards only with a source address.** The example forwards a RustDesk server to one LAN host from one
  outside address, with a hairpin rule for LAN clients that use the public name.
- **No UPnP, no SIP or H.323 helpers, no web interface, IPv6 off.**
- **IP block lists** in nftables sets, updated every 6 hours: Spamhaus DROP, Feodo Tracker, Emerging Threats
  compromised hosts, DShield. Traffic from listed addresses is dropped before connection tracking. A LAN device
  that connects to a listed address is dropped and logged. A bad download never replaces the last good list.
- **Country lists** (ipdeny), empty by default, with a log-only mode to try before you block.
- **CAKE traffic shaper** against bufferbloat, off until you measure your line.
- **Named network ports by MAC address** (`wan0`, `trunk0`, `mgmt0`, two spares), so a BIOS or kernel change
  cannot swap WAN and LAN.
- **Rescue port** `mgmt0` at 10.255.255.1 with its own DHCP address for one laptop. It always accepts SSH.

## DNS and DHCP

- **dnsmasq** for DHCP and LAN names: reservations, a query log, protection against DNS rebinding.
- **unbound** as the resolver: DNS over TLS to Quad9, DNSSEC validation, answers kept through short upstream
  outages.
- **DNS blocking** with response policy zones: Hagezi Pro (ads, trackers) and Hagezi Threat Intelligence Feeds
  (malware, phishing), updated twice a day. A blocked name gets a local answer and a log line. One file holds
  your exceptions.
- **DNS that cannot be skipped by accident:** port 53 to other servers is redirected to the firewall, DNS over
  TLS from the LAN is reset so that devices fall back, and Firefox is told not to use DNS over HTTPS.
- **NTP for the LAN** from chrony, announced by DHCP.

## Detection and logs

- **Suricata 8** intrusion detection on the LAN side (detection only, it blocks nothing). Rules: Emerging
  Threats Open, Feodo Tracker, URLhaus, updated daily.
- **Traffic per device** from the kernel's connection table: which device talked to which address, name,
  network owner and country, how much, and for how long.
- **A log database on the box** (DuckDB): firewall drops, DNS questions, traffic, IDS alerts, system events, and
  syslog from your switch and access point. Loaded every 10 minutes, weekly archives in Parquet, a size limit
  that removes the oldest rows first.
- **Signals**: queries that mark inbound connections, remote-access tools, tunnels, VPNs, hole punching, relay
  apps, encrypted DNS that skips the filter, port-mapping requests, beacons, new devices, LAN scans, large
  uploads and telemetry.
- **A daily report** at 05:30: the same SQL every day, as a Markdown file on the box.
  [Sample](../site/example/samples/report-sample.md).
- **A daily brief by email**, written by an AI agent that runs on the box as a user with no sudo, no network
  tools and one command (read-only SQL). [Sample](../site/example/samples/brief-sample.txt).
- **WAN watch**: a change of the public address, WAN down and up, and a wrong DDNS record are logged and
  mailed; the DDNS record is updated.
- **Your own names for outside addresses.** A list on the box labels the hosts you know (an office, a relative's
  house, a rented server) in the report and the brief. It is a label only and never opens a port.
- **An hourly health line** in syslog.

## Operation and safety

- **Unattended install** from a USB stick: three questions (password twice, confirm the disk). A model check
  stops the stick from erasing any other computer that boots from it.
- **Deploy with automatic rollback.** `deploy.sh` checks every file with the tool that will read it, saves what
  it replaces, installs, and reboots. If you do not confirm within 15 minutes, the box puts the old files back
  and reboots again.
- **Rule changes with a 120-second undo** (`fw-apply`, `fw-confirm`).
- **Two profiles**: `bench` (test the box behind your present router) and `prod` (the real network).
- **Automatic updates**: Debian security fixes and point releases, Suricata, Claude Code, and DuckDB within the
  same major version. A reboot happens only when needed, at 04:30. The daily report lists what changed, what
  waits and whether each update job ran. A weekly job checks for a newer BIOS on Lenovo machines and installs
  nothing.
- **History of `/etc`** in git on the box (etckeeper), with a commit before and after each deploy.
- **Backups pulled by your PC.** The box holds no credential for your PC. The backup key can run one export
  command and nothing else. Daily copies, plus a weekly archive that stores one full copy a year and then only
  what changed.
- **Secrets never enter the repository.** Scripts that you run yourself prompt for the DDNS token and the mail
  password and store them on the box. The mail password is encrypted with the box's TPM chip.
- **Optional agent fleet unit.** The image installs `fleet-member.service` for people who run jobs on several
  machines from one hub. It stays inactive here and can be removed; see
  [../agent/README.md](../agent/README.md).
- **Email with one fixed recipient.** Programs on the box can queue a message; only one service can send, and
  only to the address in the encrypted credential.

## For the agent

- [../AGENTS.md](../AGENTS.md): the rules and the reading order.
- [../SETUP-QUESTIONS.md](../SETUP-QUESTIONS.md): every question, what it sets, and a safe default when you do
  not know the answer.
- [../firewall/SERVICES.md](../firewall/SERVICES.md): each service with the command that shows it works.
- `tools/render-site.py`: fills your values into a copy of the tree. `tools/scan-public.py`: stops a commit
  that holds a real address, MAC, email or key.

## Limits

- One flat LAN. No VLANs, no guest network, no VPN server, no IPv6.
- Tested on one machine and one internet provider. Expect to read and change files.
- Suricata detects and does not block.
- The daily brief needs a Claude subscription: it signs in with a token from `claude setup-token`, not with an
  API key. Everything else works without it.
- No warranty. A firewall you do not understand is worse than the router you have. Read
  [design-decisions.md](design-decisions.md) before the cutover.
