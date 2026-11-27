# Pinned build inputs. fetch-downloads.sh, build-iso.sh and verify-iso.sh read this file.
# To move to a newer release, change a version and its hash here, in one commit, after you have checked the new
# hash against the publisher's own page. BUILD.md ("Change a pinned input") gives the steps.

# Debian netinst image. The archive URL keeps old point releases; "current" only has the newest one.
DEBIAN_VERSION=13.7.0
DEBIAN_ISO=debian-$DEBIAN_VERSION-amd64-netinst.iso
DEBIAN_ISO_SHA256=a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355
DEBIAN_URLS="https://cdimage.debian.org/cdimage/archive/$DEBIAN_VERSION/amd64/iso-cd https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
# "Debian CD signing key", listed at https://www.debian.org/CD/verify. It signs SHA256SUMS.
DEBIAN_CD_KEY_FPR=DF9B9C49EAA9298432589D76DA87E80D6294BE9B
DEBIAN_CD_KEY_URL="https://keyring.debian.org/pks/lookup?op=get&search=0x$DEBIAN_CD_KEY_FPR"

# DuckDB CLI (Debian has no package). DuckDB signs nothing, so the hash here is the only check.
DUCKDB_VERSION=v2.0.0
DUCKDB_TGZ=duckdb-cli-$DUCKDB_VERSION-linux-amd64.tar.gz
DUCKDB_TGZ_SHA256=c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc
DUCKDB_URL=https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION/duckdb-cli-linux-amd64.tar.gz

# Claude Code apt signing key. The fingerprint is on https://code.claude.com/docs/en/setup. The key file can be
# exported again by its owner, so the check is the fingerprint, not a file hash.
CLAUDE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
CLAUDE_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE

# The image that build-iso.sh writes.
FIREWALL_ISO=debian-$DEBIAN_VERSION-amd64-firewall.iso
