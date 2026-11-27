# Cutover

The day the firewall replaces your present router. The house has no internet for about 30 minutes. A rollback
takes under 15 minutes at any point and is at the end of this file. Read it before you start.

This is stage 5 of [../SETUP-GUIDE.md](../SETUP-GUIDE.md). Do not start before the check of stage 4 has
passed. The person sets the date and moves the cables. The agent runs the commands on the box and reads the
checks.

The addresses below use the example LAN `192.168.50.0/24`. Read your own `LAN_PREFIX` for `192.168.50`.

## The result

```
Provider's device (ONT or modem) ──► firewall wan0
firewall trunk0 ──► your switch                     the LAN
old router, as an access point at .4 ──► switch     Wi-Fi as before
firewall mgmt0 ── free                              rescue port
```

The old router stays powered and keeps its Wi-Fi names and passwords, so no Wi-Fi client needs a change. It is
also the rollback.

## Before the day

Each item is done once and can be done days ahead.

1. **Stage 4 is complete.** Both profiles validate, the guard test passed, the rescue port works, and the box
   has run on the bench for some days.
2. **Save the old router's settings to a file** (most routers: Administration, "Save settings" or "Backup").
   Keep the file on the admin PC and one more copy on another machine. This file is the rollback.
3. **Write down the old router's WAN status:** its public address and its WAN MAC address. If you clone the
   MAC (question B3), the firewall should get the same public address.
4. **Find the access point mode** in the old router's menus. If it has none: you will switch its DHCP server
   off, give it the LAN address `.4`, and cable one of its **LAN** ports (not its WAN port) to the switch.
5. **Reservations.** Every device that must keep a fixed address has a line in your reservations file
   (question C2), and the tree on the box is the latest render.
6. **Make the test list** (question K6): the devices and services that matter most, each with a test that
   takes a minute. Examples: a phone on Wi-Fi opens a web page; the work laptop joins its VPN; the TV plays a
   stream; the phone adapter has a dial tone; the forward answers from the remote site.
7. **Internet for the admin PC during the cutover.** An agent that runs on the admin PC needs internet while
   the house has none. A phone hotspot does this. Join it once, so that the PC knows it. Check that the
   hotspot's range is not your LAN and not `10.255.255.0/30`; if it is, turn the hotspot off and on to get
   another range. Set the hotspot network to "metered", so that the PC does not use it for large downloads.
8. **Secrets** ([SECRETS.md](SECRETS.md)) may be stored before or after the cutover. The DDNS name can only be
   tested after it.

## How the admin PC connects during the cutover

The admin PC needs two paths at once: internet for the agent, and the house LAN for the old router, the
switch and the firewall.

| Path | Use | Default route |
|---|---|---|
| Wi-Fi to the phone hotspot | Internet for the agent | Yes |
| Cable to the switch, fixed address in the LAN, **no gateway** | The old router's pages, SSH to the firewall | No |
| Cable to the firewall's `mgmt0` port, address by DHCP (`10.255.255.2`) | Rescue only | No |

On Windows, [tools/wired-port.ps1](tools/wired-port.ps1) sets the wired port for each row. It holds the example
house's addresses and adapter names, so edit it for your PC first. Run it elevated:

| Mode | What it does |
|---|---|
| `-Mode Lan` | Wired port: fixed `192.168.50.5/24`, no gateway, no DNS. The house Wi-Fi profile is set to "connect manually", so that Windows does not join it and hold the address twice. It also adds one host route (see below) |
| `-Mode Mgmt` | Wired port: DHCP, for the `mgmt0` port |
| `-Mode Off` | Back to normal: wired port to DHCP, the Wi-Fi profile connects by itself again |

The script is written for the example: it has the address `192.168.50.5`, and the parameters `-Adapter`
(default `Ethernet`), `-WifiProfile` (your Wi-Fi name) and `-RustDeskRemote` (your `REMOTE_SRC`). Read it and
change the addresses to yours before the day. On Linux or macOS, set the same by hand: a fixed address with no
gateway on the wired port.

