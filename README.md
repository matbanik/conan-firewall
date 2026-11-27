# conan-firewall

A home router and firewall on Debian 13, built to be set up and run with an AI agent.

This repository holds the complete, working configuration of one house: the installer build, the firewall
configuration, the log database, the daily report, and the cutover plan that replaced a consumer router. Every
private value was replaced by an example value. You answer a questionnaire, the answers go into one small file,
and the tools fill them in.

**It does not ship a built image, a Debian ISO, a binary or a key.** You (or your agent) build the installer
image from the stock Debian ISO. Every download is checked against a pinned hash or signature before it is used.

## Start here

Open the repository with an AI coding agent and say:

> Read AGENTS.md and guide me through the setup.

The agent interviews you with [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md), writes your answers to
`site/<name>/site.env`, and then follows [SETUP-GUIDE.md](SETUP-GUIDE.md) with you. Without an agent, read
those two files yourself; every step is a command you can type.

## The five stages

| Stage | What happens | Document |
|---|---|---|
| 1. Configure | The questionnaire. Your answers become `site/<name>/` | [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md) |
| 2. Build and install | Build the installer image, write a USB stick, install Debian with three questions on the screen | [installer/BUILD.md](installer/BUILD.md), [installer/INSTALL.md](installer/INSTALL.md) |
| 3. Connect the agent | SSH with a key, decide what the agent may do on the box | [agent/README.md](agent/README.md) |
| 4. Start the services | Check and deploy the test profile, then check each service | [firewall/README.md](firewall/README.md), [firewall/SERVICES.md](firewall/SERVICES.md) |
| 5. Cut over | Plan the swap, do it in about 30 minutes, keep a rollback | [firewall/CUTOVER.md](firewall/CUTOVER.md) |

Until stage 5 the box is only a computer on your LAN. Your present router keeps working, and nothing in
stages 1 to 4 changes your network.

## Features

### Routing and firewall

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

### DNS and DHCP

- **dnsmasq** for DHCP and LAN names: reservations, a query log, protection against DNS rebinding.
- **unbound** as the resolver: DNS over TLS to Quad9, DNSSEC validation, answers kept through short upstream
  outages.
- **DNS blocking** with response policy zones: Hagezi Pro (ads, trackers) and Hagezi Threat Intelligence Feeds
  (malware, phishing), updated twice a day. A blocked name gets a local answer and a log line. One file holds
  your exceptions.
- **DNS that cannot be skipped by accident:** port 53 to other servers is redirected to the firewall, DNS over
  TLS from the LAN is reset so that devices fall back, and Firefox is told not to use DNS over HTTPS.
- **NTP for the LAN** from chrony, announced by DHCP.

### Detection and logs

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
  [Sample](site/example/samples/report-sample.md).
- **A daily brief by email**, written by an AI agent that runs on the box as a user with no sudo, no network
  tools and one command (read-only SQL). [Sample](site/example/samples/brief-sample.txt).
- **WAN watch**: a change of the public address, WAN down and up, and a wrong DDNS record are logged and
  mailed; the DDNS record is updated.
- **Your own names for outside addresses.** A list on the box labels the hosts you know (an office, a relative's
  house, a rented server) in the report and the brief. It is a label only and never opens a port.
- **An hourly health line** in syslog.

### Operation and safety

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
  machines from one hub. It stays inactive here and can be removed; see [agent/README.md](agent/README.md).
- **Email with one fixed recipient.** Programs on the box can queue a message; only one service can send, and
  only to the address in the encrypted credential.

### For the agent

- [AGENTS.md](AGENTS.md): the rules and the reading order.
- [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md): every question, what it sets, and a safe default when you do not
  know the answer.
- [firewall/SERVICES.md](firewall/SERVICES.md): each service with the command that shows it works.
- `tools/render-site.py`: fills your values into a copy of the tree. `tools/scan-public.py`: stops a commit
  that holds a real address, MAC, email or key.

## What you need

| Need | Detail |
|---|---|
| The firewall machine | A small x86-64 PC with at least three Ethernet ports: internet, LAN, and the rescue port. Tested on one machine only: a Lenovo ThinkCentre M920q with a four-port Intel i350 card. Other hardware needs the changes in [installer/BUILD.md](installer/BUILD.md), "Other hardware" |
| Disk and memory | The log database may grow to 100 GB (the limit is a setting). 8 GB of memory or more for Suricata and the report |
| A TPM 2.0 chip | Only for the stored mail password |
| An admin PC | It builds the image (Linux, or WSL on Windows), holds the SSH key, and pulls the backups. The helper scripts in `firewall/tools/*.ps1` are written for Windows PowerShell and are untested elsewhere |
| A switch and an access point | The firewall has no Wi-Fi. Your old router can become the access point |
| An internet line that gives its address by DHCP | PPPoE and static addresses are not in this tree |
| Time | An evening for stages 1 to 4, and 30 minutes without internet for the cutover |

## What is a setting and what is an edit

`site/<name>/site.env` holds the values that differ in every house: the LAN prefix, MAC addresses, host names,
the time zone, the install disk. `site/<name>/files/` holds whole files that are yours alone, such as the DHCP
reservations. `python3 tools/render-site.py site/<name>` writes a filled-in copy to `out/<name>/`, and that
copy is what you build and deploy. `site/<name>/` and `out/` are ignored by git, so your values stay on your
PC.

Everything else is a file that you edit: the rule set, the block list sources, the report queries, the text
that tells the brief what is normal in your house. This is a real configuration, not a product with a settings
page. The comments in the files still name the original setup (a fiber line, a consumer router as the access
point, a RustDesk server). Read them as the worked example they are. [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md)
names the file for each choice.

## Repository layout

| Path | What |
|---|---|
| `AGENTS.md`, `CLAUDE.md` | Entry point for an AI agent |
| `SETUP-QUESTIONS.md`, `SETUP-GUIDE.md` | The questionnaire and the step-by-step guide |
| `installer/` | Scripts that build and verify the installer image, and the install walkthrough |
| `agent/` | How an agent connects to the box, and what it may do there |
| `firewall/` | The configuration, laid out as on the box, with `validate.sh` and `deploy.sh` |
| `firewall/tools/` | Scripts for the admin PC: backups, secrets, the cutover |
| `site/example/` | An example site and synthetic sample outputs |
| `tools/` | `render-site.py`, `scan-public.py`, the pre-commit hook |
| `docs/` | Why each design choice was made, and the research behind the feature list |

## Limits

- One flat LAN. No VLANs, no guest network, no VPN server, no IPv6.
- Tested on one machine and one internet provider. Expect to read and change files.
- Suricata detects and does not block.
- The daily brief needs a Claude subscription: it signs in with a token from `claude setup-token`, not with an
  API key. Everything else works without it.
- No warranty. A firewall you do not understand is worse than the router you have. Read
  [docs/design-decisions.md](docs/design-decisions.md) before the cutover.

## Security

See [SECURITY.md](SECURITY.md). Never commit your `site/<name>/` folder, a key or a token. Install the
pre-commit hook: `sh tools/hooks/install.sh`.

## License

MIT. See [LICENSE](LICENSE). The block lists, rule sets and programs that the box downloads have their own
licenses and terms.
