#!/usr/bin/env python3
"""cmux ops poller — push git/PR state into cmux workspace metadata.

For every non-sentinel workspace whose cwd is inside a git repo:
  - writes a one-line description: "WT branch (dirty|clean) · PR <state>"
  - sets the "pr" status pill (open/draft/merged/none/error)

Owns ONLY the "pr" pill and the description — cmux-wt owns "wt"/"agent",
and the sentinel bridge owns agent-state pills.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
STATE_DIR = HOME / ".config" / "cmux" / "ops"
CACHE_FILE = STATE_DIR / "state-cache.json"
CMUX = "/Applications/cmux.app/Contents/Resources/bin/cmux"
GH_TIMEOUT = 6
PR_CACHE_TTL = 45  # seconds

# Sentinel meter labels — any workspace title equal to or starting "<label> "
# is a usage meter, not real work.
METER_LABELS = (
    "5h", "7d", "m7d", "spend",
    "cx5h", "cx7d",
    "ampu", "ampo",
)


def run(cmd: list[str], cwd: str | None = None, timeout: int = 8) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
        )
        return p.returncode, p.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return 127, ""


def is_meter(title: str) -> bool:
    for label in METER_LABELS:
        if title == label or title.startswith(label + " "):
            return True
    return False


def git(args: list[str], cwd: str) -> tuple[int, str]:
    return run(["git", "-C", cwd] + args, timeout=8)


def repo_root(cwd: str) -> str | None:
    rc, out = git(["rev-parse", "--show-toplevel"], cwd)
    return out if rc == 0 and out else None


def is_worktree(root: str) -> bool:
    rc, gd = git(["rev-parse", "--git-dir"], root)
    return rc == 0 and "/worktrees/" in gd.replace("\\", "/")


def branch_and_dirty(root: str) -> tuple[str, bool]:
    rc, br = git(["rev-parse", "--abbrev-ref", "HEAD"], root)
    branch = br if rc == 0 and br and br != "HEAD" else "(detached)"
    rc, st = git(["status", "--porcelain"], root)
    dirty = rc == 0 and bool(st)
    return branch, dirty


def has_github_remote(root: str) -> bool:
    rc, url = git(["remote", "get-url", "origin"], root)
    return rc == 0 and bool(url) and "github.com" in url


def pr_state(root: str, branch: str, cache: dict) -> tuple[str, str]:
    """Return (badge_label, pill_color). Caches per (root, branch)."""
    key = f"{root}|{branch}"
    now = time.time()
    ent = cache.get(key)
    if ent and now - ent.get("ts", 0) < PR_CACHE_TTL:
        return ent["label"], ent["color"]

    label, color = "PR ?", "#8E8E93"
    rc, out = run(
        ["gh", "pr", "view", branch, "--json",
         "number,state,isDraft,reviewDecision,statusCheckRollup"],
        cwd=root, timeout=GH_TIMEOUT,
    )
    if rc == 0 and out:
        try:
            pr = json.loads(out)
            n = pr.get("number")
            state = pr.get("state", "")
            draft = pr.get("isDraft", False)
            checks = pr.get("statusCheckRollup") or []
            failing = any(
                (c.get("conclusion") or c.get("state") or "").upper()
                in {"FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED"}
                for c in checks if isinstance(c, dict)
            )
            pending = any(
                (c.get("status") or "").upper() in {"IN_PROGRESS", "QUEUED", "PENDING", "WAITING"}
                or (c.get("state") or "").upper() in {"PENDING", "EXPECTED"}
                for c in checks if isinstance(c, dict)
            )
            if state == "MERGED":
                label, color = f"PR #{n} merged", "#BF5AF2"
            elif state == "CLOSED":
                label, color = f"PR #{n} closed", "#8E8E93"
            elif draft:
                label, color = f"PR #{n} draft", "#FFD60A"
            elif failing:
                label, color = f"PR #{n} failing", "#FF453A"
            elif pending:
                label, color = f"PR #{n} checks…", "#0A84FF"
            elif state == "OPEN":
                label, color = f"PR #{n} open", "#30D158"
        except (json.JSONDecodeError, AttributeError):
            pass
    elif rc == 4 or (rc != 0 and "no pull requests found" in out.lower()):
        label, color = "PR none", "#636366"
    else:
        # gh error (no auth, no remote, timeout) — keep neutral, do NOT cache long
        return "PR ?", "#8E8E93"

    cache[key] = {"ts": now, "label": label, "color": color}
    return label, color


def cmux_set_status(ref: str, key: str, value: str, icon: str, color: str) -> None:
    run([CMUX, "set-status", key, value, "--icon", icon,
         "--color", color, "--workspace", ref], timeout=8)


def cmux_set_desc(ref: str, desc: str) -> None:
    run([CMUX, "workspace-action", "set-description",
         "--workspace", ref, "--description", desc], timeout=8)


def load_cache() -> dict:
    try:
        return json.loads(CACHE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_cache(cache: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        CACHE_FILE.write_text(json.dumps(cache))
    except OSError:
        pass


def main() -> int:
    rc, out = run([CMUX, "workspace", "list", "--json"], timeout=10)
    if rc != 0 or not out:
        print("cmux workspace list failed", file=sys.stderr)
        return 1
    try:
        workspaces = json.loads(out).get("workspaces", [])
    except json.JSONDecodeError:
        print("bad workspace list json", file=sys.stderr)
        return 1

    cache = load_cache()
    changed = False

    for w in workspaces:
        ref = w.get("ref")
        title = w.get("title") or ""
        cwd = w.get("current_directory") or ""
        if not ref or is_meter(title) or not cwd or not os.path.isdir(cwd):
            continue
        # Only manage workspaces the ops suite owns: anything under a
        # .worktrees/ dir, or titled "<repo>/<branch>" by cmux-wt. Plain user
        # workspaces keep whatever description they already have.
        parts = Path(cwd).parts
        in_worktrees = ".worktrees" in parts
        wt_title = bool(re.match(r"^[^/\s]+/[^/\s]+$", title))
        if not (in_worktrees or wt_title):
            continue
        root = repo_root(cwd)
        if not root:
            continue
        branch, dirty = branch_and_dirty(root)
        kind = "WT" if is_worktree(root) else "MAIN"
        state = "dirty" if dirty else "clean"

        if has_github_remote(root):
            plabel, pcolor = pr_state(root, branch, cache)
            cmux_set_status(ref, "pr", plabel, "arrow.triangle.pull", pcolor)
        else:
            plabel = "PR n/a"

        desc = f"{kind} {branch} ({state}) · {plabel}"
        prev = cache.get(f"desc|{ref}")
        if not prev or prev.get("v") != desc:
            cache[f"desc|{ref}"] = {"ts": time.time(), "v": desc}
            cmux_set_desc(ref, desc)

    save_cache(cache)
    return 0


if __name__ == "__main__":
    sys.exit(main())
