<div align="center">

# CodeFocus

### Phone time while your AI codes. Locks when it stops.

CodeFocus locks the distracting apps on your iPhone — TikTok, Instagram, whatever eats your day — and only unlocks them while an AI coding agent like **Claude Code** is actually running on your Mac. It stops, your apps lock. No willpower. Pure leverage.

<a href="https://apps.apple.com/app/id6781040937"><img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="54"></a>

<!-- TODO: drop a demo.gif here — phone blocked → claude runs on Mac → phone unlocks -->

</div>

---

## How it works

```
   Your Mac                           Your iPhone
 ┌────────────────┐                 ┌────────────────┐
 │  Claude Code   │    Bluetooth    │   CodeFocus    │
 │  working  ─────────────────────▶ │  apps unlocked │
 │  idle / ESC ───────────────────▶ │  apps locked   │
 └────────────────┘                 └────────────────┘
```

A tiny open-source helper on your Mac reads whether Claude Code is actively working (straight from Claude's own session state) and advertises it over Bluetooth LE. Your iPhone reads that and locks/unlocks the apps you picked — in real time, fully on-device.

## Setup — two parts

### 1. Get the app

**[Download CodeFocus on the App Store →](https://apps.apple.com/app/id6781040937)**

### 2. Connect your Mac

Paste this once into your Mac's **Terminal**:

```bash
curl -fsSL https://raw.githubusercontent.com/codefocusapp/setup/main/install.sh | bash
```

It compiles a small Bluetooth peripheral locally, reads Claude Code's session status so it knows when your agent is active (no hooks, nothing intrusive), and runs at login. Fully local, readable source — you can inspect [`install.sh`](install.sh) before running it.

### 3. Pair

Open **CodeFocus**, allow Screen Time + Bluetooth, pick the apps to lock, and connect to your Mac. Done — your phone unlocks while your agent codes and locks the moment it stops.

## Requirements

- iPhone + the CodeFocus app
- macOS with Bluetooth
- [Claude Code](https://claude.com/claude-code) (or another agent that runs in your terminal)
- Xcode Command Line Tools — `xcode-select --install`

## Privacy

CodeFocus collects **nothing** — no account, no servers, no tracking. Everything stays on your devices.
[Privacy Policy](https://codefocusapp.github.io/setup/privacy.html) · [Terms of Use](https://codefocusapp.github.io/setup/terms.html)

## Uninstall (Mac side)

```bash
launchctl unload ~/Library/LaunchAgents/app.codefocus.peripheral.plist
rm -rf ~/.codefocus ~/Library/LaunchAgents/app.codefocus.peripheral.plist
```

---

<div align="center">

Made for developers with no willpower. 🟠

</div>
