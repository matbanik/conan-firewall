#!/bin/sh
# Build the firewall installer ISO from the stock Debian netinst image.
#   sh build-iso.sh KEYFILE
# KEYFILE holds the SSH public key(s) that may log in as fwadmin, one per line (for example
# ~/.ssh/firewall_ed25519.pub). It is copied onto the ISO as /firewall/authorized_keys. Never pass a private key.
#
# Environment:
#   DOWNLOADS  where fetch-downloads.sh put the inputs (default ~/.cache/conan-firewall/downloads)
#   OUT        the image to write (default: next to this script, name from pins.sh)
# Run on Linux or in WSL. Needs xorriso, tar, md5sum, sha256sum, awk, ssh-keygen, and what fetch-downloads.sh needs.
#
# What it does: checks the inputs again (no network), stages overlay/firewall plus the key, the DuckDB binary
# and the Claude Code apt key, adds one boot menu entry to the stock GRUB and ISOLINUX menus, rebuilds
# md5sum.txt, and writes the ISO with the original hybrid MBR/GPT and EFI boot records (replay).
set -eu
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pins.sh"
D=${DOWNLOADS:-${XDG_CACHE_HOME:-$HOME/.cache}/conan-firewall/downloads}
OUT=${OUT:-$HERE/$FIREWALL_ISO}
OVERLAY=$HERE/overlay/firewall
SRC=$D/$DEBIAN_ISO

die() { echo "build-iso: $*" >&2; exit 1; }
[ $# -eq 1 ] || { echo "usage: build-iso.sh KEYFILE   (the SSH public key file for fwadmin)" >&2; exit 2; }
KEYFILE=$1
for c in xorriso tar md5sum sha256sum awk ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found (Debian/Ubuntu: apt install xorriso openssh-client)"
done

# A public tree that was not rendered still has placeholders.
if grep -rlE '@@[A-Z][A-Z0-9_]*@@' "$OVERLAY" "$HERE/boot" >&2; then
  die "these files still have placeholders. Render the site first: python tools/render-site.py site/<name>, then run out/<name>/installer/build-iso.sh"
fi
# Windows line ends break the preseed and the shell scripts without any error message at install time.
if grep -rlI "$(printf '\r')" "$OVERLAY" "$HERE/boot" >&2; then
  die "these files have CRLF line ends. Check them out again with LF (the repo's .gitattributes sets eol=lf)."
fi
for f in authorized_keys duckdb claude-code.asc; do
  [ ! -e "$OVERLAY/$f" ] || die "$OVERLAY/$f must not exist: the build adds it from KEYFILE or the downloads"
done

[ -f "$KEYFILE" ] || die "key file not found: $KEYFILE"
if grep -q 'PRIVATE KEY' "$KEYFILE"; then
  die "$KEYFILE is a private key. Pass the .pub file."
fi
ssh-keygen -l -f "$KEYFILE" >/dev/null 2>&1 || die "$KEYFILE holds no valid SSH public key"

sh "$HERE/fetch-downloads.sh" --check

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Stage the overlay with Unix permissions (a Windows drive does not keep them)
mkdir "$T/firewall"
for f in "$OVERLAY"/*; do
  [ -f "$f" ] && cp "$f" "$T/firewall/"
done
cp "$KEYFILE" "$T/firewall/authorized_keys"
cp "$D/claude-code.asc" "$T/firewall/claude-code.asc"
tar -xzf "$D/$DUCKDB_TGZ" -C "$T/firewall" duckdb
chmod 0644 "$T"/firewall/*
chmod 0755 "$T"/firewall/duckdb "$T"/firewall/fw-apply "$T"/firewall/fw-confirm \
  "$T"/firewall/late.sh "$T"/firewall/setup.sh

# Boot menus: the stock files from the ISO plus one entry each. The stock "Install" entries stay as they are.
xorriso -osirrox on -indev "$SRC" \
  -extract /md5sum.txt "$T/md5sum.orig" \
  -extract /boot/grub/grub.cfg "$T/grub.orig" \
  -extract /isolinux/txt.cfg "$T/txt.orig" >/dev/null 2>&1 || die "cannot read the boot menus from $SRC"
chmod u+w "$T/md5sum.orig" "$T/grub.orig" "$T/txt.orig"
if grep -q 'preseed/file=/cdrom/firewall/' "$T/grub.orig" "$T/txt.orig"; then
  die "$SRC already has a firewall entry; it is not the stock image"
fi
# GRUB (UEFI): the entry goes after the first "Install" entry, which is just before the first submenu.
awk -v entry="$HERE/boot/grub-entry.cfg" '
  !done && /^submenu / { while ((getline line < entry) > 0) print line; done = 1 }
  { print }
  END { exit !done }' "$T/grub.orig" > "$T/grub.cfg" || die "no submenu line in the stock grub.cfg; the menu layout changed"
# ISOLINUX (legacy BIOS): appended after the stock "install" label.
cat "$T/txt.orig" "$HERE/boot/isolinux-entry.cfg" > "$T/txt.cfg"

# md5sum.txt: replace the changed boot files, add the overlay
grep -v -e ' \./boot/grub/grub.cfg$' -e ' \./isolinux/txt.cfg$' "$T/md5sum.orig" > "$T/md5sum.txt"
( cd "$T" && md5sum grub.cfg | sed 's| grub.cfg$| ./boot/grub/grub.cfg|' ) >> "$T/md5sum.txt"
( cd "$T" && md5sum txt.cfg  | sed 's| txt.cfg$| ./isolinux/txt.cfg|' ) >> "$T/md5sum.txt"
( cd "$T" && find firewall -type f | sort | xargs md5sum | sed 's|  firewall/|  ./firewall/|' ) >> "$T/md5sum.txt"

[ "$OUT" != "$SRC" ] || die "OUT is the source image"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
xorriso -indev "$SRC" -outdev "$OUT" \
  -map "$T/firewall" /firewall \
  -map "$T/grub.cfg" /boot/grub/grub.cfg \
  -map "$T/txt.cfg" /isolinux/txt.cfg \
  -map "$T/md5sum.txt" /md5sum.txt \
  -boot_image any replay
echo "Built $OUT"
sha256sum "$OUT"
echo "Next: sh $HERE/verify-iso.sh $KEYFILE"
