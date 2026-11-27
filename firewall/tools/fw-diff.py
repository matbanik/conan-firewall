#!/usr/bin/env python3
"""fw-diff: differential, compressed copies of the firewall's config exports. Runs on ADMINPC; pull-fw-backup.ps1 -Weekly calls it.

  base-STAMP.tar.xz   everything. One in each calendar year.
  diff-STAMP.tar.xz   only what is new or changed since that base, and _diff.json with the names that are gone.

A restore needs one base and one diff, never a chain. Files are compared inside the export's tars, and are not unpacked to
Windows, so owners, modes, times and symlinks stay. After each write the copy is read back and compared with the export.

  fw-diff.py add fw-STAMP.tar FOLDER
  fw-diff.py restore FOLDER/diff-STAMP.tar.xz OUTDIR     writes etc.tar, usr-local.tar, ... (also takes a base)
  fw-diff.py selftest
"""
import copy
import hashlib
import io
import json
import lzma
import os
import re
import sys
import tarfile
import tempfile
from pathlib import Path

NOTE = "_diff.json"
SUMS = "SHA256SUMS"     # covers the export's own tar files; it is made again from nothing on a restore, so it is not kept
TYPES = (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE, tarfile.LNKTYPE)


class Entry:
    def __init__(self, info, data):
        if info.type not in TYPES:
            raise SystemExit(f"{info.name}: a type that this tool cannot keep")
        self.info, self.data = info, data
        # The finest times are in the pax headers as text; tarfile gives them as a float in mtime.
        self.mark = (info.type, info.mode, info.uid, info.gid, info.uname, info.gname, info.mtime, info.linkname,
                     hashlib.sha256(data).hexdigest())


def members(tar):
    for m in tar:
        yield m, tar.extractfile(m).read() if m.isreg() else b""


def read_export(path):
    """{key: Entry}. key is 'packages.tsv', or 'etc.tar/' and the name inside etc.tar."""
    out = {}
    with tarfile.open(path, "r:") as outer:
        for m, data in members(outer):
            if m.name == SUMS:
                continue
            if not m.name.endswith(".tar"):
                # These are written at each export, so their time says nothing.
                m.mtime, m.pax_headers = 0, {}
                out[m.name] = Entry(m, data)
                continue
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as inner:
                for x, d in members(inner):
                    key = f"{m.name}/{x.name}"
                    if key in out:
                        raise SystemExit(f"{key} is in the export two times")
                    out[key] = Entry(x, d)
    if not any(k.startswith("etc.tar/") for k in out):
        raise SystemExit("the export has no etc.tar")
    return out


def put(tar, name, e):
    info = copy.copy(e.info)
    info.name, info.pax_headers = name, {k: v for k, v in e.info.pax_headers.items() if k != "path"}
    info.size = len(e.data)
    tar.addfile(info, io.BytesIO(e.data))


def write_xz(path, entries, note=None):
    part = path.with_name(path.name + ".part")
    try:
        with lzma.open(part, "wb", preset=9 | lzma.PRESET_EXTREME) as f, tarfile.open(fileobj=f, mode="w", format=tarfile.PAX_FORMAT) as tar:
            if note is not None:
                info, data = tarfile.TarInfo(NOTE), json.dumps(note, indent=1).encode()
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            for k in sorted(entries):
                put(tar, k, entries[k])
        return part
    except BaseException:
        part.unlink(missing_ok=True)
        raise


def read_xz(path):
    out, note = {}, None
    with lzma.open(path) as f, tarfile.open(fileobj=f, mode="r:") as tar:
        for m, data in members(tar):
            if m.name == NOTE:
                note = json.loads(data)
            else:
                out[m.name] = Entry(m, data)
        while f.read(1 << 20):      # to the end, so that xz checks the whole file
            pass
    return out, note


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path, folder=None):
    """The whole state that one copy stands for."""
    got, note = read_xz(path)
    if note is None:
        return got
    base = (folder or path.parent) / note["base"]
    if sha(base) != note["base_sha256"]:
        raise SystemExit(f"{base.name} is not the base that {path.name} was made from")
    state, inner = read_xz(base)
    if inner is not None:
        raise SystemExit(f"{base.name} is not a base")
    for k in note["removed"]:
        del state[k]
    state.update(got)
    return state


def marks(state):
    return {k: e.mark for k, e in state.items()}


def finish(part, final, want, folder):
    """Read the new copy back. It gets its name only when it gives exactly the export."""
    try:
        if marks(load(part, folder)) != marks(want):
            raise SystemExit(f"{final.name}: read back, it is not the same as the export")
        if final.exists():
            raise SystemExit(f"{final.name} exists")
        part.replace(final)
    except BaseException:
        part.unlink(missing_ok=True)
        raise


def base_for(folder, year):
    """The newest base of this year that is still good, or None. A base that a diff does not agree with is not used."""
    for base in sorted(folder.glob(f"base-{year}????-??????.tar.xz"), reverse=True):
        try:
            state, _ = read_xz(base)
            digest = sha(base)
            for d in sorted(folder.glob("diff-*.tar.xz"), reverse=True):
                note = read_xz(d)[1]
                if note["base"] == base.name:
                    if note["base_sha256"] != digest:
                        raise ValueError("changed since its last diff")
                    break
            return base, state, digest
        except (OSError, EOFError, ValueError, TypeError, KeyError, lzma.LZMAError, tarfile.TarError) as e:
            print(f"WARNING {base.name} is damaged ({e}); a new base is made")
    return None


