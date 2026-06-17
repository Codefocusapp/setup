#!/bin/bash
#
# CodeFocus — Mac Setup
# Verbindet Claude Code mit der CodeFocus iPhone-App über Bluetooth.
# Nutzung:  curl -fsSL https://raw.githubusercontent.com/codefocusapp/setup/main/install.sh | bash
#
set -e

CF_DIR="$HOME/.codefocus"
CLAUDE_DIR="$HOME/.claude"
STATE_FILE="$CLAUDE_DIR/claude-state"
SETTINGS="$CLAUDE_DIR/settings.json"
PLIST="$HOME/Library/LaunchAgents/app.codefocus.peripheral.plist"
APP="$CF_DIR/CodeFocus.app"
BIN="$APP/Contents/MacOS/CodeFocus"
SRC="$CF_DIR/CodeFocus.swift"
LOG="$CF_DIR/codefocus.log"
# Alt-Setup (frühere "Earned"-Version) zum Aufräumen
OLD_DIR="$HOME/.earned"
OLD_PLIST="$HOME/Library/LaunchAgents/app.earned.peripheral.plist"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$1"; exit 1; }

echo ""
bold "🔒 CodeFocus — Mac Setup"
echo "Verbindet Claude Code mit deiner CodeFocus iPhone-App."
echo ""

# ---------- 1. Checks ----------
[ "$(uname)" = "Darwin" ] || die "Earned läuft nur auf macOS."

if ! command -v swiftc >/dev/null 2>&1; then
  warn "Xcode Command Line Tools fehlen (für die Kompilierung)."
  echo "  Bitte ausführen:  xcode-select --install"
  echo "  Danach dieses Script erneut starten."
  die "swiftc nicht gefunden."
fi
ok "Xcode Command Line Tools gefunden"

if [ ! -d "$CLAUDE_DIR" ]; then
  warn "Claude Code scheint nicht installiert (~/.claude fehlt)."
  echo "  Earned braucht Claude Code. Installiere es zuerst: https://claude.com/claude-code"
  die "Claude Code nicht gefunden."
fi
ok "Claude Code gefunden"

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || die "python3 nicht gefunden (kommt mit Xcode CLT)."

# Alt-Setup (frühere "Earned"-Version) aufräumen
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -rf "$OLD_DIR" "$OLD_PLIST" 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"

# ---------- 2. BLE-Peripheral schreiben ----------
bold "Installiere BLE-Peripheral…"
cat > "$SRC" <<'SWIFTEOF'
import Foundation
import CoreBluetooth

let kServiceUUID        = CBUUID(string: "CC1A0DE0-0000-1000-8000-00805F9B34FB")
let kCharacteristicUUID = CBUUID(string: "CC1A0DE0-0001-1000-8000-00805F9B34FB")
let kStatePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-state")