**The host route.** If the admin PC is also the target of your port forward, the firewall sends the remote
site's connections to it over the cable, but the PC's answers would leave through the hotspot and never
arrive. `-Mode Lan` adds a route for the remote address through the LAN gateway. The route is gone after a
reboot of the PC; run `-Mode Lan` again.

## Checklist for the day

Do every item, in this order.

### A. State

1. "Before the day" is complete. The settings file of the old router is in two places.
2. On the box: `sudo ./validate.sh prod` ends with `RESULT: OK`, and `systemctl --failed` lists nothing.
3. Tell the people in the house. Write down the start time.

### B. The admin PC

1. Put the phone on a charger and start the hotspot.
2. Connect a cable from the admin PC to a free switch port. Not the port that `trunk0` will use.
3. Put a second cable next to the firewall, for `mgmt0`.

### C. Agent access

1. `ssh fwadmin@<bench address> true` works with no prompt.
2. The PC's `known_hosts` file has the firewall's host key under three names: the bench address, the future
   LAN address (`192.168.50.1`) and `10.255.255.1`. The key is the same; add the two missing lines now, so that
   no host-key question comes up during the cutover:

   ```sh
   ssh-keyscan -t ed25519 <bench address> 2>/dev/null |
     sed -e 's/^[^ ]*/192.168.50.1/p' -e 's/^[^ ]*/10.255.255.1/' >>~/.ssh/known_hosts
   ```

   Compare the fingerprint first, as in stage 3.
3. The old router's admin password is at hand. The agent does not need it; the person types it.

### D. Rollback readiness

1. Read "Rollback" below.
2. Know this trap: **an unconfirmed deploy goes back to the files from before it, and that is the bench
   profile.** The bench profile runs a DHCP server on `trunk0` for the range `192.168.12.0/24`. On the house
   switch that would hand wrong addresses to your devices. So: if you will not confirm, **unplug `trunk0` from
   the switch before the 30 minutes end.**
3. If the LAN path to the firewall fails, move the PC's cable to `mgmt0`, run `wired-port.ps1 -Mode Mgmt`,
   and use `ssh fwadmin@10.255.255.1`.

## The cutover

1. **Box**, still on the bench, over SSH:

   ```sh
   cd ~/firewall-config
   sudo ./deploy.sh prod --no-reboot --minutes 30
   sudo poweroff
   ```

   The `prod` files are installed and wait for a confirm. The 30 minutes start when the box boots again.

   Optional, before the `poweroff`: a lease seed, so that every client keeps its present address. With an
   ASUS router and a settings dump, `tools/import-asus.py --leases` writes `out/dnsmasq.leases.seed`. Copy it
   to the box and run
   `sudo install -m 644 -o dnsmasq -g nogroup dnsmasq.leases.seed /var/lib/misc/dnsmasq.leases`.
   Without a seed, devices with a reservation keep their address, and the others get one from the pool when
   they renew.

2. **Admin PC** to the cutover network: `wired-port.ps1 -Mode Lan` (elevated), leave the house Wi-Fi, join
   the hotspot. Check: `ping 192.168.50.1` answers over the cable (the old router), and a web page opens
   over the hotspot.

3. **Old router to access point mode.** In its pages: operation mode "Access Point". LAN address fixed:
   `192.168.50.4`, mask `255.255.255.0`, gateway `192.168.50.1`, DNS `192.168.50.1`. It reboots. Open its
   pages at the new address and check that the Wi-Fi names are as before.

4. **Cables.** The provider's cable moves from the old router's WAN port to the firewall's `wan0`. The
   firewall's `trunk0` goes to the switch. The old router stays on the switch, on a LAN port.

   Without a cloned MAC address, some provider devices accept a new router only after a restart: switch the
   modem or ONT off for a minute.

5. **Power on the firewall.** Write down the time. You have 30 minutes.

