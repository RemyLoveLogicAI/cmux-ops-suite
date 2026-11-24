#!/usr/bin/env python3
"""cmux memory board — unified memory state collector (one-shot).

Runs once per launchd tick (~60s), collects memory state, writes
~/.config/cmux/memory/state.json, and mirrors a compact JSON snapshot into
the `mem-board` carrier workspace's description so the native
`memory-board.js` sidebar can bind it live.

NO HTTP server — the board is file+workspace-description only. This keeps
personal data off any socket (AGENTS_BRIDGE ephemeral-port rule).

Sources:
  - TypeFire vault  ~/Documents/TypeFire_Notes (recent .md notes + daily)
  - LifeOS          ~/.config/LIFEOS/USER (PROJECTS.md, FEED.md)
  - OH HAI          `oh-hai messages list --json` (open asks/tasks/notify)
  - Supermemory     api.supermemory.ai/v3/search (SUPERMEMORY_API_KEY env)
  - Mem (mem.ai)    MCP-only — reported as unavailable

No deps beyond stdlib.
"""

from __future__ import annotations
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
VAULT = HOME / "Documents" / "TypeFire_Notes"
LIFEOS_USER = HOME / ".config" / "LIFEOS" / "USER"
STATE_DIR = HOME / ".config" / "cmux" / "memory"
STATE_FILE = STATE_DIR / "state.json"
REFRESH_S = 60          # launchd StartInterval; reference only
CARRIER_TITLE = "mem-board"
ENV_FILE = STATE_DIR / "env"   # chmod 600; holds SUPERMEMORY_API_KEY etc.
CMUX = os.environ.get("CMUX_BIN", "/Applications/cmux.app/Contents/Resources/bin/cmux")
if not Path(CMUX).exists():
    CMUX = "cmux"

# Rotating Supermemory queries — recent durable memories.
SM_QUERIES = [
    "recent decision", "project status", "user preference",
    "architecture choice", "lesson learned", "current focus",
]
_sm_idx = 0


def load_env() -> None:
    """Load KEY=VALUE pairs from ENV_FILE into os.environ (file wins over env)."""
    try:
        for ln in ENV_FILE.read_text().splitlines():
            ln = ln.strip()
            if not ln or ln.startswith("#") or "=" not in ln:
                continue
            k, _, v = ln.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    except OSError:
        pass