def add(export, folder):
    m = re.fullmatch(r"fw-((\d{4})\d{4}-\d{6})\.tar", export.name)
    if not m:
        raise SystemExit(f"not an export name: {export.name}")
    stamp, want = m[1], read_export(export)
    found = base_for(folder, m[2])
    if found is None:
        final = folder / f"base-{stamp}.tar.xz"
        finish(write_xz(final, want), final, want, folder)
        print(f"ok {final.name} {final.stat().st_size} bytes: full copy, {len(want)} entries")
        return
    base, state, digest = found
    old, new = marks(state), marks(want)
    changed = {k: e for k, e in want.items() if old.get(k) != new[k]}
    removed = sorted(k for k in old if k not in new)
    final = folder / f"diff-{stamp}.tar.xz"
    note = {"base": base.name, "base_sha256": digest, "export": export.name, "removed": removed}
    finish(write_xz(final, changed, note), final, want, folder)
    print(f"ok {final.name} {final.stat().st_size} bytes: {len(changed)} new or changed, {len(removed)} removed, against {base.name}")


def restore(path, out):
    state = load(path)
    out.mkdir(parents=True, exist_ok=True)
    groups = {}
    for k, e in state.items():
        tar, sep, name = k.partition("/")
        if sep:
            groups.setdefault(tar, {})[name] = e
        else:
            if Path(k).name != k:
                raise SystemExit(f"bad name: {k}")
            with open(out / k, "xb") as f:
                f.write(e.data)
    for tar, es in groups.items():
        if Path(tar).name != tar:
            raise SystemExit(f"bad name: {tar}")
        with tarfile.open(out / tar, "x", format=tarfile.PAX_FORMAT) as t:
            for n in sorted(es, key=lambda n: (es[n].info.islnk(), n)):   # a hard link goes after its file
                put(t, n, es[n])
    print(f"restored {len(state)} entries to {out}")


def selftest():
    def export(path, etc, loose):
        def info(name, data=b"", **kw):
            i = tarfile.TarInfo(name)
            i.size, i.mode, i.mtime = len(data), 0o640, 1700000000.25
            for k, v in kw.items():
                setattr(i, k, v)
            return i
        inner = io.BytesIO()
        with tarfile.open(fileobj=inner, mode="w", format=tarfile.PAX_FORMAT) as t:
            for n, v in etc.items():
                if isinstance(v, dict):
                    t.addfile(info(n, **v))
                else:
                    t.addfile(info(n, v, uid=7, gname="adm"), io.BytesIO(v))
        with tarfile.open(path, "w") as t:
            for n, v in {"etc.tar": inner.getvalue(), SUMS: os.urandom(8), **loose}.items():
                t.addfile(info(n, v, mtime=os.getpid()), io.BytesIO(v))

    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        f = d / "f"
        f.mkdir()
        long = "etc/" + "x" * 160
        etc = {"etc": {"type": tarfile.DIRTYPE, "mode": 0o755}, "etc/a": b"one", "etc/b": b"two", long: b"l",
               "etc/s": {"type": tarfile.SYMTYPE, "linkname": "/run/x"}, "etc/h": {"type": tarfile.LNKTYPE, "linkname": "etc/a"}}
        e1 = d / "fw-20260101-000000.tar"
        export(e1, etc, {"packages.tsv": b"p1"})
        add(e1, f)
        e2 = d / "fw-20260108-000000.tar"
        etc2 = {**etc, "etc/b": b"TWO", "etc/c": b"new", "etc/s": {"type": tarfile.SYMTYPE, "linkname": "/run/y"}}
        del etc2[long]
        export(e2, etc2, {"packages.tsv": b"p1"})
        add(e2, f)
        diff = f / "diff-20260108-000000.tar.xz"
        got, note = read_xz(diff)
        assert set(got) == {"etc.tar/etc/b", "etc.tar/etc/c", "etc.tar/etc/s"} and note["removed"] == ["etc.tar/" + long]
        restore(diff, d / "r")
        back = d / "fw-back.tar"
        with tarfile.open(back, "w") as t:
            for p in (d / "r").iterdir():
                t.add(p, arcname=p.name)
        x, y = marks(read_export(back)), marks(read_export(e2))
        assert {k: v for k, v in x.items() if "/" in k} == {k: v for k, v in y.items() if "/" in k}
        assert (d / "r" / "packages.tsv").read_bytes() == b"p1"
        # the same export again: nothing to keep; another year: a new base; the base stays untouched
        before = sha(f / "base-20260101-000000.tar.xz")
        export(d / "fw-20260115-000000.tar", etc, {"packages.tsv": b"p1"})
        add(d / "fw-20260115-000000.tar", f)
        assert read_xz(f / "diff-20260115-000000.tar.xz")[0] == {}
        e3 = d / "fw-20270105-000000.tar"
        export(e3, etc, {"packages.tsv": b"p2"})
        add(e3, f)
        assert (f / "base-20270105-000000.tar.xz").exists() and sha(f / "base-20260101-000000.tar.xz") == before
        # a damaged base is not used, and a restore from it stops
        b = f / "base-20260101-000000.tar.xz"
        b.write_bytes(b.read_bytes()[:-40])
        try:
            load(diff)
            raise AssertionError("a damaged base was accepted")
        except SystemExit:
            pass
        e4 = d / "fw-20260122-000000.tar"
        export(e4, etc, {"packages.tsv": b"p1"})
        add(e4, f)
        assert (f / "base-20260122-000000.tar.xz").exists()
        assert not list(f.glob("*.part"))
    print("fw-diff selftest ok")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["selftest"]:
        selftest()
    elif len(a) == 3 and a[0] == "add":
        add(Path(a[1]), Path(a[2]))
    elif len(a) == 3 and a[0] == "restore":
        restore(Path(a[1]), Path(a[2]))
    else:
        raise SystemExit(__doc__)
