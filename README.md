# cmux-ops-suite

Idempotent installer + doctor for the custom cmux ops suite on this machine (cmux 0.65.2, macOS arm64).

## What it installs

| Component | Deploys to | What it does |
|---|---|---|
| `cmux-wt` | `~/.local/bin/` | `cmux-wt <branch> [agent] [base]` — git worktree + cmux workspace, auto-grouped into `Repos/<repo>` |
| `cmux-pr-dock` | `~/.local/bin/` | curses TUI for PR diff / failed CI logs / comments; tracks focused workspace |
| ops poller | `~/.config/cmux/ops/` + LaunchAgent | every 20s writes `pr` pill + `WT branch (dirty) · PR …` description on `.worktrees/`/`repo/branch` workspaces |
| `ops-board.swift` | `~/.config/cmux/sidebars/` | selected left sidebar: usage meters + slash-nested groups + agent dots + PR telemetry |
| `ops-board-lite.js` | `~/.config/cmux/sidebars/` | JS fallback sidebar (renamed from old ops-board.js) |
| `dock.json` | `~/.config/cmux/` | seeds right-Dock `pr-dock` terminal control (merged by id) |
| cmux-sentinel | `~/.cmux-sentinel` → `~/bin/` | Claude/Codex/Amp usage meter workspaces + bridge hooks; `USAGE_PROVIDERS="claude codex amp"` |
| credential patch | `~/bin/cmux-claude-usage.sh` | re-applied after every sentinel install (keychain hashed-service fallback) |
| agent hooks | cmux-managed | `cmux hooks setup -y` for all detected agents |

## Install

```sh
git clone <this-repo> && cd cmux-ops-suite
./install.sh     # idempotent — safe to re-run
./doctor.sh      # health check, exit 1 on FAIL
```

## Manual steps it can't do

- **Linear sidebar**: `~/.cmux-linear-sidebar/install.sh` in a cmux terminal — needs interactive `lin_api_` key (Linear → Settings → Security & access → Personal API keys). Then add a `linear-dock` control to `~/.config/cmux/dock.json`.
- **Claude meters** show `⚠ auth` until Claude Code refreshes OAuth (self-heals on use).
- **Amp meter** shows `⚠ no data` — pay-as-you-go account, no subscription plan (expected).
- Launch cmux with `open --env JSC_useConcurrentJIT=0 -a cmux` to avoid the `.js` sidebar JIT memory leak on 0.65.2.
- If `pr-dock` doesn't appear in the Dock: `cmux new-surface --placement dock --command "$HOME/.local/bin/cmux-pr-dock"`.

## Layout

```
install.sh  doctor.sh  README.md
files/
  bin/{cmux-wt, cmux-pr-dock}
  cmux/ops/poller.py   cmux/dock.json
  launchd/com.lovelogic.cmux.ops-poller.plist
  sidebars/{ops-board.swift, ops-board-lite.js}
  sentinel/cmux-claude-usage.sh   # patched read_token (hashed keychain services)
```

## cmux 0.65.2 gotchas baked in

- `workspace create --json` → `workspace_ref`; `--workspace` accepts `workspace:N` refs.
- `workspace-action set-description --workspace <ref> --description <text>` (no `workspace update`).
- `set-status <key> <val> --icon --color --workspace <ref>`; `clear-status`.
- `workspace-group list|create|add` — group id lives at `.group.ref` in create JSON.
- `hooks setup -y` (no `hooks status`); `send-text` does NOT exist.
- Sidebar interpreter: no `||`, no nil comparisons, no nested Buttons, no `return` in `for`.
- Socket control already `automation` via Settings — never add to cmux.json.
