# Earned — Mac Setup

Connects **Claude Code** on your Mac to the **Earned** iPhone app over Bluetooth.
When Claude Code is working, Earned unlocks your distracting apps; when it stops, they lock again.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jonasmuth04-pixel/earned-mac/main/install.sh | bash
```

The script:
- compiles a tiny Bluetooth peripheral locally (no notarization, fully readable source),
- adds hooks to your `~/.claude/settings.json` that report when Claude is active/idle (existing hooks are preserved),
- installs a LaunchAgent so it runs automatically at login.

## Requirements
- macOS
- [Claude Code](https://claude.com/claude-code)
- Xcode Command Line Tools (`xcode-select --install`)

## Uninstall
```bash
launchctl unload ~/Library/LaunchAgents/app.earned.peripheral.plist
rm -rf ~/.earned ~/Library/LaunchAgents/app.earned.peripheral.plist
```

100% local & open source — nothing runs through third-party servers.
