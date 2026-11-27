# Firewall configuration

Everything that makes a fresh Debian 13 install into the router: configuration files, the programs that run
on the box, and the two scripts that check and install them.

Read [../SETUP-GUIDE.md](../SETUP-GUIDE.md) first. This folder is stage 4 of that guide.

| Document | What |
|---|---|
| [SERVICES.md](SERVICES.md) | Every service and timer: what it does, its settings, and how to check it |
| [SECRETS.md](SECRETS.md) | How the person stores the DDNS token and the mail password on the box |
| [CUTOVER.md](CUTOVER.md) | The day the box replaces the old router, and the rollback |
| [MAPPING.md](MAPPING.md) | Where each setting of a consumer router lives in this tree |

## Layout

| Path | What |
|---|---|
| `common/` | Files for both profiles, laid out as on the box: `common/etc/...` becomes `/etc/...`, `common/usr/local/...` becomes `/usr/local/...` |
| `profiles/bench/` | The test setup: `wan0` on your present LAN, a test LAN `192.168.12.0/24` on `trunk0` |
| `profiles/prod/` | The real network: `wan0` on the internet line, your LAN on `trunk0` |
| `guard/` | The deploy guard. It is installed before a profile and is never reverted |
| `validate.sh` | Runs on the box. Tests every file. Changes nothing |
| `deploy.sh` | Runs on the box. Validates, saves, installs, reboots, then waits for your confirm |
| `tools/` | Scripts for the box (`nic-macs.sh`) and for the admin PC (the others) |

Many files here hold placeholders: a key such as `LAN_PREFIX` between two `@@` marks. `tools/render-site.py`
in the repository root fills them in. You deploy the rendered copy in `out/<name>/firewall/`, never this
folder as it is.

## Network design

| Interface | Port | Address | Role |
|---|---|---|---|
| `wan0` | Card port 0 | DHCP from the provider. In `prod` it uses the MAC address in `WAN_CLONE_MAC` | Internet |
| `trunk0` | Card port 1, to the switch | `<LAN_PREFIX>.1/24` | The LAN |
| `mgmt0` | Onboard port | `10.255.255.1/30` | Rescue port. A laptop gets `.2` by DHCP |
| `spare2`, `spare3` | Card ports 2 and 3 | None | Not used |

The names come from `/etc/systemd/network/*.link`, which match each port by its permanent MAC address.

## What runs on the box

| Function | How |
|---|---|
| Firewall and NAT | nftables: `/etc/nftables.conf` plus `/etc/nftables.d/profile.nft`. Default drop |
| DHCP and LAN names | dnsmasq, with a query log |
| DNS resolver | unbound on `127.0.0.1:5335`, DNS over TLS to Quad9, DNSSEC |
| DNS blocking | unbound response policy zones, filled by `fw-dnsbl` |
| IP block lists | nftables sets, filled by `fw-blocklists` |
| Time | chrony serves NTP to the LAN |
| Intrusion detection | Suricata 8 on `trunk0` |
| Traffic records | `fw-flowd` reads the kernel's connection table |
| Database | DuckDB in `/var/lib/fwdb`, loaded by `fw-ingest` |
| Daily report and brief | `fw-report`, `fw-brief` |
| Email | `fw-mail`, one fixed recipient |
| WAN events and DDNS | `wan-event`, from a dhcpcd hook and a 5-minute timer |
| Updates | unattended-upgrades, `fw-duckdb-update`, `fw-suricata-update`, `fw-bios-check` |
| Shaper | CAKE on `wan0`, off by default |
| History and backup | etckeeper, `fw-backup-export` for the pull from the admin PC |

[SERVICES.md](SERVICES.md) has the details of each.

## Validate

On the box, in `~/firewall-config`:

```sh
sudo ./validate.sh bench      # or prod
```

It lays out `common/`, the profile and `guard/` in a scratch folder and tests the result:

- each program's own configuration test: `nft -c`, `dnsmasq --test`, `unbound-checkconf`, `rsyslogd -N1`,
  `suricata -T`, `visudo -c`, `logrotate -d`, `systemd-analyze verify`, and checks of the sshd, chrony, apt,
  sysctl and interface files;
- the self-tests of the block list, DNS list, traffic, database and archive programs;
- an unbound test instance that must block a listed name and answer an allowed one;
- the rule set and the shaper in scratch network namespaces, with test packets;
- a search for anything that looks like a secret.

It ends with `RESULT: OK (<profile>)`, `RESULT: OK with warnings` or `RESULT: FAIL`. A `FAIL` line shows the
program's own message. It refuses files that still hold a placeholder.

## Deploy

```sh
sudo ./deploy.sh bench        # or prod
sudo ./deploy.sh prod --no-reboot --minutes 30
```

What it does, in order:

1. Refuses to start while an earlier deploy still waits for its confirm.
2. Runs `validate.sh`. A failure ends the deploy; nothing was changed.
3. Saves every file it will replace to `/var/backups/fw-deploy/<time>/`, with a list of the files that are new.
   It installs nothing unless this save worked.
4. Commits `/etc` (etckeeper).
5. Installs the guard and writes a "pending" marker.
6. Installs the files, creates the service users, enables the services.
7. Rebuilds the initramfs. If that fails, it stops without a reboot and says what to do.
8. Commits `/etc` again and reboots (unless `--no-reboot`).

