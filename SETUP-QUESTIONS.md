# Setup questions

The interview that comes before any build or deploy. An AI agent asks these questions and writes down the
answers. A person without an agent answers them on paper and then follows [SETUP-GUIDE.md](SETUP-GUIDE.md).

## How to run the interview (for the agent)

1. Ask one block at a time, in order. Give the default with each question. Do not ask what you can read from a
   command; run the command and show the result.
2. Three kinds of answer:
   - **A value**: it goes into `site/<name>/site.env` under the key shown.
   - **An edit**: the default in the tree is used unless the person wants something else. Then you change the
     file shown, after the interview, and say what you changed.
   - **A stop**: this tree does not support the answer. Say so. Do not go on as if it did.
3. When the person does not know, take the **fail-safe default**. Every default leaves a feature off or a port
   closed. Nothing is opened by default.
4. Start by copying the example: `cp -r site/example site/<name>` (`<name>` is one short word for the house,
   for example `home`). `site/<name>/` is ignored by git.
5. Write answers that are not `site.env` values to `site/<name>/ANSWERS.md`, one line per question id. Never
   write a password, a token or a key there.
6. At the end, read the summary back (the last section of this file) and wait for a yes.

Block I asks about the person's own access. Blocks F, G and H name secrets; the person stores them later with
a script. You never see them.

---

## Block A. The machine

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| A1 | Which machine becomes the firewall (maker and model)? | `HW_MODEL_FILE`, `HW_MODEL_REGEX`: the installer only runs on a machine whose model text matches | The example values, for a Lenovo ThinkCentre M920q, M920x or M720q. For another machine follow "Other hardware" in `installer/BUILD.md`. Never use a pattern that matches every machine |
| A2 | How many wired network ports does it have, and what card are they on? | Whether this tree fits | **Stop** with fewer than three ports: one for the internet, one for the LAN, one rescue port. Tested with one onboard port and a four-port Intel i350 card (driver `igb`). `tools/nic-macs.sh` finds only `igb` ports; for other cards you read the MAC addresses by hand (guide, stage 4) |
| A3 | Which disk will be erased for the install? | `INSTALL_DISK` | `/dev/nvme0n1` for NVMe, usually `/dev/sda` for SATA. Ask the person to confirm that nothing on that disk is needed |
| A4 | What is the time zone? | `TIME_ZONE` (a name from `/usr/share/zoneinfo`) | Ask. Reports and the database use local time |
| A5 | What name and address should the box use for its own history of `/etc`? | `ETC_GIT_NAME`, `ETC_GIT_EMAIL`, one word each | The example values. They stay on the box. Do not use a personal email address |
| A6 | Does the machine have a TPM 2.0 chip that is switched on? | Whether email can be set up (block G) | Unknown: go on, and check after the install with `systemd-creds has-tpm2`. Without a TPM there is no email |
| A7 | What is the admin PC: Windows, Linux or a Mac? | Which helper scripts work | The `.ps1` scripts in `firewall/tools/` and `agent/` are for Windows PowerShell. On Linux or a Mac, read each script and run its SSH commands by hand |

## Block B. The internet line

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| B1 | How does your present router get its internet address: automatically (DHCP), with a user name and password (PPPoE), or a fixed address? | Whether this tree fits | DHCP is the only method in this tree. **Stop** for PPPoE or a static address: `profiles/prod/etc/network/interfaces` and `dhcpcd.conf` would need new content that nobody has tested here |
| B2 | Is the device in front of your router a plain modem or fiber terminal, or is it a router itself? | The cutover plan | If it is a router, the firewall would sit behind a second NAT. That works, but put that device in bridge mode if you can. Note the answer for block K |
| B3 | Should the firewall use the WAN MAC address of your present router? Many providers tie the address lease to the MAC, so a clone keeps your public address. | `WAN_CLONE_MAC` (lower case), `WAN_CLONE_MAC_UC` (upper case) | Yes: read the WAN MAC from the old router's status page. For no clone, put the firewall's own `wan0` MAC in both keys once you know it (stage 4) |
| B4 | Do you need IPv6? | Whether this tree fits | IPv6 is off, and the rules drop it. **Stop** if the person needs it |
| B5 | Do you need a name that follows your public address (dynamic DNS)? It is only needed when something outside connects in (block F). | `DDNS_NAME`; the provider's token is stored in stage 4 with `firewall/tools/store-wan-secrets.ps1` | No. Leave `DDNS_NAME` at the example value. With no token stored, the box makes no DDNS update |

