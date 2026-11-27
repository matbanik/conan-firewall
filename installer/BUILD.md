# Build the installer image

Instructions for an AI agent (or a person) who builds the firewall installer for one house. This repository
does not ship a built image, a Debian ISO, a binary or a key. You build the image yourself from the stock
Debian netinst ISO, and every download is checked before it is used.

The result is one file, `debian-13.7.0-amd64-firewall.iso`. Written to a USB stick, it installs Debian 13 on the
firewall machine with three questions on the screen, and leaves a box that you can reach over SSH with your key.
[INSTALL.md](INSTALL.md) covers the install itself.

## Rules for the agent

1. **Never get around a failed check.** If `fetch-downloads.sh`, `build-iso.sh` or `verify-iso.sh` stops with
   an error, read the message, find the cause and tell the person. Do not edit a hash or a fingerprint in
   `pins.sh` to make a check pass. "Change a pinned input" below is the only way to change one.
2. **Never read, copy or ask for a private key.** The build takes the *public* key file (`.pub`). The person
   makes the key pair; you only receive the path of the `.pub` file.
3. **The person writes the USB stick, not you.** Writing to the wrong disk destroys it. Give the person the
   command and let them pick the disk and confirm it.
4. **Commit nothing that the build makes or downloads.** The ISO, the downloads, the DuckDB binary and the key
   stay out of git. `installer/.gitignore` and the root `.gitignore` already cover them.
5. **Change files in `installer/`, not in `out/`.** `out/<name>/` is a rendered copy; the next render
   replaces it.
6. Ask the person before you install packages on their computer (`apt install ...`).

## What you need

| Need | Detail |
|---|---|
| A Linux shell on amd64 | Debian, Ubuntu, or WSL on Windows. The verify step runs the DuckDB Linux binary, so it must be amd64 |
| Packages | `xorriso curl gnupg coreutils tar openssh-client python3`, and `debconf` for the preseed check (it is already there on Debian and Ubuntu). Install: `sudo apt install xorriso curl gnupg openssh-client python3` |
| Disk space | About 2 GB (the Debian ISO is 760 MB, the built image 830 MB) |
| Network | For `fetch-downloads.sh` only. The build and the verify step work offline |
| A USB stick | 1 GB or larger. Everything on it is erased |
| The firewall machine | The build is set for a Lenovo ThinkCentre M920q with an NVMe drive. For another machine see "Other hardware" |

On Windows, run every `sh` and `python` command below inside WSL. The repository can stay on the Windows drive
(`/mnt/c/...`): the build sets the Unix file permissions itself.

## Steps

All commands run from the repository root. `<name>` is the name of your site folder.

### 1. Site values

Copy `site/example/` to `site/<name>/` if that is not done yet, and set the installer keys in
`site/<name>/site.env`:

| Key | What it sets | How to choose |
|---|---|---|
| `ETC_GIT_NAME`, `ETC_GIT_EMAIL` | The author of the commits that etckeeper makes of `/etc` on the box | Any name and address, one word each, no spaces. They never leave the box unless you push `/etc` somewhere |
| `TIME_ZONE` | The time zone of the box | A name from `/usr/share/zoneinfo`, for example `Europe/Berlin`. Reports and the log database use local time |
| `INSTALL_DISK` | The disk that the installer erases and installs to | `/dev/nvme0n1` for an NVMe drive, usually `/dev/sda` for a SATA drive |
| `HW_MODEL_FILE`, `HW_MODEL_REGEX` | The safety guard: the automated install only starts on a machine whose model text matches | See "Other hardware". Keep the defaults for an M920q, M920x or M720q |

The other keys in `site.env` belong to the firewall configuration. The render needs a value for every key, but
only the six above reach the installer image.

### 2. The SSH key (the person does this)

