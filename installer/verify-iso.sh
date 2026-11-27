#!/bin/sh
# Check the built ISO. Prints one line per check and ends with VERIFY PASS (exit 0) or VERIFY FAIL (exit 1).
#   sh verify-iso.sh KEYFILE
# KEYFILE is the same public key file that build-iso.sh got. DOWNLOADS and OUT mean the same as in build-iso.sh.
# Run on amd64 Linux or in WSL. Needs xorriso, tar, md5sum, sha256sum; debconf-set-selections for the preseed check.
#
# Checks: the boot records match the stock image's; /firewall holds exactly the expected files, each equal to
# its source, with the right modes; every md5sum in md5sum.txt is right; each boot menu has exactly one
# firewall entry; the preseed parses; the shell scripts parse; the DuckDB binary runs.
set -u
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pins.sh"
D=${DOWNLOADS:-${XDG_CACHE_HOME:-$HOME/.cache}/conan-firewall/downloads}
OUT=${OUT:-$HERE/$FIREWALL_ISO}
OVERLAY=$HERE/overlay/firewall
SRC=$D/$DEBIAN_ISO
[ $# -eq 1 ] || { echo "usage: verify-iso.sh KEYFILE" >&2; exit 2; }
KEYFILE=$1
for f in "$SRC" "$OUT" "$KEYFILE" "$D/$DUCKDB_TGZ" "$D/claude-code.asc"; do
  [ -f "$f" ] || { echo "verify-iso: not found: $f" >&2; exit 2; }
done
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
FAILS=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }

# Boot records: same El Torito and system area setup as the stock image. The image path, the image size, the
# start blocks and the GPT GUIDs change with every build, so they are left out; the sizes of the boot
# partitions are kept.
bootrep() {
  xorriso -indev "$1" -report_el_torito as_mkisofs -report_system_area plain 2>/dev/null | awk '
    /^-isohybrid-mbr / { sub(/:\047[^\047]*\047$/, ":IMAGE") }
    /^(ISO image size\/512|GPT disk GUID|GPT lba range|GPT partition GUID) *:/ { next }
    /^MBR partition +:/ { print "MBR partition", $4, $5, $6, ($4 > 1 ? $8 : "-"); next }
    /^GPT start and size *:/ { print "GPT partition size", $6, ($6 > 1 ? $8 : "-"); next }
    /^APM start and size *:/ { print "APM partition size", $6, $8; next }
    { print }'
}
bootrep "$SRC" > "$T/a"
bootrep "$OUT" > "$T/b"
if grep -q '^-e ./boot/grub/efi.img.$' "$T/a" && grep -q '^-b ./isolinux/isolinux.bin.$' "$T/a" &&
   diff "$T/a" "$T/b" > "$T/bootdiff"; then
  ok "boot records match the stock image's (BIOS and UEFI, $(wc -l < "$T/a" | tr -d ' ') report lines)"
else
  bad "boot records differ from the stock image (< stock, > built):"; cat "$T/bootdiff" 2>/dev/null
fi

mkdir "$T/iso"
xorriso -osirrox on -indev "$OUT" -extract / "$T/iso" >/dev/null 2>&1
chmod -R u+w "$T/iso"

# /firewall: the expected files, each equal to its source
mkdir "$T/want"
for f in "$OVERLAY"/*; do
  [ -f "$f" ] && cp "$f" "$T/want/"
done
cp "$KEYFILE" "$T/want/authorized_keys"
cp "$D/claude-code.asc" "$T/want/claude-code.asc"
tar -xzf "$D/$DUCKDB_TGZ" -C "$T/want" duckdb
( cd "$T/want" && ls ) > "$T/want.list"
( cd "$T/iso/firewall" 2>/dev/null && find . -mindepth 1 | sed 's|^\./||' | sort ) > "$T/have.list"
if diff "$T/want.list" "$T/have.list" > "$T/listdiff"; then
  ok "/firewall holds the $(wc -l < "$T/want.list" | tr -d ' ') expected files"
else
  bad "/firewall file list differs (< expected, > on the ISO):"; cat "$T/listdiff"
fi
n=0
for f in $(cat "$T/want.list"); do
  if cmp -s "$T/want/$f" "$T/iso/firewall/$f"; then n=$((n + 1)); else bad "/firewall/$f differs from its source"; fi
done
ok "$n files in /firewall equal their source"
xorriso -indev "$OUT" -lsl /firewall 2>/dev/null | awk '$1 ~ /^-/ { gsub(/\047/, "", $NF); print $1, $NF }' | sort -k2 > "$T/modes"
for f in $(cat "$T/want.list"); do
  case $f in
    duckdb|fw-apply|fw-confirm|late.sh|setup.sh) want=-rwxr-xr-x ;;
    *) want=-rw-r--r-- ;;
  esac
  have=$(awk -v f="$f" '$2 == f { print $1 }' "$T/modes")
  [ "$have" = "$want" ] || bad "/firewall/$f has mode $have, want $want"
done
ok "file modes checked"

if ( cd "$T/iso" && md5sum -c --quiet md5sum.txt ); then
  ok "every md5sum in md5sum.txt is right ($(grep -c ' \./firewall/' "$T/iso/md5sum.txt") lines for /firewall)"
else
  bad "md5sum.txt check"
fi
for m in boot/grub/grub.cfg isolinux/txt.cfg; do
  c=$(grep -c 'preseed/file=/cdrom/firewall/preseed.cfg' "$T/iso/$m")
  if [ "$c" = 1 ]; then ok "$m has one firewall entry"; else bad "$m has $c firewall entries, want 1"; fi
done

if command -v debconf-set-selections >/dev/null 2>&1; then
  if debconf-set-selections -c "$T/iso/firewall/preseed.cfg"; then ok "preseed.cfg parses"; else bad "preseed.cfg does not parse"; fi
else
  echo "skip  preseed.cfg parse check: debconf-set-selections not found (apt install debconf)"
fi
for f in late.sh setup.sh fw-apply fw-confirm; do
  if sh -n "$T/iso/firewall/$f"; then ok "$f parses"; else bad "$f has a syntax error"; fi
done
chmod +x "$T/iso/firewall/duckdb"
if v=$("$T/iso/firewall/duckdb" --version 2>&1); then ok "duckdb runs: $v"; else bad "duckdb does not run: $v"; fi

echo "image $OUT"
sha256sum "$OUT" | cut -d' ' -f1
if [ "$FAILS" = 0 ]; then echo "VERIFY PASS"; else echo "VERIFY FAIL ($FAILS)"; exit 1; fi
