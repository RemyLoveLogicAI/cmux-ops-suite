#!/usr/bin/env bash
# cmux-ops-suite installer — idempotent, safe to re-run.
# Deploys: cmux-wt, cmux-pr-dock, ops poller (launchd), ops-board sidebar,
# dock.json, cmux-sentinel (meters + Claude credential patch), agent hooks.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$REPO/files"
HOME_DIR="$HOME"
CMUX="$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
UID_N="$(id -u)"

say()  { printf '\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mwarn: %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null || fail "python3 required"
[ -x "$CMUX" ] || fail "cmux CLI not found"
"$CMUX" ping >/dev/null 2>&1 || warn "cmux not responding — socket steps will be skipped"

# ── 1. binaries ──────────────────────────────────────────────────────────────
say "bin → ~/.local/bin"
mkdir -p "$HOME_DIR/.local/bin"
for f in "$FILES"/bin/*; do
  install -m 0755 "$f" "$HOME_DIR/.local/bin/$(basename "$f")"
done

# ── 2. ops poller + launchd ──────────────────────────────────────────────────
say "ops poller"
mkdir -p "$HOME_DIR/.config/cmux/ops" "$HOME_DIR/Library/LaunchAgents"
install -m 0644 "$FILES/cmux/ops/poller.py" "$HOME_DIR/.config/cmux/ops/poller.py"
# plist template: __HOME__/__USER__ rendered at install time → portable
LA="$HOME_DIR/Library/LaunchAgents/com.cmux.ops-poller.plist"
sed -e "s|__HOME__|$HOME_DIR|g" -e "s|__USER__|$(id -un)|g" \
    "$FILES/launchd/com.cmux.ops-poller.plist.in" > "$LA"
chmod 0644 "$LA"
# upgrade path: drop the pre-rename label/file if an older install left them
launchctl bootout "gui/$UID_N/com.lovelogic.cmux.ops-poller" 2>/dev/null || true
rm -f "$HOME_DIR/Library/LaunchAgents/com.lovelogic.cmux.ops-poller.plist"
launchctl bootout "gui/$UID_N/com.cmux.ops-poller" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$LA" 2>/dev/null || true

# ── 3. sidebars ──────────────────────────────────────────────────────────────
say "sidebars"
mkdir -p "$HOME_DIR/.config/cmux/sidebars"
SB="$HOME_DIR/.config/cmux/sidebars"
# Retire the old JS ops-board once so the .swift isn't shadowed (.js wins on tie)
if [ -f "$SB/ops-board.js" ] && [ ! -f "$SB/ops-board-lite.js" ]; then
  mv "$SB/ops-board.js" "$SB/ops-board-lite.js"
fi
install -m 0644 "$FILES"/sidebars/* "$SB/"
"$CMUX" sidebar validate ops-board >/dev/null 2>&1 || warn "ops-board failed validation"
"$CMUX" sidebar reload >/dev/null 2>&1 || warn "sidebar reload failed"
"$CMUX" sidebar select ops-board >/dev/null 2>&1 || warn "sidebar select failed (pick ops-board from the sidebar menu)"

# ── 4. dock.json (merge controls by id) ──────────────────────────────────────
say "dock.json"
mkdir -p "$HOME_DIR/.config/cmux"
HOME_DIR="$HOME_DIR" python3 - "$FILES/cmux/dock.json.in" "$HOME_DIR/.config/cmux/dock.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
new = json.loads(open(src).read().replace("__HOME__", __import__("os").environ["HOME_DIR"]))
try:
    cur = json.load(open(dst))
except (OSError, json.JSONDecodeError):
    cur = {"controls": []}
controls = cur.setdefault("controls", [])
ids = {c.get("id") for c in controls if isinstance(c, dict)}
for c in new.get("controls", []):
    if c.get("id") in ids:
        controls[[i for i,x in enumerate(controls) if x.get("id")==c["id"]][0]] = c
    else:
        controls.append(c)
json.dump(cur, open(dst, "w"), indent=2)
print(f"dock.json: {len(controls)} control(s)")
PY

say "cmux-sentinel"
mkdir -p "$HOME_DIR/bin"
if [ ! -d "$HOME_DIR/.cmux-sentinel" ]; then
  git clone --depth 1 https://github.com/oliver-kriska/cmux-sentinel.git "$HOME_DIR/.cmux-sentinel" || warn "sentinel clone failed"
fi
if [ -f "$HOME_DIR/.cmux-sentinel/install.sh" ]; then
  (cd "$HOME_DIR/.cmux-sentinel" && WITH_BRIDGE=1 ./install.sh >/dev/null 2>&1) || warn "sentinel install.sh reported errors (non-fatal)"
fi
# Re-apply the credential patch AFTER sentinel's installer (it overwrites ~/bin)
if [ -f "$FILES/sentinel/cmux-claude-usage.sh" ]; then
  install -m 0755 "$FILES/sentinel/cmux-claude-usage.sh" "$HOME_DIR/bin/cmux-claude-usage.sh" 2>/dev/null || \
    install -m 0755 "$FILES/sentinel/cmux-claude-usage.sh" "$HOME_DIR/.local/bin/cmux-claude-usage.sh"
  [ -f "$HOME_DIR/.cmux-sentinel/bin/cmux-claude-usage.sh" ] && \
    install -m 0755 "$FILES/sentinel/cmux-claude-usage.sh" "$HOME_DIR/.cmux-sentinel/bin/cmux-claude-usage.sh"
fi
# Provider switch
ENVF="$HOME_DIR/.config/cmux/usage-sentinels.env"
mkdir -p "$HOME_DIR/.config/cmux"
if [ -f "$ENVF" ]; then
  if grep -q '^USAGE_PROVIDERS=' "$ENVF"; then
    sed -i '' 's/^USAGE_PROVIDERS=.*/USAGE_PROVIDERS="claude codex amp"/' "$ENVF"
  else
    printf '\nUSAGE_PROVIDERS="claude codex amp"\n' >> "$ENVF"
  fi
else
  printf 'USAGE_PROVIDERS="claude codex amp"\n' > "$ENVF"
fi
[ -x "$HOME_DIR/bin/cmux-sentinel-setup.sh" ] && "$HOME_DIR/bin/cmux-sentinel-setup.sh" >/dev/null 2>&1 || true
for label in claude codex amp; do
  plist="$HOME_DIR/Library/LaunchAgents/com.cmux-${label}-usage.plist"
  [ -f "$plist" ] || continue
  launchctl print "gui/$UID_N/com.cmux-${label}-usage" >/dev/null 2>&1 || \
    launchctl bootstrap "gui/$UID_N" "$plist" 2>/dev/null || true
done
# Sentinel watch: recreates per-window meter workspaces after cmux restarts.
# Cheap no-layout pass every 60s; full layout pass only when sentinels were missing.
if [ -f "$FILES/sentinel/cmux-sentinel-watch.sh" ]; then
  install -m 0755 "$FILES/sentinel/cmux-sentinel-watch.sh" "$HOME_DIR/bin/cmux-sentinel-watch.sh"
fi
LAW="$HOME_DIR/Library/LaunchAgents/com.cmux.sentinel-watch.plist"
if [ -f "$FILES/launchd/com.cmux.sentinel-watch.plist.in" ]; then
  sed -e "s|__HOME__|$HOME_DIR|g" \
      "$FILES/launchd/com.cmux.sentinel-watch.plist.in" > "$LAW"
  chmod 0644 "$LAW"
  launchctl bootout "gui/$UID_N/com.cmux.sentinel-watch" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$LAW" 2>/dev/null || true
fi

# ── 5b. memory board (one-shot collector + carrier workspace) ────────────────
say "memory board"
mkdir -p "$HOME_DIR/.config/cmux/memory"
install -m 0755 "$FILES/cmux/memory/board.py" "$HOME_DIR/.config/cmux/memory/board.py"
# env file: only create if absent (never overwrite a real key)
if [ ! -f "$HOME_DIR/.config/cmux/memory/env" ]; then
  install -m 0600 "$FILES/cmux/memory/env.example" "$HOME_DIR/.config/cmux/memory/env"
  warn "created ~/.config/cmux/memory/env — add SUPERMEMORY_API_KEY to enable Supermemory"
fi
LA2="$HOME_DIR/Library/LaunchAgents/com.cmux.memory-board.plist"
sed -e "s|__HOME__|$HOME_DIR|g" \
    "$FILES/launchd/com.cmux.memory-board.plist.in" > "$LA2"
chmod 0644 "$LA2"
launchctl bootout "gui/$UID_N/com.cmux.memory-board" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$LA2" 2>/dev/null || true
install -m 0644 "$FILES/sidebars/memory-board.js" "$SB/memory-board.js"
"$CMUX" sidebar validate memory-board >/dev/null 2>&1 || warn "memory-board failed validation"

# ── 6. hooks + settings ──────────────────────────────────────────────────────
say "agent hooks + settings"
"$CMUX" hooks setup -y >/dev/null 2>&1 || warn "cmux hooks setup reported errors (copilot config may be invalid — non-fatal)"
"$CMUX" config set automation.workspaceAutoNaming false >/dev/null 2>&1 || true

say "done"
cat <<'EOF'
Live now: cmux-wt, cmux-pr-dock (dock.json seeded), ops poller (launchd, 20s),
ops-board.swift sidebar (selected), sentinel meters (claude/codex/amp), agent hooks,
memory-board sidebar (carrier workspace + launchd collector, 60s).

Pending (manual):
  - Linear sidebar: run ~/.cmux-linear-sidebar/install.sh in a cmux terminal (needs lin_api_ key)
  - Claude meters show ⚠ auth until Claude Code refreshes its OAuth token (self-heals on use)
  - Amp meter shows ⚠ no data — pay-as-you-go account, no subscription plan (expected)
  - Launch cmux with: open --env JSC_useConcurrentJIT=0 -a cmux  (.js sidebar JIT leak workaround)
  - Dock: if pr-dock doesn't appear, run: cmux new-surface --placement dock --command "$HOME/.local/bin/cmux-pr-dock"

Health check: ./doctor.sh
EOF
