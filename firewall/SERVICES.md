# Services

Every service and timer that `deploy.sh` enables: what it does, where its settings are, and a command that
shows it works. All commands run on the box.

A setting is changed in the repository file, not on the box: edit, render, copy, validate, deploy. The paths
below are the paths on the box; in the repository each is under `firewall/common/` (or
`firewall/profiles/<profile>/` where noted).

## After a deploy

Run these from a **new** SSH session, before `sudo fw-deploy-confirm`.

| Check | Pass |
|---|---|
| `systemctl --failed` | Lists nothing |
| `ip -br a` | `wan0` has an address from DHCP, `trunk0` has `.1` of its LAN, `mgmt0` has `10.255.255.1` |
| `sudo nft list ruleset \| head -n 40` | Shows `table inet fw` |
| `dig @127.0.0.1 -p 5335 debian.org +dnssec` | An answer, and `ad` among the flags |
| `dig @127.0.0.1 debian.org +short` | An address (dnsmasq, through unbound) |
| `chronyc tracking` | `Leap status : Normal` |
| `systemctl is-active nftables dnsmasq unbound suricata fw-flowd` | Five times `active` |
| `systemctl list-timers 'fw-*' wan-check.timer` | Each timer has a next run |
| `sudo journalctl -t wan-ip-watch -t fw-health -n 10` | Lines without `error` |

On a LAN client (on the bench: the test laptop on `trunk0`):

| Check | Pass |
|---|---|
| The client's address | From the LAN range, gateway and DNS server `.1` |
| Open a web page | It loads |
| `nslookup example.com 8.8.8.8` | It answers, **and** the question is in `/var/log/dnsmasq.log` on the box: the redirect works |
| `nslookup doubleclick.net` | `0.0.0.0`, and a line in `/var/log/dnsbl.log` on the box (with DNS blocking on, after the first list download) |

## Core

### nftables.service

The firewall and NAT. Policy: drop on input and forward.

