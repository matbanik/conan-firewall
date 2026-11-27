# Setup guide

From an empty machine to a working router, in five stages. Each stage ends with a check. Do not start a stage
before the check of the one before has passed.

`<name>` is your site folder. `<address>` is the firewall's present address. Commands marked **box** run on
the firewall over SSH. Commands marked **PC** run on the admin PC, in the repository root, in a Linux shell
(Linux, or WSL on Windows). Git Bash on Windows is enough for everything except the image build in stage 2.

| Stage | Result | Changes your network? |
|---|---|---|
| 1. Configure | `site/<name>/` holds your answers | No |
| 2. Build and install | The machine runs Debian and accepts your SSH key | No. It is one more computer on the LAN |
| 3. Connect the agent | The agent can run commands on the box | No |
| 4. Start the services | The bench profile runs, every service is checked, the rollback is tested | No. The box routes only for one test laptop |
| 5. Cut over | The box is the router | **Yes** |

Write one line to `site/<name>/PROGRESS.md` after each stage: the date, the stage, the result.

---

## Stage 1. Configure

1. Run the interview in [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md).
2. Make the edits that the answers call for. Keep a list in `site/<name>/ANSWERS.md`.
3. Render:

   ```sh
   python3 tools/render-site.py site/<name>
   ```

**Check:** the command prints the two folders it wrote, `out/<name>/firewall` and `out/<name>/installer`, and
no error. The MAC addresses of the box's own ports are still the example values. That is expected; stage 4
sets them.

## Stage 2. Build and install

1. Follow [installer/BUILD.md](installer/BUILD.md) from step 2. The person makes the SSH key and writes the
   USB stick. The agent runs fetch, build and verify.
2. Follow [installer/INSTALL.md](installer/INSTALL.md). The person sits at the machine with a screen and a
   keyboard, for about 15 minutes. Cable the machine's **onboard** port to the house LAN.
3. Find the box's address: your router lists a new client named `firewall`. Or log in as `fwadmin` on the
   machine's own screen and run `ip -br a`.

**Check (PC, typed by the person):**

```sh
ssh -i ~/.ssh/firewall_ed25519 fwadmin@<address> 'tail -n 1 /var/log/firewall-bootstrap.log'
```

SSH asks for the passphrase of the key. The first time it also asks whether to trust the host: compare the
fingerprint as stage 3, step 2 says, before you type `yes`. The command prints `bootstrap done`. If the log has a `WARNING` line, INSTALL.md says what to do.

## Stage 3. Connect the agent

Read [agent/README.md](agent/README.md). In short:

1. The person loads the key into an SSH agent and types the passphrase. The AI agent then uses
   `ssh fwadmin@<address>` and never sees the passphrase or the key file.
