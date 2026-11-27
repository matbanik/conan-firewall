#!/usr/bin/env python3
"""Render the firewall config and the installer for one site.

    python tools/render-site.py site/<name> [--out DIR]

Copies firewall/ and installer/ into DIR (default out/<name>), lays the site's own files from
site/<name>/files/ over firewall/, and fills every placeholder (a KEY between two @@ marks) from
site/<name>/site.env. It stops with an error, and changes nothing, if a placeholder has no value, a site file
listed in tools/site-files.txt is missing, or site.env has a bad line.

A new render replaces DIR/firewall and DIR/installer, so an installer image built there goes too: build it
again from the new render. It only replaces folders that an earlier render made (DIR/.render-site marks them).

Next: build the installer from DIR/installer (installer/BUILD.md), or copy DIR/firewall to the box and run
deploy.sh there (firewall/README.md). build-iso.sh, validate.sh and deploy.sh refuse a tree that still has
placeholders. Python 3.8+ standard library only.
"""
import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(rb"@@([A-Z][A-Z0-9_]*)@@")
KEY = re.compile(r"[A-Z][A-Z0-9_]*\Z")
TREES = ("firewall", "installer")
MARK = ".render-site"
# Local build inputs and outputs that may sit in the source folders. They are never part of a render.
IGNORE = {
    "firewall": ("out",),
    "installer": ("*.iso", "downloads", "*.log", "authorized_keys", "duckdb", "claude-code.asc"),
}


def read_env(path):
    """site.env: KEY=value per line, # comments, no quoting. The value is the rest of the line as written."""
    env, errors = {}, []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        key, eq, value = line.partition("=")
        key = key.strip()
        if not eq or not KEY.match(key):
            errors.append(f"{path}:{n}: expected KEY=value")
        elif key in env:
            errors.append(f"{path}:{n}: {key} is set twice")
        elif "@@" in value:
            errors.append(f"{path}:{n}: a value cannot contain @@")
        else:
            env[key] = value.rstrip("\r")
    return env, errors


def is_text(data):
    if b"\0" in data:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def render(site, out):
    errors = []
    env_file = site / "site.env"
    if not env_file.is_file():
        sys.exit(f"render-site: {env_file} not found")
    env, errors = read_env(env_file)
    files = site / "files"
    listed = ROOT / "tools" / "site-files.txt"
    required = []
    if listed.is_file():
        required = [s.strip() for s in listed.read_text(encoding="utf-8").splitlines()
                    if s.strip() and not s.lstrip().startswith("#")]
    for rel in required:
        if not (files / rel).is_file():
            errors.append(f"site file missing: {files / rel} (see tools/site-files.txt)")
    if errors:
        sys.exit("render-site:\n  " + "\n  ".join(errors))

    old = [t for t in TREES if (out / t).exists()]
    if old and not (out / MARK).is_file():
        sys.exit(f"render-site: {out} already has {' and '.join(old)}, and no earlier render made them "
                 f"({MARK} is missing). Use another --out, or remove them yourself.")

    stage = Path(tempfile.mkdtemp(prefix="render-", dir=out.parent if out.parent.exists() else None))
    try:
        for t in TREES:
            shutil.copytree(ROOT / t, stage / t, ignore=shutil.ignore_patterns(*IGNORE[t]))
        if files.is_dir():
            shutil.copytree(files, stage / "firewall", dirs_exist_ok=True)
        used, missing = set(), {}
        for p in sorted(stage.rglob("*")):
            if not p.is_file():
                continue
            data = p.read_bytes()
            if not is_text(data) or b"@@" not in data:
                continue

            def fill(m):
                k = m.group(1).decode()
                if k in env:
                    used.add(k)
                    return env[k].encode("utf-8")
                missing.setdefault(k, set()).add(p.relative_to(stage).as_posix())
                return m.group(0)

            new = TOKEN.sub(fill, data)
            if new != data:
                p.write_bytes(new)
        if missing:
            lines = [f"{k}: {', '.join(sorted(v))}" for k, v in sorted(missing.items())]
            sys.exit(f"render-site: no value in {env_file} for:\n  " + "\n  ".join(lines))
        left = [p.relative_to(stage).as_posix() for p in stage.rglob("*")
                if p.is_file() and is_text(p.read_bytes()) and TOKEN.search(p.read_bytes())]
        if left:
            sys.exit("render-site: placeholders left in:\n  " + "\n  ".join(left))
        out.mkdir(parents=True, exist_ok=True)
        (out / MARK).write_text("Made by tools/render-site.py. The next render replaces firewall/ and "
                                "installer/ in this folder.\n", encoding="utf-8")
        for t in TREES:
            if (out / t).exists():
                shutil.rmtree(out / t)
            shutil.move(str(stage / t), str(out / t))
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    unused = sorted(set(env) - used)
    if unused:
        print("render-site: note, not used by any file: " + ", ".join(unused), file=sys.stderr)
    print("render-site: " + " and ".join(str(out / t) for t in TREES))


def main():
    ap = argparse.ArgumentParser(description="Fill the firewall config and the installer with one site's values.")
    ap.add_argument("site", type=Path, help="site directory, e.g. site/example")
    ap.add_argument("--out", type=Path, help="output directory for this site (default out/<site name>); "
                                             "firewall/ and installer/ are written inside it")
    a = ap.parse_args()
    site = a.site.resolve()
    out = (a.out or ROOT / "out" / site.name).resolve()
    sources = [(ROOT / t).resolve() for t in TREES]
    if out == ROOT or any(out == s or s in out.parents for s in sources):
        sys.exit("render-site: --out must not be the repo folder, firewall/ or installer/, or inside the last two")
    render(site, out)


if __name__ == "__main__":
    main()