## Block C. The LAN

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| C1 | What are the first three numbers of your LAN addresses today (for example 192.168.1)? Keep them or change them? | `LAN_PREFIX`. The firewall takes `.1`. The network is always a /24 | Keep today's prefix, so devices with fixed addresses keep working. **Not** `192.168.12` (the bench profile's test LAN) and not `10.255.255` (the rescue port). If today's LAN is `192.168.12`, replace `192.168.12` with another free private prefix in every file under `firewall/profiles/bench/` before the first render. If you change the prefix, the bench profile must still accept SSH from today's LAN: put today's network into `wan_ssh_allow` in `firewall/profiles/bench/etc/nftables.d/profile.nft` |
| C2 | Which devices need a fixed address (printers, TVs, servers, cameras)? | The site file `site/<name>/files/profiles/prod/etc/dnsmasq.d/20-reservations.conf`: one `dhcp-host=MAC,address,name` line each | Take the list from the old router's DHCP page. An empty file with only comments is valid |
| C3 | Is the automatic address range `.20` to `.254` with 24-hour leases right? | Edit `firewall/profiles/prod/etc/dnsmasq.d/10-profile.conf` | Keep it. Reservations may sit inside or outside the range |
| C4 | Do you have a managed switch and an access point with fixed addresses? | The tree gives the names `switch` to `.3` and `ap` to `.4`, and accepts syslog (UDP 514) from those two addresses only. Edit `10-profile.conf`, the `in_lan` chain in `common/etc/nftables.conf`, and `common/etc/rsyslog.d/20-lan-devices.conf` together if yours differ | Give your switch `.3` and your access point `.4`. With no such devices, leave the files as they are: nothing listens there and nothing breaks |
| C5 | What is the admin PC's host name and LAN address? | `ADMIN_HOST`, `ADMIN_HOST_LC` (the same name in lower case). The example gives it `.5` | Give the admin PC a reservation at `.5` in C2. The name appears in comments and in the brief text. The address matters: the example forward (F2) goes to `.5`, `validate.sh` tests the backup login from `.5`, and `pull-fw-backup.ps1 -Setup` lets the backup key in from `.5` only (its `-From` option changes that) |
| C6 | Do you need separate networks (guest Wi-Fi, IoT, VLANs)? | Whether this tree fits | **Stop** if the person needs them now. This tree has one flat LAN. Guest isolation inside an access point still works, because the access point does it |
| C7 | Two more names with no function: an old log server, and the test laptop for the bench profile. | `LOG_HOST`, `BENCH_CLIENT`. Used in comments only | Keep the example values |

## Block D. DNS and blocking

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| D1 | Which DNS provider should the firewall ask? | Edit `firewall/common/etc/unbound/unbound.conf.d/firewall.conf` (the `forward-zone` block) | Quad9 over TLS, as in the tree. Quad9 also refuses known malware names |
| D2 | Block ads, trackers and malware names for the whole house? | `DNSBL_ENABLE` and `DNSBL_LISTS` in `firewall/common/etc/default/fw-dnsbl`. Each list also needs an `rpz:` block in `unbound.conf.d/firewall-rpz.conf` | On, with Hagezi Pro and Hagezi TIF medium. Expect one or two sites to break in the first week. The fix is one line in `common/etc/unbound/rpz-allow.zone`. To start without blocking, set `DNSBL_ENABLE=0` |
| D3 | Which names must never be blocked (work VPN, bank, a smart-home service)? | `firewall/common/etc/unbound/rpz-allow.zone` | None. Add them when something breaks; `/var/log/dnsbl.log` shows what was blocked |
| D4 | Block traffic to and from known bad addresses? | `BL_ENABLE` and `BL_SOURCES` in `firewall/common/etc/default/fw-blocklists` | On, with the four lists in the tree. These lists are small and careful; false blocks are rare |
| D5 | Block or log whole countries? | `GEO_COUNTRIES`, `GEO_ACTION` in the same file | Empty: no country is blocked. To try it, set `GEO_ACTION=log` for a week and read the report before you change it to `drop` |
| D6 | Devices that set their own DNS server are redirected to the firewall, and DNS over TLS from the LAN is reset. Is that acceptable? | The `prerouting` and `forward` chains in `firewall/common/etc/nftables.conf` | Keep both. A device that needs its own DNS (some work laptops) gets an exception rule by address; ask the person which |
| D7 | Do you run Plex or a similar service that uses public names for private addresses? | `rebind-domain-ok` lines in `firewall/common/etc/dnsmasq.d/firewall.conf` | The tree allows `plex.direct`. Leave it; it does no harm without Plex |