| | |
|---|---|
| Settings | `/etc/nftables.conf` (the rules), `/etc/nftables.d/profile.nft` (interfaces, LAN, the forward's addresses; per profile) |
| Log | `/var/log/firewall.log`: `DROP_WAN`, `DROP_LAN`, `DROP_IN`, `DROP_FWD`, `DROP_BLOUT`, `DROP_GEO`, `DROP_DOT`, `ACCEPT GEO` |
| Check | `sudo nft list chain inet fw input`; `sudo tail -n 5 /var/log/firewall.log` |

What the rules allow in:

| From | To the box | Through the box |
|---|---|---|
| Internet (`wan0`) | DHCP replies only. No ping, no SSH | Only the forward in the `prerouting` chain, from one source address |
| LAN (`trunk0`) | SSH, DNS, DHCP, NTP, ping. Syslog from `.3` and `.4` | Everything out, except DNS over TLS (reset) and listed addresses |
| Rescue port (`mgmt0`) | SSH, DHCP, ping | Nothing |

### dnsmasq.service

DHCP for the LAN and the rescue port, LAN names, and the DNS front that clients use. It passes questions to
unbound.

| | |
|---|---|
| Settings | `/etc/dnsmasq.d/firewall.conf`, `10-profile.conf` (range, names; per profile), `20-reservations.conf` (your site file) |
| Log | `/var/log/dnsmasq.log`, every question with the client's address |
| Check | `cat /var/lib/misc/dnsmasq.leases`; `sudo tail -n 5 /var/log/dnsmasq.log` |

### unbound.service

The resolver, on `127.0.0.1:5335`. DNS over TLS to Quad9, DNSSEC validation, the block zones.

| | |
|---|---|
| Settings | `/etc/unbound/unbound.conf.d/firewall.conf`, `firewall-rpz.conf` (one `rpz:` block per list), `/etc/unbound/rpz-allow.zone` (your exceptions), `blocked.zone` |
| Check | `dig @127.0.0.1 -p 5335 debian.org +dnssec` shows the `ad` flag; `sudo unbound-control status` |

### suricata.service

Intrusion detection on `trunk0`. It writes alerts and blocks nothing.

| | |
|---|---|
| Settings | `/etc/suricata/firewall.yaml` (included into Debian's `suricata.yaml`), `disable.conf` (rules switched off), `/etc/systemd/system/suricata.service.d/firewall.conf` |
| Log | `/var/log/suricata/eve.json`, `fast.log` (one line per alert) |
| Check | `systemctl is-active suricata`; `ls -l /var/log/suricata/eve.json` twice, a minute apart: the size grows |

### chrony, rsyslog, dhcpcd, ssh

Debian's own services, with small additions from this tree.

| Service | Addition | Check |
|---|---|---|
| chrony | `/etc/chrony/conf.d/lan.conf`: serve time to the LAN | `chronyc tracking`; `sudo chronyc clients` |
| rsyslog | `/etc/rsyslog.d/`: firewall lines to `/var/log/firewall.log`, block lines to `/var/log/dnsbl.log`, syslog from the switch and the access point to `/var/log/lan-devices.log`. Nothing is sent to another host | `ls -l /var/log/firewall.log /var/log/dnsbl.log` |
| dhcpcd | `/etc/dhcpcd.conf` (per profile): `wan0` only, IPv4 only, no host name sent. `/etc/dhcpcd.exit-hook` calls `wan-event` | `ip -4 addr show wan0` |
| ssh | Key login only, `fwadmin` only; `fwbackup` with a forced command | `sudo sshd -T \| grep -i -E 'allowusers\|passwordauth'` |

## WAN and health

### wan-check.timer

Runs `wan-event CHECK` 2 minutes after boot and then every 5 minutes. It notices a changed public address
that the DHCP hook missed, records WAN down and up, and compares the DDNS record with the address.

| | |
|---|---|
| Settings | `/etc/wan-event/ddns.curl`, `ddns.name`: written only by `tools/store-wan-secrets.ps1`. With no files there is no DDNS update. Never read these files |
| Check | `sudo journalctl -t wan-ip-watch -n 5`; `sudo wan-event TEST` logs the result and queues a test mail |

### fw-health.timer

One syslog line an hour: services, WAN, DNS, load, connection count, disk, temperature, alerts and blocks in
the last hour, list sizes, whether a reboot waits.

| | |
|---|---|
| Check | `sudo journalctl -t fw-health -n 2` |

## Blocking

### fw-blocklists.timer and fw-blocklists-load.service

The timer downloads the IP lists every 6 hours (and 3 minutes after boot) and fills the nftables sets `bl_v4`,
`geo_drop_v4` and `geo_log_v4`. The load service fills the sets from the last good copy each time nftables
starts or reloads. A download that is empty, too small or malformed is not used.

| | |
|---|---|
| Settings | `/etc/default/fw-blocklists`: `BL_ENABLE`, `BL_SOURCES`, `GEO_COUNTRIES`, `GEO_ACTION` (`log` or `drop`), `GEO_URL` |
| Check | `sudo nft list set inet fw bl_v4 \| head -n 5` shows elements; `sudo journalctl -u fw-blocklists -n 10` |

### fw-dnsbl.timer

Downloads the DNS block lists at 04:00 and 16:00 (and 5 minutes after boot) and reloads the unbound zones. A
copy with fewer names than `DNSBL_MIN` is not used. A blocked name is answered as an alias of
`blocked.internal` (address `0.0.0.0`).

| | |
|---|---|
| Settings | `/etc/default/fw-dnsbl`: `DNSBL_ENABLE`, `DNSBL_LISTS`, `DNSBL_MIN`. A new list also needs an `rpz:` block in `firewall-rpz.conf` |
| Check | `ls -l /var/lib/unbound/rpz/`; `sudo tail -n 5 /var/log/dnsbl.log` |
| Allow a name | Add it to `rpz-allow.zone` in the repository and deploy |

### fw-suricata-update.timer

Updates the Suricata rules at about 03:15 (and 15 minutes after boot). A rule set that fails Suricata's own
test is not loaded.

| | |
|---|---|
| Settings | `/etc/default/fw-suricata-update`: `SURICATA_SOURCES` |
| Check | `sudo journalctl -u fw-suricata-update -n 10` |

### fw-suricata-rotate.timer

Rotates Suricata's logs each night at 00:17, after `fw-ingest` has read them.

| | |
|---|---|
| Check | `ls -l /var/log/suricata/` shows dated files after the first night |

### fw-shaper.service

The CAKE shaper on `wan0`. **Off by default**; the unit runs and does nothing until `SHAPER_ENABLE=1`.

| | |
|---|---|
| Settings | `/etc/default/fw-shaper`: `SHAPER_ENABLE`, `EGRESS_KBIT`, `INGRESS_KBIT`, `SHAPER_OPTS`. The file says how to measure the line |
| Check | `tc qdisc show dev wan0` shows `cake` only when the shaper is on |

## Database, report and brief

### fw-flowd.service

Reads connection start and end events from the kernel and writes traffic records for `fw-ingest`. It runs as
the user `fwdb`.

| | |
|---|---|
| Check | `systemctl is-active fw-flowd`; `ls /var/lib/fwdb/spool \| tail -n 3` |

### fw-ingest.timer

Every 10 minutes: loads the firewall log, the DNS log, the block log, Suricata alerts, traffic records, system
events, leases and your known-hosts list into `/var/lib/fwdb/fwlog.duckdb`, and runs the signal queries
(`/usr/local/share/fwdb/detect.sql`, `signatures.tsv`). Above `FWDB_LIMIT` it removes the oldest rows.

| | |
|---|---|
| Settings | `FWDB_LIMIT`, `FWDB_TARGET` (bytes) on the `Environment=` line of `fw-ingest.service`. Defaults: 85 GB and 75 GB |
| Check | `sudo journalctl -u fw-ingest -n 5`; `ls -l /var/lib/fwdb/fwlog.duckdb` |

### fw-asn.timer

Sundays at 03:20: downloads the table that maps addresses to network owners and countries (iptoasn.com), for
the report.

| | |
|---|---|
| Check | `sudo journalctl -u fw-asn -n 5` |

### fw-archive.timer

Tuesdays at 05:10: writes last week's rows to a Parquet archive in `/var/lib/fwdb/archive/` and keeps at most
15 GB of archives. The admin PC's weekly backup collects them.

| | |
|---|---|
| Check | `ls -l /var/lib/fwdb/archive/` after the first Tuesday |

### fw-report.timer

Daily at 05:30: first `fw-updates` (as root) lists what the update jobs did, then `fw-report` (as `fwdb`)
writes `/var/lib/fwdb/reports/YYYY-MM-DD.md`. Reports are kept for 400 days. A sample is in
`site/example/samples/report-sample.md`.

| | |
|---|---|
| Check | `ls /var/lib/fwdb/reports/ \| tail -n 3`; run one now: `sudo systemctl start fw-report.service` |

### fw-brief.service

No timer: it starts when `fw-report.service` ends. As the user `fleet`, it gives today's report to one Claude
session that may run one command (`fwq`, read-only SQL) and has no network tools, and queues the answer as
mail. If the session fails or no token is stored, the report itself is queued, so a missed brief is visible.

| | |
|---|---|
| Settings | `/usr/local/share/fw-analysis/brief.md` (what to write, and what is normal in your house: **edit it** in `site/<name>/files/common/usr/local/share/fw-analysis/brief.md`), `context/analyst.md` (the tables). The token is stored by the person with `agent/store-claude-token.ps1` |
| Check | `sudo journalctl -u fw-brief -n 20`; `sudo ls /var/lib/fw-analysis/runs/` |

### fw-mail.path and fw-mail.timer

`fw-mail.path` starts the sender when a message arrives in `/var/spool/fw-mail`. The timer tries again every
30 minutes for messages that could not be sent. Any program on the box may queue a message; only
`fw-mail.service` (user `fwmail`) reads the login, and the recipient is fixed in it.

| | |
|---|---|
| Settings | `/etc/credstore.encrypted/fw-mail`, written only by `tools/store-mail-secret.ps1` and encrypted with the TPM. Without it the service does not start and messages wait |
| Check | `sudo ls /var/spool/fw-mail` is empty after a send; `sudo journalctl -u fw-mail -n 10`; `sudo wan-event TEST` queues a test message |

## Updates

### unattended-upgrades (Debian's timers)

Installs security fixes, point releases, updates of backports packages that are installed, and Claude Code.
Services that use an old library are restarted. A reboot happens only when needed, at 04:30.

| | |
|---|---|
| Settings | `/etc/apt/apt.conf.d/52firewall-unattended`, `/etc/needrestart/conf.d/50-firewall.conf` |
| Check | `sudo unattended-upgrade --dry-run -d 2>&1 \| tail -n 5`; the "Updates" part of the daily report |

### fw-duckdb-update.timer

Sundays at 05:00: installs a newer DuckDB of the same major version, after a SHA-256 check. A new major
version is reported and not installed.

| | |
|---|---|
| Settings | `/etc/default/fw-duckdb-update` |
| Check | `duckdb --version`; `sudo journalctl -u fw-duckdb-update -n 5` |

### fw-bios-check.timer

Saturdays at 04:00: compares the BIOS version with Lenovo's update catalog. It installs nothing. On another
maker's machine it writes "not a Lenovo machine type" and ends.

| | |
|---|---|
| Check | The "Updates" part of the daily report; `sudo journalctl -u fw-bios-check -n 5` |

## Deploy and backup

### fw-deploy-guard.service

Runs at boot only while a deploy waits for its confirm (`/var/lib/fw-deploy/pending`). When the time is up it
puts the saved files back and reboots.

| | |
|---|---|
| Check | `ls /var/lib/fw-deploy/pending` is missing after a confirm; `sudo journalctl -t fw-deploy -n 10` |

### The backup user (no unit)

`deploy.sh` creates the user `fwbackup`. Its SSH key can run one command, `fw-backup-export`, which writes a
tar of `/etc` (without password hashes, keys and the secrets), the programs, the reports and the package list.
The admin PC pulls it with `tools/pull-fw-backup.ps1`.

| | |
|---|---|
| Settings | `/etc/ssh/sshd_config.d/20-fwbackup.conf`, `/etc/sudoers.d/fw-backup` |
| Check | On the admin PC: `pull-fw-backup.ps1 -Target <address>` writes one file and says that it checked it |

### etckeeper

Git history of `/etc` on the box. `deploy.sh` commits before and after.

| | |
|---|---|
| Check | `sudo git -C /etc log --oneline \| head -n 5` |

## Users on the box

| User | For | Rights |
|---|---|---|
| `fwadmin` | You and your agent | SSH with your key. sudo (see `agent/README.md`) |
| `fwdb` | `fw-flowd`, `fw-ingest`, `fw-report`, `fw-archive` | Owns `/var/lib/fwdb`. May read logs. No login |
| `fwmail` | `fw-mail.service` | May read the mail spool. No login |
| `fwbackup` | The backup pull | One forced command over SSH |
| `fleet` | `fw-brief` | No sudo, no SSH login. May read logs and the database |

## When a service fails

1. `systemctl status <unit>` and `sudo journalctl -u <unit> -n 50`.
2. Test the configuration in the tree: `sudo ./validate.sh <profile>` in `~/firewall-config`.
3. Fix the file in the repository, then render, copy and deploy. Do not repair files on the box by hand: the
   next deploy would undo the repair, and the repository would be wrong.