The box accepts SSH logins with a key only, for the user `fwadmin` only. The person makes a key pair on the
computer that will manage the firewall, and protects it with a passphrase:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/firewall_ed25519 -C firewall
```

The build needs the path of the public file, `~/.ssh/firewall_ed25519.pub`. The file may hold more than one
public key, one per line. The private file never leaves that computer.

### 3. Render

```sh
python3 tools/render-site.py site/<name>
```

This writes `out/<name>/firewall/` and `out/<name>/installer/` with your values filled in. Run the next steps
from `out/<name>/installer/`. `build-iso.sh` refuses a tree that still has placeholders.

### 4. Fetch and check the inputs

```sh
sh out/<name>/installer/fetch-downloads.sh
```

It downloads three files to `~/.cache/conan-firewall/downloads` (set `DOWNLOADS` to use another folder) and
checks each one. A file that already passes its check is not downloaded again.

| File | Check |
|---|---|
| Debian netinst ISO | Its SHA-256 equals the pin in `pins.sh` **and** the entry in Debian's `SHA256SUMS`, and `SHA256SUMS` carries a good signature from the pinned Debian CD signing key |
| DuckDB CLI tarball | Its SHA-256 equals the pin in `pins.sh`. DuckDB signs nothing, so this is the only check |
| Claude Code apt key | The file holds exactly one key, with the pinned fingerprint |

Success looks like this (four `ok` lines):

```
ok  SHA256SUMS: good signature from Debian CD key DF9B9C49EAA9298432589D76DA87E80D6294BE9B
ok  debian-13.7.0-amd64-netinst.iso: SHA-256 matches pins.sh and the signed SHA256SUMS
ok  duckdb-cli-v2.0.0-linux-amd64.tar.gz: SHA-256 matches pins.sh
ok  claude-code.asc: one key, fingerprint 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
All build inputs are present and checked in ...
```

### 5. Build

```sh
sh out/<name>/installer/build-iso.sh ~/.ssh/firewall_ed25519.pub
```

It checks the inputs again without the network, then adds a `/firewall` folder and one boot menu entry to the
stock image. The stock "Install" entries stay as they are. The image is written next to the script:
`out/<name>/installer/debian-13.7.0-amd64-firewall.iso` (set `OUT` to write it somewhere else).

What goes into `/firewall`:

| File | From | Purpose |
|---|---|---|
| `preseed.cfg` | `overlay/firewall/` | The answers for the Debian installer |
| `late.sh`, `setup.sh` | `overlay/firewall/` | The bootstrap that runs at the end of the install |
| `bench.nft` | `overlay/firewall/` | The first ruleset: SSH and ping from private addresses, nothing forwarded |
| `fw-apply`, `fw-confirm` | `overlay/firewall/` | Rule changes with automatic rollback |
| `sshd-firewall.conf` | `overlay/firewall/` | SSH: keys only, `fwadmin` only |
| `fleet-member.service` | `overlay/firewall/` | The unit for an agent fleet; inactive unless you set one up (see `agent/README.md`) |
| `authorized_keys` | Your `.pub` file | Who may log in as `fwadmin` |
| `duckdb` | The checked tarball | DuckDB CLI for the log database (Debian has no package) |
| `claude-code.asc` | The checked download | The signing key of the Claude Code apt repository |

### 6. Verify

```sh
sh out/<name>/installer/verify-iso.sh ~/.ssh/firewall_ed25519.pub
```

It must end with `VERIFY PASS`. It checks that the boot records match the stock image's (legacy BIOS and
UEFI), that `/firewall` holds exactly the expected files and each one equals its source, the file modes, every
line of `md5sum.txt`, that each boot menu has one firewall entry, that the preseed and the shell scripts
parse, and that the DuckDB binary runs. With `VERIFY FAIL`, do not write the image to a stick.

The SHA-256 of the image is different on every build, because the build writes new partition IDs and times.
So there is no published hash to compare with; `verify-iso.sh` is the check.

### 7. Write the USB stick (the person does this)

Windows, from an elevated prompt. `Get-Disk` shows the disk number of the stick (BusType `USB`):

```powershell
Get-Disk
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\out\<name>\installer\write-usb.ps1 -DiskNumber N
```

`write-usb.ps1` refuses a disk that is not USB, a boot or system disk, and a disk of 256 GB or more. It asks
the person to type the disk number again, writes the image, reads it back and compares the SHA-256. It takes
the image next to the script; if the repository is inside the WSL file system, copy the image to a Windows
folder and pass `-IsoPath`.

Linux. `lsblk` shows the stick (TRAN `usb`); `sdX` is the whole disk, not a partition:

```sh
lsblk -o NAME,SIZE,TRAN,MODEL
sudo dd if=out/<name>/installer/debian-13.7.0-amd64-firewall.iso of=/dev/sdX bs=4M conv=fsync status=progress
sudo cmp -n "$(stat -c %s out/<name>/installer/debian-13.7.0-amd64-firewall.iso)" \
  out/<name>/installer/debian-13.7.0-amd64-firewall.iso /dev/sdX && echo "USB equals the image"