## Block E. Detection, logs and speed

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| E1 | Run the intrusion detection system (Suricata)? It reads LAN traffic, writes alerts and blocks nothing. It is the largest user of memory on the box. | The unit list `UNITS` in `firewall/deploy.sh`; rule sources in `common/etc/default/fw-suricata-update` | On |
| E2 | How much disk may the log database use? | `FWDB_LIMIT` and `FWDB_TARGET` (bytes): add them to the `Environment=` line of `common/etc/systemd/system/fw-ingest.service`. Above the limit the oldest rows go until the target is reached. The weekly archives take up to 15 GB more | 85 GB limit, 75 GB target: under 100 GB in total. On a disk smaller than 250 GB, set 20 GB and 15 GB |
| E3 | What is the speed of the line (down and up), and do video calls stutter when someone uploads? | `SHAPER_ENABLE`, `EGRESS_KBIT`, `INGRESS_KBIT` in `common/etc/default/fw-shaper` | Off. Measure after the cutover. The file explains the test and the numbers |
| E4 | Which WAN ports get so much scanner noise that you do not want a log line for each drop? | The set `wan_noise_tcp` in `common/etc/nftables.conf`. Packets to these ports are dropped either way | Keep the set in the tree |

## Block F. Ways in from the internet

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| F1 | Does anything outside the house need to connect **in** to a device at home (remote desktop, a game server, a camera)? | See F2. Most houses answer no: outgoing connections, streaming, video calls and cloud cameras need nothing here | **No.** Then remove the example forward: delete the three `dnat to $RUSTDESK_HOST` lines and the `hairpin replies` line in `firewall/common/etc/nftables.conf`. Keep both `RUSTDESK_` lines in the two `profile.nft` files and keep `REMOTE_SRC` at the example value: `validate.sh` uses that address for one test, and it is a documentation address that never appears on the internet |
| F2 | For each way in: which LAN device, which ports, and **from which outside address**? | `REMOTE_SRC` (the one outside address), `REMOTE_NAME` (a short name for it, used in the brief). The example forward is a RustDesk server on the admin PC at `.5`: TCP 21115 to 21117 and UDP 21116. Other ports or a second forward are edits in the `prerouting` chain | **Stop** if the person cannot name a fixed outside address. A forward open to the whole internet is not offered. Suggest a VPN service or the vendor's relay instead |
| F3 | Do you want to reach the firewall's SSH from outside? | Nothing. The set `wan_ssh_allow` in `profiles/prod/etc/nftables.d/profile.nft` stays empty | No. Use the forward in F2 to a PC at home, then SSH from there |
| F4 | Does a game console or an app ask for UPnP? | Nothing. There is no UPnP service | No. The report shows which device asked (signal `port-mapping`); most apps work without it |

## Block G. Email, the report and the brief

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| G1 | Should the firewall send email (WAN changes, the daily brief)? It needs a Gmail account with an app password and a TPM chip (A6). | Nothing in the tree. In stage 4 the person runs `firewall/tools/store-mail-secret.ps1`, which asks for the sender, the one recipient and the app password | Off. Until the script has run, the mail service does not start and messages wait in `/var/spool/fw-mail` |
| G2 | Use a sender account made only for this? | Advice, no setting | Yes. Root on the firewall can read the app password, so do not use your main account |
| G3 | The daily report is a file on the box, written at 05:30. Keep it? | `fw-report.timer` in `UNITS` | On. It costs nothing and needs no account |
| G4 | Should an AI agent on the box read the report each morning and mail you a short brief? It needs email (G1) and a Claude sign-in token, and uses your Claude plan each day. | Nothing in the tree. In stage 4 the person runs `agent/store-claude-token.ps1` | Off. Without a token the brief job fails and the full report is mailed instead, when email is set up |
| G5 | What is normal in your house (the remote-access tools you use, a VPN, servers, the approved forward)? | Edit the site file `site/<name>/files/common/usr/local/share/fw-analysis/brief.md`. The copy from `site/example` holds the example house's text, so it must be changed before the first brief | Ask only when G4 is yes. Remove every sentence about the example house that is not true for this one |