After the reboot you have 15 minutes (`--minutes N`):

```sh
sudo fw-deploy-confirm        # keep the new files
sudo fw-deploy-revert         # or: put the old files back now
```

With neither, `fw-deploy-guard` puts the old files back and reboots again. If the restore itself fails, the
guard logs an error, writes `revert-failed` in the backup folder, keeps the marker and does not reboot.

**Confirm only from a new SSH session, after the checks in SERVICES.md.** If SSH is lost, cable a laptop to
`mgmt0` and use `ssh fwadmin@10.255.255.1`.

To go back to an older deploy by hand: `sudo fw-deploy-revert /var/backups/fw-deploy/<time>`.

### Guard test

Do this once on the bench, before the cutover. A second deploy of the same files would prove nothing, so the
test deploy carries two changes that must be gone after the revert.

1. The bench deploy is confirmed (`sudo fw-deploy-confirm` printed `confirmed`).
2. Make two test changes in the box copy and deploy:

   ```sh
   cd ~/firewall-config
   echo "# guard-test $(date +%F)" >>common/etc/nftables.conf
   echo 'guard test' >profiles/bench/etc/fw-guard-test
   sudo ./deploy.sh bench
   ```

3. After the reboot, SSH in. **Pass:** `grep -c guard-test /etc/nftables.conf` prints `1` and
   `/etc/fw-guard-test` exists. Do **not** confirm.
4. Wait. 15 minutes after the boot, the box restores the files and reboots. SSH in. **Pass**, all of these:
   - `grep -c guard-test /etc/nftables.conf` prints `0`.
   - `ls /etc/fw-guard-test /var/lib/fw-deploy/pending` reports both as missing.
   - `journalctl -b -1 -t fw-deploy | grep 'revert done'` prints one line.
   - `ls /var/backups/fw-deploy/*/revert-failed` finds no file.
   - `systemctl --failed` lists nothing.
5. Copy the tree to the box again (guide, 4.1), so that the test changes are gone from the box copy.

If the revert fails, read the `revert-failed` file, fix the cause over SSH or `mgmt0`, and run
`sudo fw-deploy-revert`. The box is not ready for the cutover until this test passes.

## Change rules without a reboot

For a quick test of a rule change on the running box:

```sh
sudo fw-apply /path/to/new-ruleset.nft
# test from a NEW session, then:
sudo fw-confirm "why"
```

With no confirm in 120 seconds, the old rule set comes back. This does not replace a deploy: put the change
in the repository as well, or the next deploy removes it.

## Tools

| Tool | Runs on | What |
|---|---|---|
| `tools/nic-macs.sh` | The box | Lists the ports of an Intel i350 card (driver `igb`) with their MAC addresses, in the order `wan0`, `trunk0`, `spare2`, `spare3`. Give it a scratch folder as its argument (`/tmp/nic-links`) and copy the addresses into `site.env` |
| `tools/store-wan-secrets.ps1` | Admin PC, by the person | Prompts for the DDNS update URL and name, stores them root-only on the box, runs a test |
| `tools/store-mail-secret.ps1` | Admin PC, by the person | Prompts for the sender, the recipient and the Gmail app password, stores them encrypted with the box's TPM |
| `tools/pull-fw-backup.ps1` | Admin PC | Pulls the daily backup over SSH. `-Setup` makes the key and installs it on the box, `-Register` makes the scheduled tasks, `-Weekly` writes the long-term archive. The key is accepted only from the addresses in `-From` (default: `192.168.50.5` and the rescue-port laptop); give yours at `-Setup`. `-Weekly` needs Python: set the path with `-Python`, and the archive folder with `-ArchiveDest` |
| `tools/fw-diff.py` | Admin PC | Used by the weekly archive: one full copy a year, then only what changed. `restore` gives a full export back |
| `tools/wired-port.ps1` | Admin PC, elevated | Sets the wired port for the cutover day: `-Mode Lan`, `Mgmt` or `Off`. It holds the example house's addresses (`192.168.50.5`, gateway `192.168.50.1`), adapter and Wi-Fi profile names: **edit them before you use it** |
| `tools/import-asus.py` | Admin PC | Turns a settings dump of an ASUS router into the reservations file and a lease seed. The dump script is not part of this repository; without a dump, write the reservations by hand |

The `.ps1` scripts are for Windows PowerShell. The render does not fill them in: they run from the repository
as they are, with the example house's values as defaults. Their default target is `192.168.50.1`; pass
`-Target` with your address.

## The known-hosts list

The report labels outside addresses that you know: your office, a relative's house, a server you rent. The
list is yours and lives on the box only, in `/var/lib/fwdb/known-hosts.tsv`. One line per address, fields
separated by a tab:

```
203.0.113.45	Acme office	client	tcp/21115,tcp/21116,tcp/21117,udp/21116	RustDesk
```

Address, name, relation, expected ports, note. It is a label and not a permission: the list never opens a
port. It is loaded with the next `fw-ingest` run.

## Rules for this folder

- No secret goes in this tree. `validate.sh` fails if a line looks like a credential.
- Every program in `common/usr/local/sbin` has a header that says what it does. Read it before you change it.
- After a change: render, copy, `validate.sh` for both profiles, then deploy.
