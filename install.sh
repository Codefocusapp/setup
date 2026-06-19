#!/bin/bash
#
# CodeFocus — Mac Setup
# Verbindet deine AI-Coding-Tools (Claude Code / Cursor / Codex) mit der
# CodeFocus iPhone-App über Bluetooth.
#
# Nutzung:
#   curl -fsSL https://raw.githubusercontent.com/codefocusapp/setup/main/install.sh | bash
#       -> richtet ALLE Tools ein
#   curl -fsSL .../install.sh | bash -s -- cursor codex
#       -> richtet nur die genannten Tools ein
#
# Mehrfach ausführbar (idempotent): erneut mit mehr Tokens laufen lassen,
# um später ein Tool hinzuzufügen.
#
set -e

# ---------- Tool-Auswahl ----------
TOOLS=("$@")
if [ ${#TOOLS[@]} -eq 0 ]; then TOOLS=(claude cursor codex); fi
want() { local t; for t in "${TOOLS[@]}"; do [ "$t" = "$1" ] && return 0; done; return 1; }

# ---------- Pfade ----------
CF_DIR="$HOME/.codefocus"
CLAUDE_DIR="$HOME/.claude"
STATE_FILE="$CLAUDE_DIR/claude-state"
SETTINGS="$CLAUDE_DIR/settings.json"
PLIST="$HOME/Library/LaunchAgents/app.codefocus.peripheral.plist"
APP="$CF_DIR/CodeFocus.app"
BIN="$APP/Contents/MacOS/CodeFocus"
SRC="$CF_DIR/CodeFocus.swift"
LOG="$CF_DIR/codefocus.log"
CURSOR_HOOK="$CF_DIR/cursor-hook.sh"
CODEX_HOOK="$CF_DIR/codex-hook.sh"
CURSOR_HOOKS_JSON="$HOME/.cursor/hooks.json"
CODEX_HOOKS_JSON="$HOME/.codex/hooks.json"
# Alt-Setup (frühere "Earned"-Version) zum Aufräumen
OLD_DIR="$HOME/.earned"
OLD_PLIST="$HOME/Library/LaunchAgents/app.earned.peripheral.plist"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$1"; exit 1; }

echo ""
bold "🔒 CodeFocus — Mac Setup"
echo "Tools: ${TOOLS[*]}"
echo ""

# ---------- 1. Checks ----------
[ "$(uname)" = "Darwin" ] || die "CodeFocus läuft nur auf macOS."

if ! command -v swiftc >/dev/null 2>&1; then
  warn "Xcode Command Line Tools fehlen (für die Kompilierung)."
  echo "  Bitte ausführen:  xcode-select --install"
  echo "  Danach dieses Script erneut starten."
  die "swiftc nicht gefunden."
fi
ok "Xcode Command Line Tools gefunden"

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || die "python3 nicht gefunden (kommt mit Xcode CLT)."

if want claude && [ ! -d "$CLAUDE_DIR" ]; then
  warn "Claude Code scheint nicht installiert (~/.claude fehlt) — der Rest wird trotzdem eingerichtet."
fi

# Alt-Setup (frühere "Earned"-Version) aufräumen
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -rf "$OLD_DIR" "$OLD_PLIST" 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"

# ---------- 2. BLE-Peripheral (Bridge) schreiben ----------
bold "Installiere BLE-Peripheral…"
cat > "$SRC" <<'SWIFTEOF'
import Foundation
import CoreBluetooth

let kServiceUUID        = CBUUID(string: "CC1A0DE0-0000-1000-8000-00805F9B34FB")
let kCharacteristicUUID = CBUUID(string: "CC1A0DE0-0001-1000-8000-00805F9B34FB")
let kStatePath   = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-state")
let kSessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
let kCursorState = (NSHomeDirectory() as NSString).appendingPathComponent(".codefocus/cursor-state")
let kCodexState  = (NSHomeDirectory() as NSString).appendingPathComponent(".codefocus/codex-state")
let kAgentTTL: TimeInterval = 180   // Hook-Heartbeat gilt max. 3 min (Crash-Schutz)

// Hook-basierter Agent (Cursor, Codex): der Hook schreibt "active"/"idle" + frische mtime.
// active(1) nur, wenn Inhalt "active" UND mtime jünger als TTL (sonst hängendes
// "active" nach Agent-Crash). Spiegelbild der pid-Lebendprüfung bei Claude.
func hookAgentActive(_ path: String) -> Bool {
    let fm = FileManager.default
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
          raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active",
          let attrs = try? fm.attributesOfItem(atPath: path),
          let mtime = attrs[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(mtime) < kAgentTTL
}

// Liest Claude Codes EIGENE Session-Status-Dateien: ~/.claude/sessions/<pid>.json.
// active(1) = irgendeine interaktive CLI-Session hat status "busy" (und der Prozess lebt).
// "busy" steht den GANZEN Turn an — auch beim Denken/Plan-Mode (kein Timeout, keine
// Fehl-Locks) — und flippt bei Fertigwerden UND bei ESC innerhalb ~1-2s auf "idle".
// SDK-Sessions (z.B. claude-mem Observer, entrypoint "sdk-cli") werden ignoriert.
func readState() -> UInt8 {
    let fm = FileManager.default
    // 1) Claude Code: eigene Session-Dateien (~/.claude/sessions/<pid>.json).
    //    Verzeichnis fehlt bei Cursor-/Codex-only-Usern -> dann NICHT abbrechen, weiterprüfen.
    if let files = try? fm.contentsOfDirectory(atPath: kSessionsDir) {
        for name in files where name.hasSuffix(".json") {
            let path = (kSessionsDir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["entrypoint"] as? String) == "cli",
                  (obj["status"] as? String) == "busy"
            else { continue }
            // Prozess noch am Leben? Verhindert hängendes "busy" nach Crash/Kill.
            if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0 { continue }
            return 1
        }
    }
    // 2) Hook-basierte Agents: Cursor und Codex.
    if hookAgentActive(kCursorState) { return 1 }
    if hookAgentActive(kCodexState)  { return 1 }
    return 0
}

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    var characteristic: CBMutableCharacteristic!
    var last: UInt8 = 255
    var advertising = false

    func start() {
        // Initialen Zustand für den Simulator-Bridge schreiben (Host liest claude-state).
        try? (readState() == 1 ? "active" : "idle").write(toFile: kStatePath, atomically: true, encoding: .utf8)
        manager = CBPeripheralManager(delegate: self, queue: nil)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        guard advertising else { return }
        let v = readState()
        characteristic.value = Data([v])   // immer aktuell halten — fürs aktive Re-Read vom iPhone
        if v != last {
            // claude-state für den Simulator-Bridge spiegeln (Host liest diese Datei)
            try? (v == 1 ? "active" : "idle").write(toFile: kStatePath, atomically: true, encoding: .utf8)
            // updateValue kann false liefern (Sende-Queue voll). Dann last NICHT setzen,
            // damit der nächste Poll den Notify erneut versucht (statt ihn zu verschlucken).
            if manager.updateValue(Data([v]), for: characteristic, onSubscribedCentrals: nil) {
                last = v
            }
        }
    }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        let names = ["unknown","resetting","unsupported","unauthorized","poweredOff","poweredOn"]
        let s = p.state.rawValue
        print("CodeFocus: Bluetooth-Status =", s >= 0 && s < names.count ? names[s] : "\(s)")
        if p.state == .unauthorized {
            print("CodeFocus: ⚠️ Keine Bluetooth-Erlaubnis. Systemeinstellungen → Datenschutz → Bluetooth → CodeFocus aktivieren.")
        }
        guard p.state == .poweredOn else { return }
        last = readState()
        characteristic = CBMutableCharacteristic(type: kCharacteristicUUID,
            properties: [.read, .notify], value: nil, permissions: [.readable])
        let svc = CBMutableService(type: kServiceUUID, primary: true)
        svc.characteristics = [characteristic]
        manager.add(svc)
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        // Echten Mac-Namen senden, damit das iPhone im "Choose your Mac"-Picker
        // den richtigen Mac erkennt (statt generisch "ClaudeMac").
        let name = Host.current().localizedName ?? "Mac"
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [kServiceUUID],
            CBAdvertisementDataLocalNameKey: name
        ])
        advertising = true
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
        r.value = Data([readState()])
        manager.respond(to: r, withResult: .success)
    }
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
        didSubscribeTo c: CBCharacteristic) {
        last = readState()
        manager.updateValue(Data([last]), for: characteristic, onSubscribedCentrals: [central])
    }
}

