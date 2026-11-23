#!/usr/bin/env bash
# cmux-ops-suite doctor — health check. Exit 1 on any FAIL.
set -uo pipefail

HOME_DIR="$HOME"
CMUX="$(command -v cmux 2>/dev/null || echo /Applications/cmux.app/Contents/Resources/bin/cmux)"
UID_N="$(id -u)"
PASS=0; FAIL=0; WARN=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
info() { printf '       %s\n' "$*"; }

echo "cmux-ops-suite doctor"
echo "─────────────────────"

# ── files ────────────────────────────────────────────────────────────────────
echo "files:"
for pair in \
  "$HOME_DIR/.local/bin/cmux-wt:cmux-wt" \
  "$HOME_DIR/.local/bin/cmux-pr-dock:cmux-pr-dock" \
  "$HOME_DIR/.config/cmux/ops/poller.py:poller.py" \
  "$HOME_DIR/.config/cmux/sidebars/ops-board.swift:ops-board.swift" \
  "$HOME_DIR/.config/cmux/sidebars/ops-board-lite.js:ops-board-lite.js" \
  "$HOME_DIR/.config/cmux/dock.json:dock.json" \
  "$HOME_DIR/Library/LaunchAgents/com.lovelogic.cmux.ops-poller.plist:ops-poller.plist"; do
  path="${pair%%:*}"; name="${pair##*:}"
  if [ -f "$path" ]; then ok "$name"; else bad "$name missing ($path)"; fi
done
for b in cmux-wt cmux-pr-dock; do
  [ -x "$HOME_DIR/.local/bin/$b" ] && ok "$b executable" || bad "$b not executable"
done

# ── launchd poller ───────────────────────────────────────────────────────────
echo "launchd:"
if launchctl print "gui/$UID_N/com.lovelogic.cmux.ops-poller" 2>/dev/null | grep -q "state = running"; then
  ok "ops-poller running"
else
  bad "ops-poller not running"
fi
CACHE="$HOME_DIR/.config/cmux/ops/state-cache.json"
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  [ "$age" -lt 120 ] && ok "poller cache fresh (${age}s)" || warn "poller cache stale (${age}s)"
else
  warn "poller cache missing (no git workspaces seen yet?)"
fi

# ── sidebars ─────────────────────────────────────────────────────────────────
echo "sidebars:"
"$CMUX" sidebar validate 2>/dev/null | tail -1 | grep -q "0 invalid" && ok "all sidebars valid" || bad "sidebar validation failed"
"$CMUX" sidebar validate ops-board 2>/dev/null | grep -q "OK ops-board" && ok "ops-board valid" || bad "ops-board invalid"
ls "$HOME_DIR/.config/cmux/sidebars/ops-board.js" >/dev/null 2>&1 && warn "ops-board.js still present — shadows ops-board.swift" || ok "no ops-board.js shadow"

# ── sentinel ─────────────────────────────────────────────────────────────────
echo "sentinel:"
if [ -x "$HOME_DIR/bin/cmux-sentinel-doctor.sh" ]; then
  out=$("$HOME_DIR/bin/cmux-sentinel-doctor.sh" 2>&1)
  echo "$out" | grep -q "All critical checks passed" && ok "sentinel doctor: critical pass" || warn "sentinel doctor reported failures"
  echo "$out" | grep "⚠" | sed 's/^/       /' | head -6
else
  warn "cmux-sentinel-doctor.sh missing (sentinel not installed?)"
fi
for label in claude codex amp; do
  launchctl print "gui/$UID_N/com.cmux-${label}-usage" >/dev/null 2>&1 && ok "com.cmux-${label}-usage loaded" || warn "com.cmux-${label}-usage not loaded"
done

# ── groups / cmux ────────────────────────────────────────────────────────────
echo "cmux:"
"$CMUX" workspace-group list --json >/dev/null 2>&1 && ok "workspace-group API alive" || bad "workspace-group API failed"
"$CMUX" ping >/dev/null 2>&1 && ok "cmux socket responding" || bad "cmux socket not responding"
python3 -c "import py_compile; py_compile.compile('$HOME_DIR/.local/bin/cmux-pr-dock', doraise=True)" 2>/dev/null && ok "cmux-pr-dock compiles" || bad "cmux-pr-dock broken"

# ── optional ─────────────────────────────────────────────────────────────────
echo "optional:"
gh auth status >/dev/null 2>&1 && ok "gh authenticated" || warn "gh not authenticated (PR pills/dock limited)"
if [ -d "$HOME_DIR/.cmux-linear-sidebar" ]; then
  if security find-generic-password -s cmux-linear-sidebar -w >/dev/null 2>&1; then
    ok "linear sidebar installed + key in keychain"
  else
    warn "linear sidebar cloned but no API key — run ~/.cmux-linear-sidebar/install.sh"
  fi
else
  info "linear sidebar not installed (optional)"
fi
[ -f "$HOME_DIR/.config/cmux/usage-sentinels.env" ] && \
  grep -q 'USAGE_PROVIDERS="claude codex amp"' "$HOME_DIR/.config/cmux/usage-sentinels.env" \
  && ok "USAGE_PROVIDERS=claude codex amp" || warn "USAGE_PROVIDERS not set"
"$CMUX" config get automation.workspaceAutoNaming 2>/dev/null | grep -q "false" \
  && ok "workspaceAutoNaming disabled" || warn "workspaceAutoNaming still on"

echo "─────────────────────"
echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
[ "$FAIL" -eq 0 ]