2. Check the host key the first time. The person compares the fingerprint that SSH shows with the output of
   `sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the machine's own screen.

**Check (PC):** `ssh fwadmin@<address> 'sudo -n true && hostname'` prints `firewall` with no prompt.

## Stage 4. Start the services

### 4.1 Copy the tree to the box

**PC:**

```sh
tar -C out/<name>/firewall -cf - . | ssh fwadmin@<address> \
  'rm -rf firewall-config && mkdir firewall-config && tar -xf - -C firewall-config &&
   chmod +x firewall-config/deploy.sh firewall-config/validate.sh firewall-config/tools/*.sh'
```

Run this again after every render. The copy on the box, `~/firewall-config`, is only a copy: change files in
the repository, render, and copy again. Do not use Windows PowerShell for this pipe; it damages the data.

### 4.2 Name the ports

The firewall names its ports by MAC address, so that `wan0` is always the same socket.

1. **Box**, with an Intel i350 card:

   ```sh
   sudo sh ~/firewall-config/tools/nic-macs.sh /tmp/nic-links
   ```

   It prints one line per card port: the name it gets (`wan0`, `trunk0`, `spare2`, `spare3`), the present
   name, and the MAC address. With another card, list all ports and choose yourself:

   ```sh
   for i in /sys/class/net/e*; do n=${i##*/}; echo "$n $(sudo ethtool -P "$n")"; done
   ```

2. Find each socket: `sudo ethtool -p <present name> 10` blinks its light for 10 seconds. The person puts a
   label on each: `wan0`, `trunk0`, `mgmt0`.
3. Put the addresses into `site/<name>/site.env`: `WAN0_MAC`, `TRUNK0_MAC`, `SPARE2_MAC`, `SPARE3_MAC`, and
   `MGMT0_MAC` for the onboard port. `nic-macs.sh` lists only the card; the second command lists the onboard
   port too, and it is the one that `ip -br link` shows as `UP` now. Lower case. With fewer than five ports, leave the
   spare keys at the example values; those files then match no port.
4. If the answer to B3 was "no clone", set `WAN_CLONE_MAC` and `WAN_CLONE_MAC_UC` to the `wan0` address.
5. **PC:** render and copy again (4.1).

### 4.3 Validate

**Box:**

```sh
cd ~/firewall-config
sudo ./validate.sh bench
sudo ./validate.sh prod
```

`validate.sh` installs nothing. It lays the files out in a scratch folder and runs each program's own
configuration test: nftables, dnsmasq, unbound, Suricata, systemd, and more. It also loads the rule set in
scratch network namespaces and sends test packets through it.

**Check:** both runs end with `RESULT: OK`. A line that starts with `FAIL` names the test and shows the
program's message below it. Fix the file in the repository, render, copy, and run it again. `RESULT: OK with
warnings` passes; read each warning and tell the person what it means.

### 4.4 Deploy the bench profile

The bench profile makes the box a router for one test laptop, behind your present router. The house network
does not change.

Until now the **onboard** port has been on the house LAN. With the bench profile that port becomes `mgmt0`,
the rescue port, and it answers DHCP. It must be off the house LAN before the box starts with the new files.
So this first deploy does not reboot by itself: install, power off, move the cables, power on.

1. **Box:**

   ```sh
   cd ~/firewall-config && sudo ./deploy.sh bench --no-reboot
   sudo poweroff
   ```

2. **The person** moves the cables while the box is off:

   | Port | Goes to |
   |---|---|
   | `mgmt0` (onboard) | **Unplug it from the house LAN.** It is the rescue port from now on: one laptop, or nothing |
   | `wan0` | A free LAN port of your present router or switch |
   | `trunk0` | The test laptop only. **Never the house switch:** this port runs a DHCP server |

3. **The person** powers the box on.

The box gets a **new address** on `wan0`, because that port has another MAC address. Find it in your router's
client list. The bench profile accepts SSH on `wan0` from your LAN (`LAN_PREFIX`).

You have 15 minutes from the start of the box to check and confirm. With no confirm, it puts the old files
back and reboots again. Then the box is as it was after stage 2: cable the onboard port to the house LAN
again, find the cause, and start 4.4 again.

Later bench deploys (4.6, and every change after it) use `sudo ./deploy.sh bench` and reboot by themselves:
the cables are already right.

### 4.5 Check and confirm

Open a **new** SSH session to the new address. Run the "After a deploy" checks in
[firewall/SERVICES.md](firewall/SERVICES.md), and the tests on the test laptop that it lists. When they pass:

```sh
sudo fw-deploy-confirm
```

**Check:** it prints `confirmed`, and `systemctl --failed` lists nothing.

### 4.6 Test the rollback

Do this once. It proves that a bad deploy undoes itself, before you depend on it. The steps are in
[firewall/README.md](firewall/README.md), "Guard test". The box reboots twice and the test takes about 25
minutes.

**Check:** every "Pass" line of that test holds.

### 4.7 Test the rescue port

The person cables a laptop to `mgmt0`. The laptop gets `10.255.255.2` by DHCP.
`ssh fwadmin@10.255.255.1` must work from it (with the key on that laptop, or with the admin PC cabled there).

### 4.8 Let it run

Leave the box on the bench for some days. Each morning:

```sh
systemctl --failed
systemctl list-timers 'fw-*' wan-check.timer
ls -l /var/lib/fwdb/reports/ | tail -n 3
```

Go through each service in [firewall/SERVICES.md](firewall/SERVICES.md) once. On the bench, the report shows
only the test laptop's traffic.

### 4.9 Secrets and access (each one optional)

| What | Who | How |
|---|---|---|
| Email | The person | `firewall/tools/store-mail-secret.ps1 -Target <address>`. See [firewall/SECRETS.md](firewall/SECRETS.md) |
| DDNS | The person | `firewall/tools/store-wan-secrets.ps1 -Target <address>` |
| The daily brief | The person | `agent/store-claude-token.ps1 -Address <address>`. Edit your `brief.md` site file first (question G5), render and deploy |
| sudo with a password, removal of Claude Code and the `fleet` user | The person decides | [agent/README.md](agent/README.md), "Reduce what the agent can do" |

**Check for stage 4:** both profiles validate, the bench deploy is confirmed, the rollback test passed, the
rescue port works, and three daily reports exist.

## Stage 5. Cut over

Follow [firewall/CUTOVER.md](firewall/CUTOVER.md). It has the preparation, a checklist for the day, the
steps, the checks and the rollback.

The agent does not start this stage by itself. The person sets the date, tells the house, and moves the
cables.

**Check:** the checks in CUTOVER.md pass, `sudo fw-deploy-confirm` printed `confirmed`, and the follow-ups
are done or have a date.

---

## After the setup

| Task | How |
|---|---|
| Change a setting | Edit the file in the repository, render, copy (4.1), `sudo ./validate.sh prod`, `sudo ./deploy.sh prod`, check, `sudo fw-deploy-confirm` |
| Try a rule change without a reboot | `sudo fw-apply FILE`, test, `sudo fw-confirm "reason"`. With no confirm in 120 seconds, the old rules come back |
| Allow a blocked name | Add it to `firewall/common/etc/unbound/rpz-allow.zone`, then deploy |
| Add a device with a fixed address | Add a line to your reservations file in `site/<name>/files/`, then deploy |
| Read the daily report | `ls /var/lib/fwdb/reports/` on the box |
| Ask the database | On the box: `sudo -H -u fleet /usr/local/share/fw-analysis/tools/bin/fwq "SELECT count(*) FROM fwdb.traffic"`. It is read-only. The tables are described in `firewall/common/usr/local/share/fw-analysis/context/analyst.md` |
| Get new versions of this repository | `git pull`, render, validate, deploy. Your values in `site/<name>/` are not touched |
| Restore after a disk failure | Install again from the USB stick, copy the tree, deploy `prod`, and store the secrets again with the `store-*.ps1` scripts. The pulled backup holds `/etc` without secrets, the programs, the reports and the package list, to compare with and to copy single files from. It does not hold the database; the weekly archives do |
