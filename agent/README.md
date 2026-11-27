# The agent and the firewall

How an AI agent on your admin PC reaches the box, what it can do there, and how to give it less. This is
stage 3 of [../SETUP-GUIDE.md](../SETUP-GUIDE.md).

There are two different agents in this project. Keep them apart:

| | The managing agent | The brief |
|---|---|---|
| Runs on | Your admin PC, in your session | The firewall, once a day |
| Is | The AI agent you talk to (any agent that can use a shell) | One short Claude Code session |
| Runs as | `fwadmin` over SSH, with your key | The user `fleet` |
| Can | Everything `fwadmin` can: with the default setup, anything on the box | Read today's report and ask the database with one read-only tool. No network tools, no sudo |
| Needs | Your SSH key, loaded by you | A Claude token, stored by you |
| Optional? | Yes. You can type every command yourself | Yes. Without it the plain report is mailed |

## Access for the managing agent

The box accepts SSH from the LAN and the rescue port only, with a key only, for the user `fwadmin` only.
There is no password login and no login from the internet.

### 1. The key stays yours

You made the key in `installer/BUILD.md`, step 2, with a passphrase. The agent uses the key through an SSH
agent. It never learns the passphrase and never reads or copies the key file.

Windows (PowerShell, once as administrator for the first line):

```powershell
Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent
ssh-add $HOME\.ssh\firewall_ed25519      # you type the passphrase
```

Linux and macOS:

```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/firewall_ed25519          # you type the passphrase
```

An entry in `~/.ssh/config` saves typing:

```
Host firewall
    HostName 192.168.50.1
    User fwadmin
    IdentityFile ~/.ssh/firewall_ed25519
    IdentitiesOnly yes
```

Use the box's present address for `HostName`, and change it after the cutover.

### 2. Check the host key once

The first connection asks whether to trust the box's key. Do not say yes blindly. On the box's own screen and
keyboard, log in as `fwadmin` and run:

```sh
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare the `SHA256:` value with the one in the SSH question. Only then answer `yes`. After a reinstall the
key is new: remove the old line with `ssh-keygen -R <address>` and check again. If the question comes up at
any other time, stop: something else answers at that address.

### 3. Test

```sh
ssh fwadmin@<address> 'sudo -n true && hostname'
```

It prints `firewall` and asks nothing.

## What the managing agent may do

The rules are in [../AGENTS.md](../AGENTS.md). In short: it changes the box only through `deploy.sh` and
`fw-apply`, it confirms a deploy only after the checks, it never reads a secret, and the person stores the
secrets, writes the USB stick and moves the cables.

These rules are instructions, not locks. With the default setup `fwadmin` has sudo without a password, so an
agent that ignores its rules could do anything on the box. What limits the damage:

- Every deploy saves the old files and undoes itself if nobody confirms.
- `/etc` is under git on the box: `sudo git -C /etc log` shows each change.
- The secrets are in files that only root or one service user can read, and the mail login is encrypted with
  the TPM. An agent with full sudo can still reach them. If that is not acceptable, use password sudo (below).
- The backup on the admin PC is pulled with a key that can run one command.

## The brief

`fw-brief` runs after the daily report. It gives the report to one Claude Code session as the user `fleet`.
That session has one tool (`fwq`: read-only SQL on the database), no network tools, and a time limit. The
answer is mailed. The unit's sandbox makes the system read-only for it.

To turn it on, the person runs this on the admin PC, in a real terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File agent\store-claude-token.ps1 -Address <address>
```

The script runs `claude setup-token` (a browser page opens and you approve), asks you to paste the token with
hidden input, and sends it over SSH into a file that only `fleet` can read. It then runs a one-turn test on
the box and prints `RESULT: OK`. It needs Claude Code on the admin PC and a Claude subscription.

- The agent does not run this script and never sees the token.
- The token is not in the repository, not in the backup, and not in `/etc`.
- To turn the brief off: `sudo rm /home/fleet/.agent/fleet/credentials/claude-oauth-token`. The report is
  then mailed as it is. Revoke the token in your Claude account as well.
- Before the first brief, edit `site/<name>/files/common/usr/local/share/fw-analysis/brief.md`, then render and deploy. The
  copy from `site/example` holds the example house's idea of "normal" (one approved forward from one remote
  site to one admin PC). Replace that part with yours, or the brief will judge your traffic by someone else's
  house.

What the brief sends to Anthropic: the text of the daily report, and the results of the queries the session
runs. The report holds LAN device names, addresses, and the names of sites that devices asked for. If that
must not leave the house, do not store a token.

### fleet-member.service

The image also installs a unit `fleet-member.service`. It is for people who run jobs on several machines from
one hub with a separate project, and it does nothing here: it starts only when two files exist that this
repository never writes. You can leave it or remove it (below).

## Reduce what the agent can do

Decide at the end of stage 4, and again after the cutover. Each step is separate.

### Password sudo

```sh
sudo passwd fwadmin                       # only if you do not know the password from the install
sudo rm /etc/sudoers.d/10-fwadmin
```

`fwadmin` is in the group `sudo`, so `sudo` still works, with the password. Test it in a **second** session
before you close the first: `sudo -k; sudo true`.

After this:

- The agent can read what `fwadmin` may read (most status commands, the journal) and cannot change the box.
- The person types `sudo ./validate.sh`, `sudo ./deploy.sh` and `sudo fw-deploy-confirm`. The agent prepares
  the files, says what to run, and reads the output that you paste or that it can read itself.
- `store-mail-secret.ps1`, `store-wan-secrets.ps1`, `store-claude-token.ps1` and `pull-fw-backup.ps1 -Setup`
  use `sudo -n` and fail. Run them **before** this step. To run one later, put the file back for that time:
  `echo 'fwadmin ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/10-fwadmin >/dev/null`, and remove it again.
- The daily backup pull keeps working. It uses its own user and its own sudo rule.

### No brief, no Claude Code on the box

```sh
sudo systemctl disable --now fleet-member.service
sudo rm -f /home/fleet/.agent/fleet/credentials/claude-oauth-token
sudo apt purge claude-code
sudo rm /etc/apt/sources.list.d/claude-code.list /etc/apt/keyrings/claude-code.asc \
        /etc/apt/apt.conf.d/52claude-code-unattended
sudo rm /etc/systemd/system/fleet-member.service && sudo systemctl daemon-reload
```

Keep the user `fleet`: `fw-brief.service` and the `fwq` tool run as that user, and `fw-report.service` starts
the brief unit after every report. Without Claude Code and without a token the brief unit mails the plain
report.
The report itself needs neither. After this, `validate.sh` ends with `RESULT: OK with warnings` and one
warning, "no Claude Code apt list found". That is expected.

### No agent at all

Nothing on the box needs an AI agent. Follow SETUP-GUIDE.md and type the commands yourself; every step is
written so that a person can do it.

## If you think the key or the token leaked

1. **SSH key:** on the box (through `mgmt0` if needed), remove the line from
   `/home/fwadmin/.ssh/authorized_keys`, add a new key, and look at `sudo journalctl -u ssh` and
   `sudo git -C /etc log` for what happened.
2. **Claude token:** revoke it in your Claude account, remove the file on the box, store a new one.
3. **Mail password:** revoke the app password at the mail provider, then run `store-mail-secret.ps1` again.
4. **DDNS token:** make a new one at the provider, then run `store-wan-secrets.ps1` again.