// Reiner Inhalts-Check: "active" = entsperrt, bis Stop/SessionEnd "idle"/"closed" schreibt.
// Kein Staleness-Timeout — sonst sperrt es in tool-call-losen Modes (langes Denken,
// Plan-Mode, Rückfragen) fälschlich.
func readState() -> UInt8 {
    guard let raw = try? String(contentsOfFile: kStatePath, encoding: .utf8) else { return 0 }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "active" ? 1 : 0
}

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    var characteristic: CBMutableCharacteristic!
    var last: UInt8 = 255
    var advertising = false

    func start() {
        // Nach Mac-Neustart/Crash aufräumen: es läuft keine Session mehr. Marker leeren
        // und State auf idle, damit kein „hängender" entsperrter Zustand übrig bleibt.
        let home = NSHomeDirectory() as NSString
        try? FileManager.default.removeItem(atPath: home.appendingPathComponent(".claude/codefocus-sessions"))
        try? "idle".write(toFile: kStatePath, atomically: true, encoding: .utf8)
        manager = CBPeripheralManager(delegate: self, queue: nil)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        guard advertising else { return }
        let v = readState()
        characteristic.value = Data([v])   // immer aktuell halten — fürs aktive Re-Read vom iPhone
        if v != last {
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
        print("Earned: Bluetooth-Status =", s >= 0 && s < names.count ? names[s] : "\(s)")
        if p.state == .unauthorized {
            print("Earned: ⚠️ Keine Bluetooth-Erlaubnis. Systemeinstellungen → Datenschutz → Bluetooth → earned-ble aktivieren.")
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
  <string>CodeFocus connects to your iPhone over Bluetooth to share when Claude Code is working.</string>
</dict>
</plist>
PLISTEOF
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
ok "CodeFocus.app erstellt (Bluetooth-Dialog zeigt \"CodeFocus\")"

# ---------- 3. State-Datei + Session-Tracking ----------
printf idle > "$STATE_FILE"
mkdir -p "$CLAUDE_DIR/codefocus-sessions"

# Hook-Helper: pflegt einen Marker pro Claude-Session und leitet daraus den
# Gesamt-State ab. So bleibt die App entsperrt, solange IRGENDEIN Fenster arbeitet —
# Fensterwechsel oder mehrere parallele Sessions führen nicht mehr zu Fehl-Locks.
cat > "$CF_DIR/hook.py" <<'HOOKEOF'
import sys, json, os

mode = sys.argv[1] if len(sys.argv) > 1 else "add"
claude = os.path.expanduser("~/.claude")
sdir = os.path.join(claude, "codefocus-sessions")
os.makedirs(sdir, exist_ok=True)

# session_id kommt als JSON auf stdin (Claude-Code-Hook-Payload)
try:
    sid = (json.load(sys.stdin) or {}).get("session_id") or "default"
except Exception:
    sid = "default"
sid = "".join(c for c in sid if c.isalnum() or c in "-_") or "default"  # Dateiname säubern
marker = os.path.join(sdir, sid)

if mode == "add":
    open(marker, "w").close()          # Session arbeitet → Marker an
else:
    try:
        os.remove(marker)              # Session fertig/geschlossen → Marker weg
    except FileNotFoundError:
        pass

# active = solange noch IRGENDEIN Marker existiert
active = False
with os.scandir(sdir) as it:
    for _ in it:
        active = True
        break

with open(os.path.join(claude, "claude-state"), "w") as f:
    f.write("active" if active else "idle")
HOOKEOF
ok "Session-Tracking installiert (mehrere Claude-Fenster werden korrekt zusammengeführt)"

# ---------- 4. Claude-Hooks mergen (idempotent) ----------
bold "Verbinde Claude Code (Hooks)…"
"$PYTHON" - "$SETTINGS" "$CF_DIR/hook.py" <<'PYEOF'
import json, os, sys
path, hook = sys.argv[1], sys.argv[2]
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f: cfg = json.load(f)
    except Exception:
        cfg = {}
cfg.setdefault("hooks", {})

# Alte CodeFocus/Earned-Hooks entfernen (frühere "printf … > claude-state" sowie
# vorherige hook.py-Einträge) — damit Mehrfach-Installation sauber migriert statt
# zu duplizieren. Fremde Hooks bleiben unangetastet.
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
    if ev in cfg["hooks"]:
        cfg["hooks"][ev] = strip_ours(cfg["hooks"][ev])

def add(event, mode, matcher=None):
    arr = cfg["hooks"].setdefault(event, [])
    group = {"hooks": [{"type": "command", "command": "python3 %s %s" % (hook, mode)}]}
    if matcher is not None:
        group["matcher"] = matcher
    arr.append(group)

add("UserPromptSubmit", "add")                 # Prompt ab → Marker an
add("Stop", "remove")                          # Antwort fertig → Marker weg
add("SessionEnd", "remove")                    # Session zu → Marker weg
add("Notification", "remove", "idle_prompt")   # zurück im Idle-Prompt (auch nach ESC!) → Marker weg

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("hooks ok")
PYEOF
ok "Hooks aktualisiert (Session-basiert; fremde Hooks unangetastet)"

# ---------- 5. LaunchAgent (Autostart) ----------
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

# ---------- 6. Fertig ----------
echo ""
bold "✅ Fertig!"
echo ""
bold "Beim ersten Start fragt macOS nach Bluetooth-Erlaubnis → bitte erlauben."
echo "(Falls kein Dialog kommt: Systemeinstellungen → Datenschutz → Bluetooth → CodeFocus aktivieren)"
echo ""
bold "Öffne jetzt die CodeFocus-App auf deinem iPhone und verbinde dich."
echo ""
echo "Status:    tail -f $LOG"
echo "Entfernen: launchctl unload $PLIST && rm -rf $CF_DIR \"$PLIST\""
echo ""
