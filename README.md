# Fulcro

Assistente vocale locale per macOS con **Ollama**, **Whisper** e **Piper**.
L'obiettivo è semplice: scaricare l'app, aprirla e farla funzionare in locale,
senza dipendere da API cloud.

## Cosa fa

- Ascolta e trascrive la voce in locale con Whisper.
- Risponde con un modello Ollama.
- Parla con voci Piper italiane.
- Integra comandi e automazioni macOS.

## Requisiti

- macOS recente (Apple Silicon consigliato)
- Swift / Xcode per compilare
- Ollama con un modello (es. `qwen3:8b`)
- `whisper.cpp` + modello Whisper
- Piper + voce italiana

## Installazione rapida

```bash
git clone https://github.com/gionazzario-cmyk/fulcro.git
cd fulcro
./install.sh
```

Gli script `installa-*`, `avvio-automatico.sh` e `firma-locale.sh` gestiscono
installazione, avvio e firma locale.

## Struttura

- `Sources/` — codice Swift
- `Resources/` — risorse
- `Tools/` — script di supporto
- `sito/` — pagina del progetto
- `PROGETTO-2.md` — documento di progetto e scelte tecniche

## Stato

Sorgenti pubblici ripuliti dai dati personali. Il progetto è in evoluzione:
prima di usarlo controlla i requisiti e i percorsi degli strumenti locali.

## Licenza

MIT — vedi [LICENSE](LICENSE).