## Block H. Backups

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| H1 | Should the admin PC pull a backup of the firewall's configuration every day? | Nothing in the tree. After the cutover the person runs `firewall/tools/pull-fw-backup.ps1 -Setup`, then `-Register` (Windows scheduled tasks at 06:30, and Tuesdays at 07:00) | On, set up after the cutover. Until then `/var/backups/fw-deploy/` on the box holds what each deploy replaced |
| H2 | Where do the daily copies and the long-term archive go? | Parameters `-Dest` and `-ArchiveDest` of that script | `-Dest` in the user profile; `-ArchiveDest` on a second disk |
| H3 | How many copies to keep? | `-KeepDaily`, `-KeepMonthly` | 14 daily, 12 monthly |

## Block I. Access and the agent

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| I1 | The box accepts SSH with a key only, for the user `fwadmin` only. Who makes the key? | The person runs `ssh-keygen` with a passphrase (`installer/BUILD.md`, step 2). The agent gets the path of the `.pub` file | No other way is offered |
| I2 | After the install, `fwadmin` has sudo **without a password**, so that an agent can manage the box over SSH. Keep that after the setup? | The file `/etc/sudoers.d/10-fwadmin` on the box | Keep it during the setup: the `store-*.ps1` scripts and the backup setup use `sudo -n` and fail without it. Decide again at the end of stage 4. Without it, the person types each `sudo` command and the agent reads the output. `agent/README.md` has both ways |
| I3 | The image installs Claude Code and a user `fleet` (no sudo, no SSH login) for the daily brief. Keep them? | Removal steps in `agent/README.md` | Keep them if G4 is yes or undecided. They hold no credential until the person stores a token. If G4 is a firm no, remove them after stage 4 |
| I4 | Will an AI agent on the admin PC use your SSH key? | How the person loads the key: an SSH agent with the passphrase typed by the person | The agent never learns the passphrase and never copies the key file |

## Block J. Updates

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| J1 | Install Debian security fixes and point releases by themselves? | `firewall/common/etc/apt/apt.conf.d/52firewall-unattended` | On |
| J2 | May the box reboot by itself when an update needs it? At what time? The internet is away for about one minute. | `Automatic-Reboot` and `Automatic-Reboot-Time` in the same file | On, at 04:30 |
| J3 | Update DuckDB each week within the same major version, and the Suricata rules each day? | `common/etc/default/fw-duckdb-update`, `fw-suricata-update` | On |
| J4 | Is the machine a Lenovo? | `fw-bios-check.timer`: a weekly look at Lenovo's update catalog. It installs nothing | On for Lenovo. On another maker it reports "not a Lenovo machine type"; remove the timer from `UNITS` in `deploy.sh` if you like |

## Block K. The cutover

| Id | Question | Sets | Fail-safe default |
|---|---|---|---|
| K1 | What happens to the present router: access point, or unplugged? | The plan in `firewall/CUTOVER.md` | Keep it as the access point, with a fixed address of `.4`, and keep it powered: it is also the rollback |
| K2 | Can you save the present router's settings to a file and note its WAN MAC? | The rollback | Do both before the cutover day. Without them, a rollback means setting the old router up by hand |
| K3 | When can the house be without internet for 30 minutes, with nobody on a call? | The date | Not on a work day. Not before the bench profile has run for some days |
| K4 | How will the admin PC get help if the internet stays down (a phone hotspot)? | The checklist | Test the hotspot before the day |
| K5 | Is there a laptop and a cable for the rescue port, and has the SSH login on that port been tried? | The checklist | Try it in stage 4. This port is the way back in after any mistake |
| K6 | Which devices matter most to check afterwards (work laptop, phone line, TV, cameras, door lock)? | The test list in `CUTOVER.md` | Write the list now, while nothing is broken |

---

## The summary to read back

Before any build, show the person:

1. `site/<name>/site.env` in full. It holds no secret.
2. The reservations file.
3. A list of every edit you will make to files outside `site/<name>/`, with the reason.
4. Every **stop** that came up, and what the person decided.
5. What stays **off** until they act: email, the brief, DDNS, the backup pull, country blocks, the shaper.
6. What is **open** from the internet after the cutover. With the defaults: nothing.

Then render and check:

```sh
python3 tools/render-site.py site/<name>
```

A message such as `no value in site/<name>/site.env for:` means that a key in `site.env` is missing. Fix
`site.env`, not the files in `out/`.

Next: [SETUP-GUIDE.md](SETUP-GUIDE.md), stage 2.