```

Then go to [INSTALL.md](INSTALL.md).

## What the image always does

These are not settings today. To change one, edit the file in `installer/` and build again.

| Fixed | Where |
|---|---|
| Host name `firewall`, domain `lan`, locale `en_US.UTF-8`, keymap `us` | `overlay/firewall/preseed.cfg` and both files in `boot/` |
| Admin user `fwadmin`, no root login | `overlay/firewall/preseed.cfg`, `sshd-firewall.conf`, `setup.sh` |
| `fwadmin` has sudo **without a password**, so an agent can manage the box over SSH | `setup.sh`. To make sudo ask, remove `/etc/sudoers.d/10-fwadmin` on the box after the install |
| Claude Code is installed from its signed apt repository, and a `fleet` user (no sudo, no SSH login) is made for analysis jobs. The unit stays inactive (see `agent/README.md`) | `setup.sh`, `fleet-member.service` |
| The boot menu entry says "ERASES NVMe drive", and the guard's refusal name mentions the ThinkCentre | `boot/*.cfg`, `overlay/firewall/preseed.cfg`. Text only; the disk that is erased is `INSTALL_DISK` |

## Other hardware

The automated install is tested on a ThinkCentre M920q only. For another machine:

1. **Guard.** On that machine, boot any Linux and read `/sys/class/dmi/id/product_name` and
   `/sys/class/dmi/id/product_version`. Put the file that names the model in `HW_MODEL_FILE` and a pattern for
   it in `HW_MODEL_REGEX` (`grep -iE` syntax, no single quote). Lenovo puts the model name in
   `product_version`; most other makers use `product_name`. Do not use a pattern that matches everything: the
   guard is what keeps this stick from erasing another computer that boots from it.
2. **Disk.** Set `INSTALL_DISK`.
3. **Network port names.** `setup.sh` writes DHCP stanzas for `eno1` and `eno2`, because the M920q's onboard
   port has one of those names. The installer also configures the port it used, whatever its name is, so
   other machines still come up on that port.
4. **Microcode.** The package list in `preseed.cfg` has `intel-microcode`. On an AMD machine change it to
   `amd64-microcode`.
5. Build, verify and install on a machine whose disk may be erased. Read `/var/log/firewall-bootstrap.log`
   after the first boot.

The firewall configuration in `firewall/` assumes five network ports (one onboard, four on a card). That is a
separate matter from this installer; `firewall/README.md` covers it.

## Change a pinned input

Do this when Debian publishes a new point release or you want a newer DuckDB. One commit per change.

- **Debian.** Read the new `SHA256SUMS` from `https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/` and
  check the fingerprint of the signing key against `https://www.debian.org/CD/verify`. In `pins.sh` set
  `DEBIAN_VERSION` and `DEBIAN_ISO_SHA256`. Change `DEBIAN_CD_KEY_FPR` only if Debian's page lists a new key.
  Also change the default image name in `write-usb.ps1`, or pass `-IsoPath`.
- **DuckDB.** Take the release from `https://github.com/duckdb/duckdb/releases`. Download
  `duckdb-cli-linux-amd64.tar.gz` twice, over two different networks if you can, and compare the SHA-256.
  Set `DUCKDB_VERSION` and `DUCKDB_TGZ_SHA256`.
- **Claude Code key.** Change `CLAUDE_KEY_FPR` only when `https://code.claude.com/docs/en/setup` shows a new
  fingerprint.

Then run steps 3 to 6 again. `build-iso.sh` stops if the boot menu layout of the new Debian image differs from
what it expects; then compare `boot/grub-entry.cfg` and `boot/isolinux-entry.cfg` with the stock menus.

## When something fails

| Message | Cause and fix |
|---|---|
| `these files still have placeholders` | You ran the script in `installer/` of the public tree. Render first (step 3) and run the copy in `out/<name>/installer/` |
| `these files have CRLF line ends` | Git changed the line ends on Windows. The repository's `.gitattributes` sets LF: run `git add --renormalize .` or clone again without `core.autocrlf` |
| `is missing or failed its check. Run fetch-downloads.sh without --check` | Step 4 was not run, or `DOWNLOADS` points to another folder than in step 4 |
| `SHA256SUMS is not signed by the Debian CD key` | Stop. A wrong or changed signing key, or a tampered download. Compare with `https://www.debian.org/CD/verify` |
| `SHA-256 mismatch for ...` | A broken download, or the publisher replaced the file. The bad file is kept with `.bad` at the end. Run step 4 again; if it fails again, stop and find out why |
| `no Debian mirror path lists debian-...-netinst.iso` | The network is down, or Debian moved the file. `pins.sh` lists the archive path first and then `current` |
| `claude-code.asc does not hold exactly the key` | Stop. Compare the fingerprint with `https://code.claude.com/docs/en/setup` |
| `... is a private key. Pass the .pub file` | Pass the public key file |
| `already has a firewall entry; it is not the stock image` | The file in the downloads folder is not the stock ISO. Delete it and run step 4 again |
| `no submenu line in the stock grub.cfg` | The new Debian image has a different boot menu. See "Change a pinned input" |
| `VERIFY FAIL` | The lines that start with `FAIL` say which check. Do not use the image |
| `render-site: ... already has firewall and installer, and no earlier render made them` | The `--out` folder holds something that the tool did not make. Choose another folder |
