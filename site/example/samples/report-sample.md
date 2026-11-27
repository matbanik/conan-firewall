# Sample of the daily report

**Every name, address and number here is invented.** The section titles are the real ones from `fw-report`.
The tables are cut to a few rows, and some have fewer columns than the real ones. The real report is written to `/var/lib/fwdb/reports/YYYY-MM-DD.md` on the
box each morning.

---

# Firewall database report, 24 hours to 2026-01-15 05:30 EST

## Volume

| wan_drops_logged | wan_sources | dns_questions | dns_blocked_pct | ids_alerts | down_mb | up_mb | active_devices |
|---|---|---|---|---|---|---|---|
| 18440 | 3912 | 96211 | 14.2 | 3 | 41310.5 | 3804.2 | 27 |

## Inbound from the internet (there should be none except an approved forward)

| severity | kind | dev | device | target | detail | n | mb | first_seen | last_seen |
|---|---|---|---|---|---|---|---|---|---|
| info | inbound | 192.168.50.5 | adminpc | 203.0.113.45 | tcp/21117 approved forward | 2 | 212.4 | 2026-01-14 09:02 | 2026-01-14 16:40 |

## Known hosts (the owner's list: a label, not a permission)

| ip | name | dir | dev | device | ports | down_mb | up_mb | conns | refused | relation | expected_inbound | note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 203.0.113.45 | Acme office | in | 192.168.50.5 | adminpc | tcp/21117 | 9.1 | 203.3 | 2 | 14 | client | tcp/21115,tcp/21116,tcp/21117,udp/21116 | RustDesk |

## Signals: high and medium

| severity | kind | dev | device | target | detail | n | mb | last_seen |
|---|---|---|---|---|---|---|---|---|
| medium | remote-access | 192.168.50.31 | laptop1 | relay.anydesk.example | AnyDesk relay | 38 | 61.0 | 2026-01-14 17:55 |

## Signals: low (hole punching, tunnels, long connections, encrypted DNS)

| kind | dev | device | target | detail | n | mb | last_seen |
|---|---|---|---|---|---|---|---|
| long-connection | 192.168.50.41 | tv2 | 198.51.100.20 | tcp/443, 9 h | 1 | 14.2 | 2026-01-15 02:10 |
| stun | 192.168.50.60 | phone-a | 198.51.100.77 | udp/3478 | 12 | 0.1 | 2026-01-14 20:31 |

## Signals seen today for the first time in 30 days

| kind | dev | device | target | severity | n |
|---|---|---|---|---|---|
| remote-access | 192.168.50.31 | laptop1 | relay.anydesk.example | medium | 38 |

## Telemetry by app (DNS questions)

| app | devices | questions | blocked | who |
|---|---|---|---|---|
| smart-tv | 2 | 6120 | 6011 | 192.168.50.41 192.168.50.250 |
| windows | 2 | 1904 | 1722 | 192.168.50.5 192.168.50.31 |

## Top talkers

| dev | device | down_mb | up_mb | connections | remotes | biggest_service |
|---|---|---|---|---|---|---|
| 192.168.50.41 | tv2 | 22104.0 | 310.2 | 1841 | 96 | video streaming |
| 192.168.50.5 | adminpc | 9400.8 | 2890.1 | 12033 | 1410 | game download |
| 192.168.50.31 | laptop1 | 3120.4 | 280.7 | 6210 | 802 | web |

## Top services per device

| dev | device | service | down_mb | up_mb | connections |
|---|---|---|---|---|---|
| 192.168.50.41 | tv2 | video streaming | 21870.3 | 290.0 | 620 |
| 192.168.50.5 | adminpc | game download | 8102.6 | 41.9 | 212 |

## Traffic spikes (5 minutes over 4 times the day's normal busy level, with what caused them)

| start | mb | dev | device | service |
|---|---|---|---|---|
| 2026-01-14 19:30 | 2910.2 | 192.168.50.5 | adminpc | game download |

## Devices well above their own 7-day average

(none)

## Countries and networks outside the US by traffic

| country | network | down_mb | up_mb | devices |
|---|---|---|---|---|
| DE | EXAMPLE-HOSTING | 120.4 | 8.1 | 3 |
| NL | EXAMPLE-CDN | 88.0 | 2.2 | 5 |

## DNS: noisiest devices

| dev | device | questions | blocked | names |
|---|---|---|---|---|
| 192.168.50.41 | tv2 | 21044 | 6011 | 212 |
| 192.168.50.5 | adminpc | 18310 | 1722 | 2904 |

## DNS: long or random-looking names (DNS tunneling check)

(none)

## WAN drops: top sources

| src | country | network | n | ports |
|---|---|---|---|---|
| 198.51.100.9 | NL | EXAMPLE-SCANNER | 412 | 380 |
| 198.51.100.140 | US | EXAMPLE-RESEARCH | 208 | 96 |

## WAN drops: top ports

| proto | dport | n | sources |
|---|---|---|---|
| tcp | 22 | 1930 | 611 |
| tcp | 443 | 1204 | 498 |
| udp | 5060 | 880 | 77 |

## IDS alerts by rule

| signature | severity | n | sources | example |
|---|---|---|---|---|
| ET INFO Example Remote Access Tool Activity | 2 | 3 | 1 | 192.168.50.31 -> 198.51.100.61:443 |

## Devices first seen in the last 24 hours

(none)

## Firewall events

| host | tag | message | n | last |
|---|---|---|---|---|
| firewall | fw-health | ok services=N failed=N wan=up dns=ok load=N.N ... | 24 | 2026-01-15 05:00 |
| firewall | fw-backup | export sent | 1 | 2026-01-14 06:30 |

## Database

| flow_min | flow_hour | flow | dns_hour | drops | alert | device | legacy_event | newest_minute |
|---|---|---|---|---|---|---|---|---|
| 1204311 | 310442 | 8120044 | 96110 | 911204 | 212 | 41 | 0 | 2026-01-15 05:20 |

## Database size, archive and backup (fw-ingest keeps the database under 85 GB, fw-archive its folder under 15 GB)

| database_gb | archive_gb | newest_week_archived | config_backup_taken | weekly_archive_taken |
|---|---|---|---|---|
| 12.41 | 2.07 | fwdb-2026-W02.tar | 2026-01-14 06:30 | 2026-01-13 07:00 |

## Updates (fw-updates, run as root just before this report)

```
Reboot required: no
BIOS: X9ZKT12A dated 01/02/2026 (installed by hand only; fw-bios-check compares it with Lenovo's catalog weekly)
  Lenovo catalog, 2026-01-10: current
Changed in the last 24 hours: 3
  upgrade openssl 3.5.1-1 -> 3.5.1-1+deb13u1
  upgrade curl 8.14.1-2 -> 8.14.1-2+deb13u1
  upgrade libxml2 2.12.7+dfsg+really2.9.14-2 -> 2.12.7+dfsg+really2.9.14-2+deb13u1
Waiting upgrades: 0
Held packages: none
unattended-upgrades errors or warnings in 24 hours: 0
Services on old libraries: none
Claude Code: installed 2.1.0, newest in its apt channel 2.1.0
DuckDB CLI: v1.4.2 (fw-duckdb-update, weekly)
Suricata rules file: 2026-01-15 03:15
Failed units: none
```
