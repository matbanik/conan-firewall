#!/usr/bin/env python3
"""Check that no real address, MAC address, mail address, DDNS name, private path or key is in the repository.

    python tools/scan-public.py             the files git tracks (every file, when this is not a git checkout)
    python tools/scan-public.py --staged    what the next commit holds (the pre-commit hook runs this)
    python tools/scan-public.py --tree      every file in the folder, tracked or not, except the ignored ones

Exit code 0 means no hit, 1 means hits (each printed as file:line kind value), 2 means the scan could not run.

What passes without a hit:
  IPv4    private, loopback, link-local, CGNAT and multicast ranges, the documentation ranges 192.0.2.0/24,
          198.51.100.0/24 and 203.0.113.0/24, and the benchmark range 198.18.0.0/15
  MAC     the documentation block 00:00:5e:00:53:xx
  mail    addresses at example, example.com, example.org, example.net and .invalid
  DDNS    names that start with "name." (the form the documents use for "your name here")
  path    paths on drive C or D, outside the Users folder
  and what tools/scan-allow.tsv lists by exact value (public resolvers, self-test values, provider hosts)

Your own values belong in site/<name>/, which git ignores. Python 3.8+ standard library only.
"""
import argparse
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = ROOT / "tools" / "scan-allow.tsv"

MAC = re.compile(r"(?<![0-9A-Fa-f:-])(?:[0-9A-Fa-f]{2}([:-]))(?:[0-9A-Fa-f]{2}\1){4}[0-9A-Fa-f]{2}(?![0-9A-Fa-f:-])")
IPV4 = re.compile(r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9]|\.[0-9])")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")
WINPATH = re.compile(r"(?<![A-Za-z0-9])[A-Za-z]:\\[^\s`\"'|,)*]*")
DDNS = re.compile(r"[A-Za-z0-9.-]+\.(?:asuscomm\.com|duckdns\.org|dynv6\.(?:net|com)|dedyn\.io|no-ip\.[a-z]+|ddns\.net)\b")
SECRET = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----|ssh-(?:ed25519|rsa) AAAA|\bghp_[A-Za-z0-9]{20,}|\bsk-ant-")
EXAMPLE_DOMAIN = re.compile(r"(^|\.)(example(\.(com|org|net))?|invalid)$")
OK_NETS = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
    "192.0.2.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/3")]
# --tree skips what .gitignore keeps out of the repository.
TREE_SKIP = (".git", "out", "__pycache__", ".serena", "downloads")


def die(msg):
    print("scan-public: " + msg, file=sys.stderr)
    sys.exit(2)


def load_allow():
    allow = {"ip": set(), "mac": set(), "email": set(), "host": set()}
    if not ALLOW.is_file():
        die(f"{ALLOW} is missing")
    for n, line in enumerate(ALLOW.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2 or parts[0] not in allow:
            die(f"{ALLOW.name}:{n}: needs a kind (ip, mac, email, host), a tab and a value")
        allow[parts[0]].add(parts[1].strip())
    return allow


def scan_text(text, allow):
    """-> [(line number, kind, value)]"""
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        for m in IPV4.finditer(line):
            ip = m.group(0)
            if ip in allow["ip"]:
                continue
            try:
                a = ipaddress.ip_address(ip)
            except ValueError:
                hits.append((n, "ipv4?", ip))
                continue
            if not any(a in net for net in OK_NETS):
                hits.append((n, "public-ip", ip))
        for m in MAC.finditer(line):
            mac = m.group(0).lower().replace("-", ":")
            if not mac.startswith("00:00:5e:00:53:") and mac not in allow["mac"]:
                hits.append((n, "mac", m.group(0)))
        for m in EMAIL.finditer(line):
            e = m.group(0)
            if e not in allow["email"] and not EXAMPLE_DOMAIN.search(e.rsplit("@", 1)[1].lower()):
                hits.append((n, "email", e))
        for m in WINPATH.finditer(line):
            p = m.group(0)
            if re.match(r"[a-z]:\\[ntrd0\\]", p) or len(p) < 4:
                continue  # an escape in code, not a path
            if p[0].upper() not in "CD" or p.lower().startswith("c:\\users\\"):
                hits.append((n, "winpath", p))
        for m in DDNS.finditer(line):
            h = m.group(0).strip(".")
            if h not in allow["host"] and not h.lower().startswith("name."):
                hits.append((n, "ddns", h))
        for m in SECRET.finditer(line):
            hits.append((n, "secret", m.group(0)))
    return hits


def private_path(rel):
    """Why this path must not be tracked at all, or None."""
    parts = rel.split("/")
    if parts[0] == "site" and len(parts) > 2 and parts[1] != "example":
        return "a site folder other than site/example holds a house's own values"
    if "out" in parts[:-1]:
        return "build output holds a house's own values"
    return None


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True)


def tracked():
    r = git("ls-files", "-z")
    if r.returncode != 0:
        return None
    return [p for p in r.stdout.decode("utf-8").split("\0") if p]


def staged():
    r = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    if r.returncode != 0:
        die("not a git checkout, so there is nothing staged")
    return [p for p in r.stdout.decode("utf-8").split("\0") if p]


def tree():
    out = []
    for p in sorted(ROOT.rglob("*")):
        rel = p.relative_to(ROOT).as_posix()
        parts = rel.split("/")
        if not p.is_file() or any(s in TREE_SKIP for s in parts) or p.suffix in (".pyc", ".iso"):
            continue
        if parts[0] == "site" and len(parts) > 1 and parts[1] != "example":
            continue  # a house's own values: ignored by git, and meant to hold real addresses
        out.append(rel)
    return out


def main():
    ap = argparse.ArgumentParser(description="Scan the repository for real addresses, names and keys.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--staged", action="store_true", help="scan what the next commit holds")
    g.add_argument("--tree", action="store_true", help="scan every file in the folder, tracked or not")
    args = ap.parse_args()

    allow = load_allow()
    if args.staged:
        paths, source = staged(), "staged files"
    elif args.tree:
        paths, source = tree(), "files in the folder"
    else:
        paths = tracked()
        source = "tracked files"
        if not paths:  # not a git checkout, or a copy inside another repository that tracks none of it
            paths, source = tree(), "files in the folder (git tracks none of them)"

    total = 0
    for rel in paths:
        if args.staged:
            r = git("show", ":" + rel)
            if r.returncode != 0:
                die(f"cannot read the staged copy of {rel}")
            data = r.stdout
        else:
            f = ROOT / rel
            if not f.is_file():
                continue  # tracked, and deleted in the working folder
            data = f.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            text = data.decode("latin-1")  # an image or another binary file: scan the bytes as they are
        for n, kind, value in scan_text(text, allow):
            print(f"{rel}:{n} {kind} {value}")
            total += 1
        why = private_path(rel)
        if why:
            print(f"{rel} private-path ({why})")
            total += 1

    if total:
        print(f"scan-public: {total} hit(s) in {len(paths)} {source}. Replace each with an example value "
              f"(see AGENTS.md), or list a value that is public by nature in tools/scan-allow.tsv.",
              file=sys.stderr)
        return 1
    print(f"scan-public: no hits in {len(paths)} {source}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
