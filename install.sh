#!/bin/bash
#
# Earned — Mac Setup
# Verbindet Claude Code mit der Earned iPhone-App über Bluetooth.
# Nutzung:  curl -fsSL https://earned.app/install.sh | bash
#
set -e

EARNED_DIR="$HOME/.earned"
CLAUDE_DIR="$HOME/.claude"
STATE_FILE="$CLAUDE_DIR/claude-state"
SETTINGS="$CLAUDE_DIR/settings.json"
PLIST="$HOME/Library/LaunchAgents/app.earned.peripheral.plist"
BIN="$EARNED_DIR/earned-ble"
SRC="$EARNED_DIR/earned-ble.swift"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "\033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "\033[33m!\033[0m %s\n" "$1"; }
die()  { printf "\033[31m✗ %s\033[0m\n" "$1"; exit 1; }

echo ""
bold "🔒 Earned — Mac Setup"
echo "Verbindet Claude Code mit deiner Earned iPhone-App."
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

mkdir -p "$EARNED_DIR" "$HOME/Library/LaunchAgents"

# ---------- 2. BLE-Peripheral schreiben ----------
bold "Installiere BLE-Peripheral…"
cat > "$SRC" <<'SWIFTEOF'
import Foundation
import CoreBluetooth

let kServiceUUID        = CBUUID(string: "CC1A0DE0-0000-1000-8000-00805F9B34FB")
let kCharacteristicUUID = CBUUID(string: "CC1A0DE0-0001-1000-8000-00805F9B34FB")
let kStatePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/claude-state")

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
        manager = CBPeripheralManager(delegate: self, queue: nil)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }
    func poll() {
        guard advertising else { return }
        let v = readState()
        if v != last {
            last = v
            characteristic.value = Data([v])
            manager.updateValue(Data([v]), for: characteristic, onSubscribedCentrals: nil)
        }
    }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        last = readState()
        characteristic = CBMutableCharacteristic(type: kCharacteristicUUID,
            properties: [.read, .notify], value: nil, permissions: [.readable])
        let svc = CBMutableService(type: kServiceUUID, primary: true)
        svc.characteristics = [characteristic]
        manager.add(svc)
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [kServiceUUID],
            CBAdvertisementDataLocalNameKey: "ClaudeMac"
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

# ---------- 3. State-Datei ----------
[ -f "$STATE_FILE" ] || printf idle > "$STATE_FILE"

# ---------- 4. Claude-Hooks mergen (idempotent) ----------
bold "Verbinde Claude Code (Hooks)…"
"$PYTHON" - "$SETTINGS" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
home_state = '"$HOME/.claude/claude-state"'  # via shell ausgewertet zur Hook-Laufzeit
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f: cfg = json.load(f)
    except Exception:
        cfg = {}
cfg.setdefault("hooks", {})

def add(event, value):
    arr = cfg["hooks"].setdefault(event, [])
    cmd = "printf %s > %s" % (value, home_state)
    # schon vorhanden? (idempotent)
    for group in arr:
        for h in group.get("hooks", []):
            if h.get("command", "").strip() == cmd:
                return
    arr.append({"hooks": [{"type": "command", "command": cmd}]})

add("UserPromptSubmit", "active")
add("Stop", "idle")
add("SessionEnd", "closed")

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("hooks ok")
PYEOF
ok "Hooks in settings.json eingetragen (bestehende unangetastet)"

# ---------- 5. LaunchAgent (Autostart) ----------
bold "Richte Autostart ein…"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>app.earned.peripheral</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$EARNED_DIR/earned.log</string>
  <key>StandardErrorPath</key><string>$EARNED_DIR/earned.log</string>
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
echo "(Falls kein Dialog kommt: Systemeinstellungen → Datenschutz → Bluetooth → earned-ble aktivieren)"
echo ""
bold "Öffne jetzt die Earned-App auf deinem iPhone und verbinde dich."
echo ""
echo "Status:    tail -f $EARNED_DIR/earned.log"
echo "Entfernen: launchctl unload $PLIST && rm -rf $EARNED_DIR \"$PLIST\""
echo ""
