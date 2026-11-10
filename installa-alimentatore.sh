#!/bin/bash
# Gestisce l'avvio di Jarvis legato all'alimentatore. Nessuna password, niente sudo.
#   bash installa-alimentatore.sh on      -> Jarvis si apre da solo quando attacchi la corrente
#   bash installa-alimentatore.sh off     -> stop: niente piu' avvio automatico
#   bash installa-alimentatore.sh prova   -> simula "attacchi" e "stacchi" senza muovere il cavo
#   bash installa-alimentatore.sh stato   -> cosa sta succedendo adesso
set -euo pipefail
cd "$(dirname "$0")"
PLIST="$HOME/Library/LaunchAgents/digio.jarvis.power.plist"
LABEL="digio.jarvis.power"
SCRIPT="$PWD/jarvis-alimentatore.sh"

case "${1:-stato}" in
  on)
    chmod +x "$SCRIPT"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>/tmp/$LABEL.log</string>
  <key>StandardErrorPath</key><string>/tmp/$LABEL.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Attivo: controllo ogni 60 s cosa succede in ~/.jarvis/logs/alimentatore.log"
    ;;
  off)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Avvio automatico disattivato. Jarvis resta installato: Aprilo tu quando vuoi."
    ;;
  prova)
    echo "-- simulo ATTACCATO --"
    JARVIS_POWER_OVERRIDE=AC /bin/zsh "$SCRIPT"; sleep 3
    pgrep -f "Jarvis.app/Contents/MacOS/Jarvis" >/dev/null && echo "   Jarvis aperto: ok" || echo "   Jarvis NON aperto (hai premuto Esci? riattacca e stacca)"
    echo "-- simulo STACCATO --"
    # JARVIS_POWER_STACCA=1: lo stacco simulato non manda nessuna notifica vera al
    # sistema, quindi l'app non puo' accorgersene da sola. Qui la chiudiamo noi, cosi'
    # il controllo qui sotto misura davvero qualcosa.
    JARVIS_POWER_OVERRIDE=BATT JARVIS_POWER_STACCA=1 /bin/zsh "$SCRIPT"; sleep 2
    pgrep -f "Jarvis.app/Contents/MacOS/Jarvis" >/dev/null && echo "   Jarvis ancora aperto: FAIL" || echo "   Jarvis chiuso: ok"
    echo "(rimetto lo stato vero)"
    /bin/zsh "$SCRIPT"
    ;;
  stato|*)
    echo "servizio: $(launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo ATTIVO || echo 'NON attivo')"
    echo "corrente: $(pmset -g batt | head -1)"
    echo "stato ultimo giro: $(cat "$HOME/.jarvis/alimentatore.stato" 2>/dev/null || echo 'ancora nessun giro')"
    echo "Jarvis: $(pgrep -f 'Jarvis.app/Contents/MacOS/Jarvis' >/dev/null && echo APERTO || echo chiuso)"
    echo "standby (Esci premuto): $([ -f "$HOME/.jarvis/standby" ] && echo SI || echo no)"
    echo "--- ultime 8 righe di log ---"
    tail -8 "$HOME/.jarvis/logs/alimentatore.log" 2>/dev/null || echo "(nessun log)"
    ;;
esac
