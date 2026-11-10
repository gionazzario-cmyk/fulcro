#!/bin/bash
# Costruisce Jarvis.app nella cartella del progetto. Riesegui questo dopo ogni modifica al codice.
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/6] compilo in modalità release (20-40 s)..."
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Jarvis"
test -x "$BIN" || { echo "binary non trovata: $BIN"; exit 1; }

echo "[2/6] costruisco Jarvis.app..."
APP="Jarvis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
cp "$BIN" "$APP/Contents/MacOS/Jarvis"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# L'icona buona e AppIcon.icns (quella dell'orbite rosso): finisce nel bundle come Jarvis.icns
# perche' Info.plist dice CFBundleIconFile = Jarvis.
ICON="Resources/AppIcon.icns"
test -f "$ICON" || ICON="Resources/Jarvis.icns"
cp "$ICON" "$APP/Contents/Resources/Jarvis.icns"
cp Tools/arduino_bridge.py Tools/stl_bridge.py Tools/bambu_bridge.py "$APP/Contents/Resources/Tools/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "[3/6] firma dell'app..."
# La firma stabile (Jarvis Locale) fa restare i permessi di macOS dopo ogni ricompilazione.
# Attenzione: se il portachiavi chiede un clic e nessuno clicca, codesign si impalla.
# Quindi la prova ha un tempo limite, poi si passa alla firma ad-hoc.
firma_stabile() {
  codesign --force --deep --sign "Jarvis Locale" "$APP" >/dev/null 2>&1 &
  local pid=$! i=0
  while [ $i -lt 25 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1; i=$((i + 1))
  done
  kill -9 "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 1
}
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Jarvis Locale" && firma_stabile; then
  echo "      firmata con Jarvis Locale (permessi stabili)"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && \
    echo "      firmata AD-HOC: macOS potra' chiederti di nuovo microfono/schermo."
  echo "      (se il portachiavi chiedeva un clic, quel clic non e' arrivato)"
fi

echo "[4/6] pyserial per parlare con Arduino..."
if python3 -c "import serial" 2>/dev/null; then
  echo "      gia' presente"
elif python3 -m pip install --user --quiet pyserial 2>/dev/null; then
  echo "      installata"
else
  echo "      NON installata: la skill Arduino non potra' rispondere"
fi

echo "[5/6] controllo i pezzi che servono..."
ok=1
if command -v /opt/homebrew/bin/whisper-cli >/dev/null 2>&1 || command -v /usr/local/bin/whisper-cli >/dev/null 2>&1; then
  echo "      whisper-cli: ok"
else
  ok=0; echo "      whisper-cli MANCANTE ->  brew install whisper-cpp"
fi
if [ -f "$HOME/.jarvis/models/ggml-small.bin" ]; then
  echo "      modello di ascolto: ok"
else
  ok=0; echo "      modello ascolto MANCANTE ->  curl -L -o ~/.jarvis/models/ggml-small.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
fi
if curl -s --max-time 8 http://127.0.0.1:11434/api/version >/dev/null 2>&1 \
   || curl -s --max-time 8 http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
  echo "      Ollama in esecuzione: ok"
else
  ok=0; echo "      Ollama spento o troppo impegnato: Aprilo dalle App (non serve il Terminale)"
fi
MODELS="$(ollama list 2>/dev/null || true)"
case "$MODELS" in
  *qwen3:8b*) echo "      qwen3:8b: ok" ;;
  *) ok=0; echo "      qwen3:8b non ancora scaricato ->  ollama pull qwen3:8b" ;;
esac

echo "[6/6] auto-test..."
"$APP/Contents/MacOS/Jarvis" --test || true

echo
if [ "$ok" -eq 1 ]; then
  echo "TUTTO PRONTO: apri $APP con doppio clic (l'icona appare nella barra dei menu in alto)."
else
  echo "App costruita, ma manca qualcosa qua sopra. Scrivi a Qoder cosa vedi."
fi
