#!/bin/sh
# Fetch the build inputs and check each one. Nothing here is kept in git.
#   sh fetch-downloads.sh            download what is missing, then check everything
#   sh fetch-downloads.sh --check    check only; no network; fails if a file is missing
# Files go to $DOWNLOADS (default ~/.cache/conan-firewall/downloads). A file that already passes its check
# is not downloaded again. Run on Linux or in WSL. Needs curl, gpg and sha256sum.
#
# Checks (pins are in pins.sh):
#   Debian netinst ISO   SHA-256 pinned here, and the same hash must be in SHA256SUMS, and SHA256SUMS must
#                        carry a good signature from the pinned Debian CD signing key
#   DuckDB CLI tarball   SHA-256 pinned here
#   Claude Code apt key  the file must hold exactly one key, with the pinned fingerprint
# Any failed check stops the script with exit 1. Do not work around a failed check: find out why first.
set -eu
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/pins.sh"
D=${DOWNLOADS:-${XDG_CACHE_HOME:-$HOME/.cache}/conan-firewall/downloads}
CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) echo "usage: fetch-downloads.sh [--check]" >&2; exit 2 ;;
esac

die() { echo "fetch-downloads: $*" >&2; exit 1; }
for c in curl gpg sha256sum awk; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found (Debian/Ubuntu: apt install curl gnupg coreutils)"
done
mkdir -p "$D"
G=$(mktemp -d)
trap 'rm -rf "$G"' EXIT
chmod 700 "$G"

sha() { sha256sum "$1" | cut -d' ' -f1; }
# A progress bar on a terminal; only errors in a log or an agent's tool output
if [ -t 2 ]; then PROGRESS=--progress-bar; else PROGRESS=-sS; fi

# get URL FILE: download to FILE. A failed download leaves no FILE.
get() {
  [ "$CHECK" = 0 ] || die "$(basename "$2") is missing or failed its check. Run fetch-downloads.sh without --check."
  echo "  fetching $1"
  if curl -fL --retry 3 --connect-timeout 20 $PROGRESS -o "$2.part" "$1"; then
    mv -f "$2.part" "$2"
  else
    rm -f "$2.part"
    return 1
  fi
}

# pinned FILE SHA256 URL: keep a file that has the pinned hash, otherwise download it and check it.
pinned() {
  if [ -f "$1" ] && [ "$(sha "$1")" = "$2" ]; then
    return 0
  fi
  get "$3" "$1" || die "download failed: $3"
  got=$(sha "$1")
  if [ "$got" != "$2" ]; then
    mv -f "$1" "$1.bad"
    die "SHA-256 mismatch for $(basename "$1"): want $2, got $got. Kept as $1.bad for a look; do not use it."
  fi
}

# ---------- Debian: signed SHA256SUMS, then the ISO
SUMS=$D/debian-$DEBIAN_VERSION-SHA256SUMS
SIGN=$SUMS.sign
KEY=$D/debian-cd-key-$DEBIAN_CD_KEY_FPR.asc
ISO=$D/$DEBIAN_ISO

lists_iso() { [ -f "$SUMS" ] && [ -f "$SIGN" ] && grep -q "  $DEBIAN_ISO\$" "$SUMS"; }
BASE=
if ! lists_iso; then
  for b in $DEBIAN_URLS; do
    if get "$b/SHA256SUMS" "$SUMS" && get "$b/SHA256SUMS.sign" "$SIGN" && lists_iso; then
      BASE=$b
      break
    fi
  done
  [ -n "$BASE" ] || die "no Debian mirror path lists $DEBIAN_ISO (tried: $DEBIAN_URLS)"
fi
[ -f "$KEY" ] || get "$DEBIAN_CD_KEY_URL" "$KEY" || die "download failed: $DEBIAN_CD_KEY_URL"

# A good signature is not enough: it must come from the pinned key. VALIDSIG ends with the primary key fingerprint.
gpg --homedir "$G" --batch --quiet --import "$KEY" 2>/dev/null || die "cannot import $KEY"
gpg --homedir "$G" --batch --status-fd 1 --verify "$SIGN" "$SUMS" 2>/dev/null |
  awk -v f="$DEBIAN_CD_KEY_FPR" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == f { ok = 1 } END { exit !ok }' ||
  die "SHA256SUMS is not signed by the Debian CD key $DEBIAN_CD_KEY_FPR. Stop and find out why."
echo "ok  SHA256SUMS: good signature from Debian CD key $DEBIAN_CD_KEY_FPR"

grep -qx "$DEBIAN_ISO_SHA256  $DEBIAN_ISO" "$SUMS" ||
  die "the signed SHA256SUMS has a different hash for $DEBIAN_ISO than pins.sh. Stop and find out why."
if [ ! -f "$ISO" ] || [ "$(sha "$ISO")" != "$DEBIAN_ISO_SHA256" ]; then
  ok=0
  for b in ${BASE:-$DEBIAN_URLS}; do
    if get "$b/$DEBIAN_ISO" "$ISO"; then
      ok=1
      break
    fi
  done
  [ "$ok" = 1 ] || die "download failed: $DEBIAN_ISO"
  got=$(sha "$ISO")
  if [ "$got" != "$DEBIAN_ISO_SHA256" ]; then
    mv -f "$ISO" "$ISO.bad"
    die "SHA-256 mismatch for $DEBIAN_ISO: want $DEBIAN_ISO_SHA256, got $got. Kept as $ISO.bad; do not use it."
  fi
fi
echo "ok  $DEBIAN_ISO: SHA-256 matches pins.sh and the signed SHA256SUMS"

# ---------- DuckDB
pinned "$D/$DUCKDB_TGZ" "$DUCKDB_TGZ_SHA256" "$DUCKDB_URL"
echo "ok  $DUCKDB_TGZ: SHA-256 matches pins.sh"

# ---------- Claude Code apt key
CK=$D/claude-code.asc
key_fprs() { gpg --homedir "$G" --batch --show-keys --with-colons "$1" 2>/dev/null |
  awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }'; }
if [ ! -f "$CK" ] || [ "$(key_fprs "$CK")" != "$CLAUDE_KEY_FPR" ]; then
  get "$CLAUDE_KEY_URL" "$CK" || die "download failed: $CLAUDE_KEY_URL"
fi
got=$(key_fprs "$CK")
if [ "$got" != "$CLAUDE_KEY_FPR" ]; then
  mv -f "$CK" "$CK.bad"
  die "claude-code.asc does not hold exactly the key $CLAUDE_KEY_FPR (found: $(echo $got)). Kept as $CK.bad; do not use it."
fi
echo "ok  claude-code.asc: one key, fingerprint $CLAUDE_KEY_FPR"

echo "All build inputs are present and checked in $D"
