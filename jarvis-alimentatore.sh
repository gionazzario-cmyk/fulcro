#!/bin/zsh
# Avvia Jarvis quando attacchi l'alimentatore. Cosa fa a batteria lo decide l'app,
# con la scelta in ~/.jarvis/passo.txt: `dormi` (resta aperta e dorme), `esci`
# (si chiude da sola, consumo zero) o `lavora`. Qui non la uccidiamo: se la scelta
# e' `esci` ci pensa lei, subito, appena sente il cavo uscire.
# Lo lancia il LaunchAgent digio.jarvis.power ogni 60 secondi: niente sudo.
#
# JARVIS_POWER_OVERRIDE=AC|BATT serve solo per provarlo senza staccare il cavo.

APP="$HOME/programmi/jarvis/Jarvis.app"
DIR="$HOME/.jarvis"
STATE="$DIR/alimentatore.stato"
STANDBY="$DIR/standby"
LOG="$DIR/logs/alimentatore.log"
PATTERN="Jarvis.app/Contents/MacOS/Jarvis"

mkdir -p "$DIR/logs"

case "${JARVIS_POWER_OVERRIDE:-}" in
  AC) NOW=AC ;;
  BATT) NOW=BATT ;;
  *)
    case "$(pmset -g batt 2>/dev/null | head -1)" in
      *"AC Power"*)      NOW=AC ;;
      *"Battery Power"*) NOW=BATT ;;
      *)                 exit 0 ;;
    esac
    ;;
esac

running() { pgrep -f "$PATTERN" >/dev/null 2>&1; }

log() { print -r -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [[ "$NOW" == AC ]]; then
  # "Jarvis e' gia' aperto" non e' un errore: lo lascio stare.
  if running; then exit 0; fi
  # Esci premuto nel pannello = non riaprirlo finche' non stacchi e riattacchi.
  if [[ -f "$STANDBY" ]]; then exit 0; fi
  [[ -d "$APP" ]] || { log "manca $APP"; exit 0; }
  open "$APP" && log "aperto perche' alimentatore attaccato"
  print -r -- AC > "$STATE"
else
  print -r -- BATT > "$STATE"
  rm -f "$STANDBY"
  # A batteria l'app fa quello che dice passo.txt (dal 2026-10-30: `esci`, si chiude
  # da sola appena il cavo esce, e non lascia il flag `standby`, quindi riattaccando
  # riparte). JARVIS_POWER_STACCA=1 resta come rete di sicurezza per le build vecchie,
  # che senza questo non si chiuderebbero mai.
  if [[ "${JARVIS_POWER_STACCA:-0}" == "1" ]] && running; then
    pkill -f "$PATTERN" && log "chiuso perche' sei passato a batteria (vecia regola)"
  fi
fi
exit 0