def sh(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return 127, ""


# ── collectors ────────────────────────────────────────────────────────────────

def collect_typefire() -> dict:
    notes = []
    daily = ""
    if VAULT.is_dir():
        files = [p for p in VAULT.rglob("*.md") if p.is_file()]
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        for p in files[:12]:
            try:
                stat = p.stat()
                rel = str(p.relative_to(VAULT))
                # first heading or first non-empty line as excerpt
                excerpt = ""
                try:
                    for line in p.read_text(errors="replace").splitlines():
                        s = line.strip().lstrip("#").strip()
                        if s and not s.startswith("---") and not s.startswith("tags:"):
                            excerpt = s[:140]
                            break
                except OSError:
                    pass
                notes.append({
                    "t": p.stem, "p": str(p), "rel": rel,
                    "mtime": int(stat.st_mtime), "excerpt": excerpt,
                })
            except OSError:
                continue
        today = VAULT / "Daily" / "Today.md"
        if today.exists():
            try:
                daily = today.read_text(errors="replace")[:800]
            except OSError:
                pass
    return {"daily": daily, "notes": notes}


def _md_headings(path: Path, limit: int = 30) -> list[str]:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for ln in lines:
        s = ln.strip()
        if s.startswith("#") and not s.startswith("# ") is False:
            pass
        if re.match(r"^#{1,3}\s", s):
            out.append(s.lstrip("#").strip()[:120])
            if len(out) >= limit:
                break
    return out


def collect_lifeos() -> dict:
    projects = []
    feed = []
    pj = LIFEOS_USER / "PROJECTS.md"
    if pj.exists():
        try:
            in_table = False
            for ln in pj.read_text(errors="replace").splitlines():
                s = ln.strip()
                if s.startswith("|") and "---" not in s:
                    cells = [c.strip() for c in s.strip("|").split("|")]
                    if cells and cells[0].lower() not in ("project", "name", ""):
                        projects.append({"name": cells[0][:80],
                                         "status": cells[-1][:60] if len(cells) > 1 else ""})
                if len(projects) >= 20:
                    break
        except OSError:
            pass
        # fallback: headings
        if not projects:
            projects = [{"name": h, "status": ""} for h in _md_headings(pj, 15)]
    fd = LIFEOS_USER / "FEED.md"
    if fd.exists():
        try:
            for ln in fd.read_text(errors="replace").splitlines():
                s = ln.strip()
                if s.startswith("|") and "---" not in s and "Source" not in s:
                    cells = [c.strip() for c in s.strip("|").split("|")]
                    if cells and cells[0]:
                        feed.append({"name": cells[0][:60],
                                     "type": cells[1][:30] if len(cells) > 1 else "",
                                     "url": cells[2][:80] if len(cells) > 2 else ""})
                if len(feed) >= 15:
                    break
        except OSError:
            pass
    return {"projects": projects, "feed": feed}


def collect_ohai() -> dict:
    rc, out = sh(["/opt/homebrew/bin/oh-hai", "messages", "list", "--json", "--limit", "30"], timeout=30)
    items = []
    if rc != 0:
        return {"pending": [], "error": f"rc={rc} out={out[:120]}"}
    try:
        msgs = json.loads(out).get("data", {}).get("messages", [])
    except json.JSONDecodeError:
        return {"pending": [], "error": f"json_err out={out[:120]}"}
    for m in msgs:
        st = m.get("status", "")
        if st in ("open", "queued", "acknowledged"):
            items.append({
                "id": m.get("id", "")[:24],
                "title": (m.get("title") or "")[:90],
                "type": m.get("type", ""),
                "status": st,
                "ts": m.get("created_at", "")[:19],
            })
    return {"pending": items[:12]}


def collect_supermemory() -> dict:
    key = os.environ.get("SUPERMEMORY_API_KEY")
    if not key:
        return {"available": False, "results": []}
    global _sm_idx
    q = SM_QUERIES[_sm_idx % len(SM_QUERIES)]
    _sm_idx += 1
    try:
        req = urllib.request.Request(
            "https://api.supermemory.ai/v3/search",
            data=json.dumps({"q": q, "containerTag": "lovelogic", "limit": 5}).encode(),
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        r = json.load(urllib.request.urlopen(req, timeout=12))
        results = []
        for it in r.get("results", [])[:5]:
            chunk = (it.get("chunks") or [{}])[0].get("content", "")
            results.append({
                "title": (it.get("title") or "")[:100],
                "snippet": chunk[:220],
                "score": round(it.get("score", 0), 3),
                "ts": (it.get("updatedAt") or it.get("createdAt") or "")[:19],
            })
        return {"available": True, "query": q, "results": results}
    except Exception as e:
        return {"available": False, "error": str(e)[:120], "results": []}


def collect_mem() -> dict:
    """Mem (mem.ai) is MCP-only on this machine; no local CLI/API. Report state."""
    return {"available": False, "note": "Mem reachable via MCP Router only"}


def collect_all() -> dict:
    return {
        "ts": int(time.time()),
        "typefire": collect_typefire(),
        "lifeos": collect_lifeos(),
        "ohai": collect_ohai(),
        "supermemory": collect_supermemory(),
        "mem": collect_mem(),
    }


# ── carrier workspace (native sidebar data path) ─────────────────────────────

def find_carriers() -> list[str]:
    """All workspace refs titled CARRIER_TITLE, newest-described first."""
    rc, out = sh([CMUX, "workspace", "list", "--json"], timeout=10)
    if rc != 0:
        return []
    refs = []
    try:
        for w in json.loads(out).get("workspaces", []):
            if (w.get("title") or "") == CARRIER_TITLE:
                refs.append(w.get("ref"))
    except json.JSONDecodeError:
        pass
    return [r for r in refs if r]


def ensure_carrier() -> str | None:
    """Return one carrier ref; close duplicates so only one survives."""
    refs = find_carriers()
    if refs:
        keep, *extras = refs
        for ref in extras:
            sh([CMUX, "workspace", "close", ref, "--force"], timeout=8)
        return keep
    # create parked workspace in home dir; no command → plain shell
    rc, out = sh([CMUX, "workspace", "create", "--name", CARRIER_TITLE,
                  "--cwd", str(HOME), "--json"], timeout=10)
    if rc == 0:
        try:
            return json.loads(out).get("workspace_ref")
        except json.JSONDecodeError:
            pass
    # fallback: parse text output
    m = re.search(r"workspace:\d+", out)
    return m.group(0) if m else None


def publish_carrier(state: dict) -> None:
    """Write compact state into carrier workspace description (≤ ~3.5KB)."""
    ref = ensure_carrier()
    if not ref:
        return
    # compact projection — sidebar only needs the visible fields
    slim = {
        "ts": state["ts"],
        "tf": [{"t": n["t"], "rel": n["rel"], "excerpt": n["excerpt"][:80]}
               for n in state["typefire"]["notes"][:8]],
        "lp": [{"n": p["name"], "s": p["status"]} for p in state["lifeos"]["projects"][:10]],
        "oh": [{"t": i["title"], "ty": i["type"], "st": i["status"]}
               for i in state["ohai"]["pending"][:8]],
        "sm": [{"t": r["title"], "s": r["snippet"][:120]}
               for r in state["supermemory"]["results"][:5]] if state["supermemory"]["available"] else [],
        "smq": state["supermemory"].get("query", ""),
    }
    desc = json.dumps(slim, separators=(",", ":"))
    if len(desc) > 3900:
        # trim until it fits
        while len(desc) > 3900 and slim["tf"]:
            slim["tf"].pop()
            desc = json.dumps(slim, separators=(",", ":"))
        while len(desc) > 3900 and slim["sm"]:
            slim["sm"].pop()
            desc = json.dumps(slim, separators=(",", ":"))
    sh([CMUX, "workspace-action", "set-description",
        "--workspace", ref, "--description", desc], timeout=8)


def main() -> int:
    load_env()
    try:
        state = collect_all()
    except Exception as e:
        print(f"collect error: {e}", file=sys.stderr)
        return 1
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state))
    publish_carrier(state)
    counts = {
        "typefire": len(state["typefire"]["notes"]),
        "lifeos": len(state["lifeos"]["projects"]),
        "ohai": len(state["ohai"]["pending"]),
        "sm": len(state["supermemory"].get("results", [])),
    }
    print(f"memory state → {STATE_FILE}  {counts}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