let p = Peripheral()
p.start()
RunLoop.main.run()
SWIFTEOF

swiftc -O "$SRC" -o "$BIN" || die "Kompilierung fehlgeschlagen."
ok "BLE-Peripheral kompiliert"

# App-Bundle-Identität → Bluetooth-Dialog zeigt "CodeFocus" + eigene Erklärung
cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CodeFocus</string>
  <key>CFBundleDisplayName</key><string>CodeFocus</string>
  <key>CFBundleIdentifier</key><string>app.codefocus.peripheral</string>
  <key>CFBundleExecutable</key><string>CodeFocus</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>CodeFocus connects to your iPhone over Bluetooth to share when your AI coding tool is working.</string>
</dict>
</plist>
PLISTEOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
ok "CodeFocus.app erstellt (Bluetooth-Dialog zeigt \"CodeFocus\")"

# claude-state-Datei anlegen (für Simulator-Bridge), falls ~/.claude existiert
[ -d "$CLAUDE_DIR" ] && [ ! -f "$STATE_FILE" ] && printf idle > "$STATE_FILE"

# ---------- 3. Claude: frühere CodeFocus-Hooks entfernen ----------
# Der neue Ansatz liest Claude Codes native Session-Status — keine Hooks nötig.
# Unsere alten Einträge (printf claude-state / hook.py) werden entfernt, fremde bleiben.
if want claude && [ -f "$SETTINGS" ]; then
  bold "Räume frühere Claude-Hooks auf…"
  "$PYTHON" - "$SETTINGS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(0)
