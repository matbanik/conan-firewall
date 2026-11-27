#!/usr/bin/env python3
"""Run one analysis session with claude -p on the firewall's fleet member. A fleet ``run`` task starts it in the slot.

``ask`` reads ``brief.md`` (and an optional ``job.json``) from the slot root, runs ``claude -p`` in WORK and prints
the answer. ``selftest`` checks the tools, the log access, ``fwq`` and a short ``claude -p`` call.

The session history stays in ~/.claude/projects on this machine, and each run's record in WORK/runs. Only the
printed answer goes back: the task's log travels to the hub, so the token's bytes are removed from it.
The token file is read here and passed to claude in its environment only. CLAUDE_CODE_SUBPROCESS_ENV_SCRUB keeps it
out of the commands Claude runs.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SLOT = Path(__file__).resolve().parents[1]
WORK = Path(os.environ.get("FW_ANALYSIS_DIR") or "/var/lib/fw-analysis")
LOG_DIR = "/var/log"
REMOVED_ENV = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
REDACTED = "[redacted]"
# Files in WORK that would change how Claude runs. They are removed before each run, and Claude may not write them.
CONTROL_FILES = (".claude", ".mcp.json", "CLAUDE.md", "CLAUDE.local.md")
ALLOWED_TOOLS = (
    "Read(./**)", f"Read(/{LOG_DIR}/**)",
    "Bash(fwq:*)",
    "Write(./reports/**)", "Edit(./reports/**)", "Write(./notes/**)", "Edit(./notes/**)",
    "TodoWrite",
)
DISALLOWED_TOOLS = ("WebFetch", "WebSearch") + tuple(
    f"{tool}(./{name}{'/**' if name == '.claude' else ''})" for tool in ("Write", "Edit") for name in CONTROL_FILES
)
JOB_KEYS = {"resume", "model", "max_turns", "max_seconds"}
DEFAULT_MAX_TURNS = 40
DEFAULT_MAX_SECONDS = 1500
SESSION_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
MODEL_RE = re.compile(r"^[A-Za-z0-9._\-\[\]]{1,64}$")
KILL_GRACE_S = 10


class JobRefusal(Exception):
    pass


def fleet_home() -> Path:
    return Path(os.environ.get("FLEET_HOME") or Path.home() / ".agent" / "fleet")


def read_token() -> str:
    path = fleet_home() / "credentials" / "claude-oauth-token"
    try:
        token = path.read_text(encoding="utf-8-sig").strip()
    except (OSError, ValueError):
        token = ""
    if not token:
        raise JobRefusal("token_missing: run store-claude-token.ps1 on the orchestrator machine")
    return token


def read_job() -> dict:
    """job.json from the slot root, checked. Missing means defaults."""
    path = SLOT / "job.json"
    if not path.is_file():
        return {}
    try:
        job = json.loads(path.read_text(encoding="utf-8-sig"))
    except ValueError as e:
        raise JobRefusal(f"job_invalid: {e}") from None
    if not isinstance(job, dict) or set(job) - JOB_KEYS:
        raise JobRefusal(f"job_invalid: keys allowed are {sorted(JOB_KEYS)}")
    if "resume" in job and not (isinstance(job["resume"], str) and SESSION_RE.fullmatch(job["resume"])):
        raise JobRefusal("job_invalid: resume is a session id")
    if "model" in job and not (isinstance(job["model"], str) and MODEL_RE.fullmatch(job["model"])):
        raise JobRefusal("job_invalid: model")
    for key, low, high in (("max_turns", 1, 200), ("max_seconds", 60, 21600)):
        if key in job and not (type(job[key]) is int and low <= job[key] <= high):
            raise JobRefusal(f"job_invalid: {key} is a whole number from {low} to {high}")
    return job


def prepare_work() -> None:
    for name in ("reports", "notes", "runs"):
        (WORK / name).mkdir(parents=True, exist_ok=True)
    for name in CONTROL_FILES:
        path = WORK / name
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif path.exists() or path.is_symlink():
            path.unlink()


def claude_env(token: str) -> dict:
    env = {name: value for name, value in os.environ.items() if name not in REMOVED_ENV}
    env.update({
        "CLAUDE_CODE_OAUTH_TOKEN": token,
        "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
        "DISABLE_AUTOUPDATER": "1",
        "FWQ_DB": str(WORK / "fw.duckdb"),
        "PATH": f"{SLOT / 'tools' / 'bin'}{os.pathsep}{env.get('PATH') or '/usr/bin:/bin'}",
    })
    return env


def claude_argv(claude: str, job: dict) -> list[str]:
    system = (SLOT / "context" / "analyst.md").read_text(encoding="utf-8")
    argv = [
        claude, "-p", "--output-format", "json",
        "--permission-mode", "dontAsk",
        "--setting-sources", "user",
        "--strict-mcp-config",
        "--add-dir", LOG_DIR,
        "--max-turns", str(job.get("max_turns", DEFAULT_MAX_TURNS)),
        "--append-system-prompt", system,
        "--allowedTools", *ALLOWED_TOOLS,
        "--disallowedTools", *DISALLOWED_TOOLS,
    ]
    if "model" in job:
        argv += ["--model", job["model"]]
    if "resume" in job:
        argv += ["--resume", job["resume"]]
    return argv


def run_claude(argv: list[str], env: dict, prompt: str, max_seconds: int) -> tuple[int, str, str, bool]:
    """Run claude in its own process group, so a timeout ends it and everything it started."""
    proc = subprocess.Popen(
        argv, cwd=WORK, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    try:
        out, err = proc.communicate(prompt.encode("utf-8"), timeout=max_seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            try:
                out, err = proc.communicate(timeout=KILL_GRACE_S)
                break
            except subprocess.TimeoutExpired:
                continue
        else:
            out, err = proc.communicate()
    return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), timed_out


def redact(text: str, token: str) -> str:
    return text.replace(token, REDACTED) if token else text


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def session(prompt: str, job: dict) -> tuple[int, dict]:
    """One claude -p session. Returns the exit code and the run record (already redacted)."""
    claude = shutil.which("claude")
    if not claude:
        raise JobRefusal("tool_missing:claude")
    if not shutil.which("duckdb"):
        raise JobRefusal("tool_missing:duckdb")
    token = read_token()
    prepare_work()
    max_seconds = job.get("max_seconds", DEFAULT_MAX_SECONDS)
    started, t0 = utc_now(), time.monotonic()
    code, out, err, timed_out = run_claude(claude_argv(claude, job), claude_env(token), prompt, max_seconds)
    record = {
        "started": started, "finished": utc_now(), "duration_s": round(time.monotonic() - t0, 1),
        "job": job, "brief": prompt, "exit": code, "timed_out": timed_out,
    }
    try:
        reply = json.loads(out)
    except ValueError:
        reply = None
    if isinstance(reply, dict):
        for key in ("session_id", "subtype", "is_error", "num_turns", "total_cost_usd", "result"):
            if key in reply:
                record[key] = reply[key]
    else:
        record["stdout_tail"] = out[-4000:]
    if code or timed_out or not isinstance(reply, dict) or reply.get("is_error"):
        record["stderr_tail"] = err[-4000:]
    record = json.loads(redact(json.dumps(record), token))
    ok = not (code or timed_out) and isinstance(reply, dict) and not reply.get("is_error")
    return (0 if ok else 1), record


def save_record(record: dict) -> Path:
    stamp = record["started"].replace(":", "").replace("-", "")
    path = WORK / "runs" / f"{stamp}-{str(record.get('session_id', 'nosession'))[:8]}.json"
    path.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


def print_record(record: dict, path: Path) -> None:
    print(f"session: {record.get('session_id', '-')}")
    print(f"turns: {record.get('num_turns', '-')}  duration_s: {record['duration_s']}  "
          f"subtype: {record.get('subtype', '-')}  exit: {record['exit']}  timed_out: {record['timed_out']}")
    print(f"record: {path}")
    for key in ("stderr_tail", "stdout_tail"):
        if record.get(key):
            print(f"--- {key} ---\n{record[key]}")
    print("--- answer ---")
    print(record.get("result", ""))


def ask() -> int:
    brief = SLOT / "brief.md"
    if not brief.is_file():
        raise JobRefusal("brief_missing: put brief.md at the repo root before dispatch")
    prompt = brief.read_text(encoding="utf-8-sig").strip()
    if not prompt:
        raise JobRefusal("brief_empty")
    code, record = session(prompt, read_job())
    print_record(record, save_record(record))
    return code


def selftest() -> int:
    failed = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failed
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")

    for tool in ("claude", "duckdb", "git"):
        check(f"tool {tool}", bool(shutil.which(tool)), shutil.which(tool) or "missing")
    check("work folder writable", os.access(WORK, os.W_OK), str(WORK))
    readable = [p.name for p in sorted(Path(LOG_DIR).glob("*.log")) if os.access(p, os.R_OK)]
    check("log files readable", bool(readable), ", ".join(readable[:8]))
    token_path = fleet_home() / "credentials" / "claude-oauth-token"
    check("token file present", token_path.is_file())
    fwq = SLOT / "tools" / "bin" / "fwq"
    r = subprocess.run([str(fwq), "SELECT 42 AS answer"], capture_output=True, text=True,
                       env={**os.environ, "FWQ_DB": str(WORK / "fw.duckdb")}, stdin=subprocess.DEVNULL)
    check("fwq query", r.returncode == 0 and "42" in r.stdout, (r.stdout + r.stderr).strip()[-300:])
    r = subprocess.run([str(fwq), "SELECT count(*) FROM read_text('/etc/passwd')"], capture_output=True, text=True,
                       env={**os.environ, "FWQ_DB": str(WORK / "fw.duckdb")}, stdin=subprocess.DEVNULL)
    check("fwq blocks files outside the allowed folders", r.returncode != 0, (r.stdout + r.stderr).strip()[-200:])
    if failed:
        print(f"{failed} check(s) failed; claude was not started")
        return 1
    prompt = (
        "Self-test. Run `fwq \"SELECT 6*7 AS n\"`, then `fwq \"SELECT count(*) AS logs FROM glob('/var/log/*.log')\"`, "
        "then use Read on /var/log/firewall-bootstrap.log (first line only). "
        "Reply with one line: OK <n> <logs> <first word of that line>."
    )
    code, record = session(prompt, {"max_turns": 6, "max_seconds": 300})
    print_record(record, save_record(record))
    return code


def main(argv: list[str]) -> int:
    actions = {"ask": ask, "selftest": selftest}
    if len(argv) != 1 or argv[0] not in actions:
        print(f"usage: claude_job.py {{{'|'.join(actions)}}}", file=sys.stderr)
        return 2
    try:
        return actions[argv[0]]()
    except JobRefusal as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
