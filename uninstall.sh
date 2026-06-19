#!/bin/bash
#
# CodeFocus — Mac Uninstall
# Entfernt einzelne Tools oder (ohne Argumente) CodeFocus komplett vom Mac.
#
# Nutzung:
#   curl -fsSL .../uninstall.sh | bash -s -- cursor       # nur Cursor entfernen
#   curl -fsSL .../uninstall.sh | bash -s -- cursor codex # mehrere
#   curl -fsSL .../uninstall.sh | bash                    # ALLES entfernen (Bridge + Hooks)
#
set -e

CF_DIR="$HOME/.codefocus"
PLIST="$HOME/Library/LaunchAgents/app.codefocus.peripheral.plist"
CURSOR_HOOKS_JSON="$HOME/.cursor/hooks.json"
CODEX_HOOKS_JSON="$HOME/.codex/hooks.json"
CODEX_CONFIG="$HOME/.codex/config.toml"
PY="$(command -v python3 || true)"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }

# Entfernt unsere Einträge aus einer Cursor-hooks.json (flaches Format); löscht Datei, wenn leer.
clean_cursor() {
  [ -n "$PY" ] && [ -f "$CURSOR_HOOKS_JSON" ] || return 0
  "$PY" - "$CURSOR_HOOKS_JSON" "cursor-hook.sh" <<'PYEOF'
import json,os,sys
path,m=sys.argv[1],sys.argv[2]
try: cfg=json.load(open(path))
except: raise SystemExit
h=cfg.get("hooks",{})
for ev in list(h):
    h[ev]=[x for x in h[ev] if isinstance(x,dict) and m not in x.get("command","")]
    if not h[ev]: del h[ev]
if not h: os.remove(path)
else: json.dump(cfg,open(path,"w"),indent=2)
PYEOF
}

# Entfernt unsere Einträge aus einer Codex-hooks.json (verschachtelt) + Trust in config.toml.
clean_codex() {
  if [ -n "$PY" ] && [ -f "$CODEX_HOOKS_JSON" ]; then
    "$PY" - "$CODEX_HOOKS_JSON" "codex-hook.sh" <<'PYEOF'
import json,os,sys
path,m=sys.argv[1],sys.argv[2]
try: cfg=json.load(open(path))
except: raise SystemExit
h=cfg.get("hooks",{})
for ev in list(h):
    h[ev]=[g for g in h[ev] if not any(m in hh.get("command","") for hh in (g.get("hooks",[]) if isinstance(g,dict) else []))]
    if not h[ev]: del h[ev]
if not h: os.remove(path)
else: json.dump(cfg,open(path,"w"),indent=2)
PYEOF
  fi
  if [ -n "$PY" ] && [ -f "$CODEX_CONFIG" ]; then
    "$PY" - "$CODEX_CONFIG" <<'PYEOF'
import sys
p=sys.argv[1]; out=[]; skip=False
for ln in open(p).read().splitlines(keepends=True):
    s=ln.lstrip()
    if s.startswith("["): skip=s.startswith("[hooks.state")
    if not skip: out.append(ln)
open(p,"w").writelines(out)
PYEOF
  fi
}

echo ""
TOOLS=("$@")

# ---------- Komplett-Deinstallation (keine Argumente) ----------
if [ ${#TOOLS[@]} -eq 0 ]; then
  bold "🧹 CodeFocus komplett entfernen…"
  launchctl bootout "gui/$(id -u)/app.codefocus.peripheral" 2>/dev/null || true
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$CF_DIR"
  clean_cursor
  clean_codex
  rm -f "$HOME/.claude/claude-state" 2>/dev/null || true
  ok "Bridge, Autostart und alle CodeFocus-Hooks entfernt"
  warn "Cursor & Codex ggf. neu starten, damit gecachte Hooks verschwinden."
  echo ""
  exit 0
fi

# ---------- Einzelne Tools ----------
want() { local t; for t in "${TOOLS[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }
bold "🧹 Entferne: ${TOOLS[*]}"

if want cursor; then
  rm -f "$CF_DIR/cursor-hook.sh" "$CF_DIR/cursor-state"
  clean_cursor
  ok "Cursor entfernt — Cursor neu starten, damit der Hook verschwindet"
fi

if want codex; then
  rm -f "$CF_DIR/codex-hook.sh" "$CF_DIR/codex-state"
  clean_codex
  ok "Codex entfernt — Codex neu starten, damit der Hook verschwindet"
fi

if want claude; then
  warn "Claude wird nativ erkannt (kein eigener Hook) — nichts einzeln zu entfernen."
  echo "      Für komplette Entfernung:  curl -fsSL .../uninstall.sh | bash"
fi

echo ""
bold "✅ Fertig."
echo ""