hooks = cfg.get("hooks", {})
def strip_ours(arr):
    out = []
    for group in arr:
        kept = [h for h in group.get("hooks", [])
                if "claude-state" not in h.get("command", "")
                and "codefocus/hook.py" not in h.get("command", "")]
        if kept:
            group["hooks"] = kept
            out.append(group)
    return out
for ev in ("UserPromptSubmit", "Stop", "SessionEnd", "Notification"):
    if ev in hooks:
        hooks[ev] = strip_ours(hooks[ev])
        if not hooks[ev]:
            del hooks[ev]
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
  ok "Claude Code nutzt native Session-Status (keine Hooks nötig)"
fi

# ---------- 4. Cursor-Hook ----------
if want cursor; then
  bold "Richte Cursor-Hook ein…"
  cat > "$CURSOR_HOOK" <<'EOF'
#!/bin/bash
# CodeFocus — Cursor-Hook: schreibt Cursor-Agent-Status nach ~/.codefocus/cursor-state
STATE="${1:-idle}"
cat >/dev/null 2>&1 || true            # stdin (Cursor Event-JSON) verwerfen
mkdir -p "$HOME/.codefocus"
printf '%s' "$STATE" > "$HOME/.codefocus/cursor-state"
printf '{"continue": true}\n'          # Cursor: Aktion normal weiterlaufen lassen
EOF
  chmod +x "$CURSOR_HOOK"
  mkdir -p "$HOME/.cursor"
  "$PYTHON" - "$CURSOR_HOOKS_JSON" "$CURSOR_HOOK" <<'PYEOF'