6. **Check**, in this order. Stop at the first failure and decide: fix, or roll back.

   | Check | Pass |
   |---|---|
   | `ssh fwadmin@192.168.50.1` from the admin PC, over the cable | A shell |
   | `systemctl --failed` | Lists nothing |
   | `ip -4 -br addr show wan0` | A public address. With a cloned MAC: the one you wrote down |
   | `sudo journalctl -t wan-ip-watch -n 5` | A line with the address, no error |
   | `dig @127.0.0.1 debian.org +short` | An address |
   | A phone on Wi-Fi | An address in `192.168.50.x`, gateway `.1`, a web page opens |
   | `cat /var/lib/misc/dnsmasq.leases` | Clients appear, one by one |
   | The "After a deploy" list in [SERVICES.md](SERVICES.md) | Passes |
   | Your test list (K6) | Each test passes |
   | The forward, from the remote site | It connects. If not, look at the host route on the admin PC first |

7. **Confirm**, from a new SSH session: `sudo fw-deploy-confirm`. It prints `confirmed`.

   If you do not confirm: unplug `trunk0` before the 30 minutes end, and go to "Rollback".

8. **Admin PC back to normal:** `wired-port.ps1 -Mode Off` (elevated), join the house Wi-Fi, renew the
   address (`ipconfig /renew`), turn the hotspot off. Check that the gateway is `192.168.50.1`.

## After the cutover

| When | What |
|---|---|
| The same day | Devices that did not come back: restart them, or switch their Wi-Fi off and on. A device with a fixed address set **on the device** needs gateway and DNS `.1` |
| The same day | Store the secrets if you have not: [SECRETS.md](SECRETS.md). `sudo wan-event TEST ddns` sends a test mail and sends the address to the DDNS provider |
| The same day | If you use a DDNS name, change it at the remote site and in the service that announces it. The old router's own DDNS name stops when it becomes an access point |
| The same day | Set up the backup pull on the admin PC: `tools/pull-fw-backup.ps1 -Setup`, then `-Register` (options in [README.md](README.md), "Tools") |
| The next morning | Read the first daily report with real traffic. Edit your `brief.md` site file for what is normal in your house, then deploy |
| The first week | Look at the DNS block log (`/var/log/dnsbl.log`) for names that someone needs, and add those to `rpz-allow.zone` |
| The first week | Measure the line under load. Turn the shaper on only if the delay grows (`/etc/default/fw-shaper` says how) |
| The first week | Scripts and bookmarks that used the old router at `.1`: point them at `.4`, or retire them. Port forwards, DDNS and filters set on the old router no longer do anything |
| The first week | On the access point, switch off what it no longer needs: file sharing, its own DDNS, remote management |
| Later | Decide on password sudo and on Claude Code ([../agent/README.md](../agent/README.md)) |

## Rollback

Under 15 minutes. Use it when a check fails and you cannot fix it in the time you have.

1. **Power off the firewall** (`sudo poweroff`, or the power button). **Unplug `trunk0` from the switch.**
   The guard would otherwise put the bench profile back at the next boot, with its DHCP server on your LAN.
2. Move the provider's cable back to the old router's WAN port.
3. On the admin PC (cable on the switch, `-Mode Lan`), open the old router's pages at `192.168.50.4` and
   **restore the settings file**. It reboots as the router at `192.168.50.1`. If its pages do not open, a
   factory reset is the last resort; it means setting the router up by hand.
4. `wired-port.ps1 -Mode Off`, and join the house Wi-Fi.
5. Clients renew within minutes. Switching a device's Wi-Fi off and on is faster.
6. Later: power the firewall on with **nothing on `trunk0`** and a laptop on `mgmt0`. Run
   `sudo fw-deploy-revert` over `ssh fwadmin@10.255.255.1`, or wait for the guard. The box reboots with the
   bench files. Put it back on the bench cabling and read what went wrong: `sudo journalctl -b -2 -p warning`
   and `sudo journalctl -t fw-deploy`.

## Notes

- **Double check `trunk0`.** Every dangerous state in this file is "a bench profile on the house switch".
  When in doubt, unplug `trunk0`.
- **No second DHCP server.** After step 3 the old router must not hand out addresses. Access point mode
  switches its DHCP server off; check it on routers that have no such mode.
- **The 30 minutes run from the boot**, not from the deploy, and every boot of an unconfirmed box starts
  them again. `sudo journalctl -t fw-deploy -b` shows the line that says when the revert will happen.
