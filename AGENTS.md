# Instructions for an AI agent

You are helping a person build a home firewall from this repository. The person may not be a network
engineer. You do the reading, the file edits and the checks. The person makes the decisions, holds the secrets
and touches the hardware.

## What to do first

1. Read [README.md](README.md) (what this is), [docs/features.md](docs/features.md) (what it does and its
   limits), [docs/before-you-start.md](docs/before-you-start.md) (what the person needs) and
   [SETUP-QUESTIONS.md](SETUP-QUESTIONS.md).
2. Look for `site/` folders other than `site/example/`.
   - None: this is a new setup. Start the interview in SETUP-QUESTIONS.md, block A.
   - One exists: read its `site.env` and its `PROGRESS.md`, tell the person where the setup stands, and go on
     from there.
3. Follow [SETUP-GUIDE.md](SETUP-GUIDE.md) one stage at a time. After each stage, write one line to
   `site/<name>/PROGRESS.md`: the date, the stage, the result.

Do not start with the installer, and do not deploy anything, before the interview is done.

## Reading order

| When | Read |
|---|---|
| Always | This file, `SETUP-QUESTIONS.md`, `SETUP-GUIDE.md` |
| Before you build the image | `installer/BUILD.md` |
| Before the install | `installer/INSTALL.md` |
| Before your first SSH login | `agent/README.md` |
| Before `validate.sh` or `deploy.sh` | `firewall/README.md` |
| After each deploy | `firewall/SERVICES.md` |
| Before you store or discuss a secret | `firewall/SECRETS.md` |
| Before the cutover day | `firewall/CUTOVER.md`, `firewall/MAPPING.md`, `docs/design-decisions.md` |

## Rules

These rules hold even when the person asks for a shortcut. Explain the reason and offer the safe way.

### Decisions

1. **Ask, do not guess.** Every value in `site.env` comes from the person or from a command whose output you
   show them. When the person does not know, use the fail-safe default from SETUP-QUESTIONS.md and say that you
   did.
2. **Stop when the questionnaire says stop.** Some answers mean that this tree does not fit without real
   changes (fewer than three network ports, PPPoE, VLANs). Say so plainly. Do not improvise a router
   configuration.
3. **One change at a time on the box.** State what you will run and what it changes before you run it.

### Secrets

4. **Never ask for, read, print or store a password, a token or a private key.** The person runs the
   `store-*.ps1` scripts and types the secret into the prompt. You only receive the path of a public key file.
5. **Never read `/etc/wan-event/`, `/etc/credstore.encrypted/` or `/etc/shadow` on the box**, and never copy an
   export that holds them to another machine.
6. **The person's values stay out of git.** `site/<name>/` and `out/` are ignored. Never add them with
   `git add -f`. Never paste a real public address, MAC address or host name into a tracked file, an issue or a
   web search. Run `python3 tools/scan-public.py --tree` before `git add` (it reads every file in the folder,
   tracked or not), and install the hook once with `sh tools/hooks/install.sh`: it checks what each commit holds.

### The firewall

7. **Never add a port forward without a source address.** If the person cannot name the outside address, the
   answer is no forward. Suggest a VPN or a relay service instead.
8. **Never enable UPnP, never open SSH to the internet, never turn the firewall off "to test".**
9. **Deploy only with `deploy.sh`, and change rules only with `fw-apply`.** Both undo themselves when nobody
   confirms. Do not edit `/etc/nftables.conf` on the box by hand, and do not run `nft flush ruleset`.
10. **Confirm a deploy only after the checks in `firewall/SERVICES.md` pass**, and only from a new SSH session
    that you opened after the reboot. A confirm from an old session proves nothing.
11. **Never get around a failed check.** `validate.sh`, `fetch-downloads.sh`, `build-iso.sh` and
    `verify-iso.sh` stop for a reason. Find the cause. Do not edit a pinned hash, and do not comment out a test.
12. **Edit files in `firewall/`, `installer/` and `site/<name>/`, never in `out/`.** The next render replaces
    `out/`. After an edit: render, copy to the box, validate.

### The hardware and the house

13. **The person writes the USB stick and moves the cables.** Give the command and wait.
14. **Never test on the house network without saying what can break.** The bench profile runs a DHCP server on
    its LAN port `trunk0`: that port must never be cabled to the house switch. The rescue port `mgmt0` answers
    DHCP in both profiles: it takes one laptop, never the house LAN.
15. **The cutover needs a date, a rollback and the person in the room.** Do not start it because the checks
    are green. See `firewall/CUTOVER.md`.

## How the files fit together

```
site/<name>/site.env  ─┐
site/<name>/files/    ─┼─ python3 tools/render-site.py site/<name> ─► out/<name>/firewall/   (copy to the box)
firewall/ installer/  ─┘                                              out/<name>/installer/  (build the image)
```

- A value like `@@LAN_PREFIX@@` in a file is a placeholder. The render fills it from `site.env`. The scripts
  refuse to run on files that still have one.
- `firewall/common/` is laid out as on the box: `common/etc/nftables.conf` becomes `/etc/nftables.conf`.
  `firewall/profiles/bench/` and `firewall/profiles/prod/` add the files that differ.
- On the box, the working copy is `~/firewall-config` (the rendered `firewall/` folder).

## What you can and cannot do on the box

`agent/README.md` has the details. In short: you log in as `fwadmin` with the person's SSH key. Whether `sudo`
needs the person's password is their choice (block I). If it does, give the person each `sudo` command and
read the output they paste back.

## When something goes wrong

- A failed deploy reverts by itself after 15 minutes. Do not fight it. Read
  `journalctl -t fw-deploy -b -1` after the box is back.
- If SSH is lost: the person cables a laptop to `mgmt0` and uses `ssh fwadmin@10.255.255.1`.
- If you are not sure whether a step is safe, it is not. Stop and ask.

## Working on this repository itself

- Shell scripts are POSIX `sh` and run on Debian. Python is the standard library only. Line ends are LF.
- Keep comments and documents in plain, short sentences.
- Run `python3 tools/scan-public.py --tree` before a commit. Example values only: `192.168.50.x`, the TEST-NET ranges
  for public addresses (`203.0.113.0/24`), MACs from `00:00:5e:00:53:xx`, names under `home.example`.