import json, os, sys
path, script = sys.argv[1], sys.argv[2]
active = ["beforeSubmitPrompt", "afterFileEdit", "afterShellExecution", "postToolUse"]
cfg = {}
if os.path.exists(path):
    try: cfg = json.load(open(path))
    except Exception: cfg = {}
cfg.setdefault("version", 1)
h = cfg.setdefault("hooks", {})
marker = os.path.basename(script)   # entfernt auch alte CodeFocus-Hooks mit anderem Pfad
def clean(arr):
    return [x for x in arr if isinstance(x, dict) and marker not in x.get("command", "")]
def add(ev, arg):
    a = clean(h.get(ev, []))
    a.append({"command": script + " " + arg})
    h[ev] = a
for e in active: add(e, "active")
add("stop", "idle")
add("sessionEnd", "idle")
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
  ok "Cursor-Hook installiert (~/.cursor/hooks.json) — Cursor neu starten"
fi

# ---------- 5. Codex-Hook ----------
if want codex; then
  bold "Richte Codex-Hook ein…"
  cat > "$CODEX_HOOK" <<'EOF'
#!/bin/bash
# CodeFocus — Codex-Hook: schreibt Codex-Agent-Status nach ~/.codefocus/codex-state
STATE="${1:-idle}"
cat >/dev/null 2>&1 || true            # stdin (Codex Event-JSON) verwerfen
mkdir -p "$HOME/.codefocus"
printf '%s' "$STATE" > "$HOME/.codefocus/codex-state"
exit 0
EOF
  chmod +x "$CODEX_HOOK"
  mkdir -p "$HOME/.codex"
  "$PYTHON" - "$CODEX_HOOKS_JSON" "$CODEX_HOOK" <<'PYEOF'
import json, os, sys
path, script = sys.argv[1], sys.argv[2]
active = ["UserPromptSubmit", "PreToolUse", "PostToolUse"]
cfg = {}
if os.path.exists(path):
    try: cfg = json.load(open(path))
    except Exception: cfg = {}
h = cfg.setdefault("hooks", {})
marker = os.path.basename(script)   # entfernt auch alte CodeFocus-Hooks mit anderem Pfad
def clean(arr):
    out = []
    for g in arr:
        inner = g.get("hooks", []) if isinstance(g, dict) else []
        if any(marker in hh.get("command", "") for hh in inner):
            continue
        out.append(g)
    return out
def add(ev, arg):
    a = clean(h.get(ev, []))
    a.append({"hooks": [{"type": "command", "command": script + " " + arg}]})
    h[ev] = a
for e in active: add(e, "active")
add("Stop", "idle")
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
  ok "Codex-Hook installiert (~/.codex/hooks.json)"
  warn "Codex verlangt manuelle Freigabe: Codex → Einstellungen → Hooks →"
  echo "      bei allen CodeFocus-Hooks auf \"Vertrauen\" + Schalter AN."
fi

# ---------- 6. LaunchAgent (Autostart) ----------
bold "Richte Autostart ein…"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.codefocus.peripheral</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" 2>/dev/null || true
ok "Autostart eingerichtet (läuft ab jetzt bei jedem Login)"

# ---------- 7. Fertig ----------
echo ""
bold "✅ Fertig! Eingerichtet für: ${TOOLS[*]}"
echo ""
bold "Beim ersten Start fragt macOS nach Bluetooth-Erlaubnis → bitte erlauben."
echo "(Falls kein Dialog kommt: Systemeinstellungen → Datenschutz → Bluetooth → CodeFocus aktivieren)"
want cursor && echo "Cursor: einmal NEU STARTEN, damit die Hooks geladen werden."
want codex  && echo "Codex:  Einstellungen → Hooks → CodeFocus-Hooks \"Vertrauen\" + aktivieren."
echo ""
bold "Öffne jetzt die CodeFocus-App auf deinem iPhone und verbinde dich."
echo ""
echo "Status:    tail -f $LOG"
echo "Entfernen: launchctl unload $PLIST && rm -rf $CF_DIR \"$PLIST\""
echo ""
