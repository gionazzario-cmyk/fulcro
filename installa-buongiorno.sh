#!/bin/bash
# Il buongiorno delle 7:30, anche con Jarvis chiuso.
#   bash installa-buongiorno.sh on|off|stato|prova
set -euo pipefail
cd "$(dirname "$0")"
PLIST="$HOME/Library/LaunchAgents/digio.jarvis.buongiorno.plist"
LABEL="digio.jarvis.buongiorno"
BIN="$PWD/Jarvis.app/Contents/MacOS/Jarvis"
LOG="$HOME/.jarvis/logs/buongiorno.log"

case "${1:-stato}" in
  on)
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.jarvis/logs"
    [ -x "$BIN" ] || { echo "manca $BIN: lancia prima install.sh"; exit 1; }
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--briefing</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>7</integer><key>Minute</key><integer>30</integer></dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Attivo: ogni giorno alle 7:30 (anche a Jarvis chiuso). Log: $LOG"
    ;;
  off)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Buongiorno disattivato."
    ;;
  prova)
    echo "-- calcolo e notifica adesso --"
    "$BIN" --briefing
    ;;
  stato|*)
    echo "servizio: $(launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo ATTIVO || echo 'NON attivo')"
    echo "file: $([ -f "$HOME/.jarvis/buongiorno.json" ] && echo presente || echo assente)"
    echo "--- ultime 6 righe ---"
    tail -6 "$LOG" 2>/dev/null || echo "(nessun log)"
    ;;
esac
