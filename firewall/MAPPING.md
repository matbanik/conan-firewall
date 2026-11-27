# From a consumer router to this tree

Where each setting of a home router lives here. Use it in stage 1 to carry your present settings over, and
later to find the file for a change.

The middle column is the example: a consumer router with one LAN, DHCP on the WAN side and one port forward.
Your router's menu names differ. Paths are under `firewall/common/` unless they start with `profiles/`;
"both profiles" means `profiles/bench/` and `profiles/prod/`.

## WAN

| Router setting | Example | Here | Notes |
|---|---|---|---|
| Connection type | Automatic (DHCP) | `profiles/prod/etc/network/interfaces`: `iface wan0 inet dhcp` | PPPoE and static addresses are not set up in the example. Your agent can add them: see `docs/features.md`, "Not in the example" |
| WAN MAC address | The old router's | `WAN_CLONE_MAC` in `site.env`; used in `interfaces` (prod) | Same MAC, same lease, same public address |
| DHCP client ID, host name | MAC-based, no name | `profiles/prod/etc/dhcpcd.conf`: `clientid`, no `hostname` | Debian's default is a DUID; this tree changes it to match a router |
| WAN DNS servers | The provider's, or a public one | `etc/unbound/unbound.conf.d/firewall.conf`, `forward-zone` | DNS over TLS to Quad9. The provider's resolvers are not used |
| MTU | 1500 | Default | MSS is clamped to the path MTU in the `forward` chain |
| IPv6 | Off | `etc/sysctl.d/`, and `nftables.conf` drops IPv6 | Off in the example. Your agent can add it: see `docs/features.md`, "Not in the example" |
| Second WAN, USB modem | None | None | |

## LAN, DHCP and DNS

| Router setting | Example | Here |
|---|---|---|
| LAN address | `192.168.50.1/24` | `LAN_PREFIX` in `site.env` |
| DHCP range, lease time | `.20` to `.254`, one day | `profiles/prod/etc/dnsmasq.d/10-profile.conf`: `dhcp-range` |
| Fixed addresses (reservations) | Five devices | Your site file `site/<name>/files/profiles/prod/etc/dnsmasq.d/20-reservations.conf` |
| DNS server given to clients | The router | dnsmasq gives the firewall's own address |
| Local domain | None | `domain=lan` in `10-profile.conf`: `nas.lan` |
| Names for fixed devices | None | `host-record` lines in `10-profile.conf` (firewall, switch, access point) |
| DNS rebind protection | Off | On: `stop-dns-rebind` in `etc/dnsmasq.d/firewall.conf`, with `rebind-domain-ok` exceptions |
| Present leases | 30 to 40 clients | Optional lease seed at the cutover ([CUTOVER.md](CUTOVER.md)) |
| Time server for clients | None | chrony; DHCP gives the firewall as the NTP server |

## Wi-Fi, guest and IoT networks

| Router setting | Example | Here |
|---|---|---|
| Wi-Fi names, passwords, bands | Two names | **Not here.** The old router, as an access point, keeps them |
| Guest network on its own VLAN | Not used | Not set up: the example has one flat LAN. Remove the guest network before the cutover, accept that its clients join the LAN, or have your agent add a VLAN for it |
| IoT network bridged to the LAN | In use | Unchanged; it is the LAN |

## Port forwarding and NAT

| Router setting | Example | Here |
|---|---|---|
| Port forward | TCP 21115 to 21117 and UDP 21116 to `.5`, from one source address | `etc/nftables.conf`, chain `prerouting`: `ip saddr $RUSTDESK_REMOTE ... dnat to $RUSTDESK_HOST`. The addresses are in `profiles/*/etc/nftables.d/profile.nft` (`REMOTE_SRC`) |
| The same forward for LAN clients that use the public name ("NAT loopback") | TCP 21117 | The hairpin rule in `prerouting`, and its masquerade rule in `postrouting` |
| NAT | On | `oifname $WAN_IF masquerade` in `postrouting` |
| UPnP, NAT-PMP | Off | None. No daemon is installed. A device that asks is reported (signal `port-mapping`) |
| ALGs (SIP, H.323, RTSP) | On | None. No conntrack helpers |
| DMZ host | Off | None |
| Hardware acceleration | On | None. Every packet passes nftables, so every rule and counter is true |

## Firewall and filters

| Router setting | Example | Here |
|---|---|---|
| Firewall on, drop from WAN | On | Chain `in_wan`: drop, logged as `DROP_WAN` with a rate limit |
| Answer ping from WAN | Off | Dropped in `in_wan` |
| DoS protection | On | `tcp_syncookies` in `etc/sysctl.d/`, and log rate limits |
| Log dropped packets | On | `/var/log/firewall.log`, then the database |
| LAN to WAN filter (address, port) | Off | The `forward` chain. IP block lists in nftables sets: `etc/default/fw-blocklists` |
| Country block | None | `GEO_COUNTRIES` and `GEO_ACTION` in `etc/default/fw-blocklists`. Empty by default |
| URL or keyword filter | Off | None. Use the DNS block lists |
| DNS filter, parental controls | Off | unbound block zones for the whole LAN: `etc/default/fw-dnsbl`. No per-device rules, no schedules |
| Vendor "protection" service | Off | Suricata on `trunk0`: alerts only, rule sources in `etc/default/fw-suricata-update` |
| QoS | Off | CAKE: `etc/default/fw-shaper`. Off until you measure the line |

## System

| Router setting | Example | Here |
|---|---|---|
| Remote syslog server | A PC on the LAN | None. Logs stay on the box and go into the database |
| Syslog **from** other devices | None | rsyslog accepts UDP 514 from `.3` and `.4`, the example's switch and access point (chain `in_lan`, `etc/rsyslog.d/20-lan-devices.conf`) |
| NTP servers | A public pool | chrony with Debian's pool; it serves the LAN |
| Time zone | US Eastern | `TIME_ZONE` in `site.env`, set at install |
| Scheduled reboot | Off | Only when an update needs one, at 04:30 (`etc/apt/apt.conf.d/52firewall-unattended`) |
| SSH | A high port, LAN only, password | Port 22, LAN and `mgmt0` only, key only, user `fwadmin` only |
| Web pages | HTTPS on the LAN | None |
| Remote management from the WAN | Off | None, and no rule for it |
| The router maker's DDNS | On | `wan-event` with your provider's update URL ([SECRETS.md](SECRETS.md)). The maker's DDNS stops when the old router becomes an access point |
| "WAN address changed" mail | A script | `wan-event`, by mail (`fw-mail`) |
| Firmware update | By hand | unattended-upgrades and the `fw-*-update` timers ([SERVICES.md](SERVICES.md), "Updates") |
| Settings backup | A file, by hand | The repository is the configuration. Plus etckeeper on the box and the pull backup |
| USB file sharing | On | None. Leave it on the access point or switch it off |

## What has no counterpart

The example has nothing for these. Decide about each one before the cutover: have your agent build it
(`docs/features.md`, "Not in the example"), move it to another device, or accept that it stops working.

- Guest network isolation and VLANs.
- Per-device parental controls, schedules and time limits.
- UPnP port mappings that games or cameras made by themselves.
- A VPN server or client on the router.
- The router maker's phone app and cloud account.
- IPv6.
