#!/bin/bash
# Fa partire Jarvis da solo quando accendi il Mac. Opzionale: eseguilo solo se lo vuoi.
#   bash avvio-automatico.sh on     -> parte al login
#   bash avvio-automatico.sh off    -> basta avvio automatico
set -euo pipefail
cd "$(dirname "$0")"
PLIST="$HOME/Library/LaunchAgents/digio.jarvis.plist"
APP="$PWD/Jarvis.app"

case "${1:-}" in
  on)
    test -d "$APP" || { echo "Prima esegui: bash install.sh"; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>digio.jarvis</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "Fatto: Jarvis parte ad ogni login."
    ;;
  off)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Avvio automatico tolto (Jarvis resta installato)."
    ;;
  *)
    echo "Uso: bash avvio-automatico.sh on   |   bash avvio-automatico.sh off"
    ;;
esac
