# Fulcro — istruzioni per l'installazione

Fulcro è un assistente vocale che gira **tutto sul tuo Mac**: nient'altro lo sente.
Vive nella barra dei menu, gli parli con **⌥ Opzione + Spazio** oppure gli scrivi.

## Cosa ti serve prima

- **macOS 14 o più nuovo, su un Mac Apple Silicon** (M1/M2/M3/M4). Non è compilato
  per Intel.
- **Ollama** con il modello `qwen3:8b` — è il cervello. Senza, Fulcro si accende lo
  stesso ma non capisce quello che gli chiedi.
  https://ollama.com → poi, da Terminale: `ollama pull qwen3:8b`
- Facoltative, ma senza queste il Mac parla con la voce di sistema e non ti ascolta
  dal microfono:
  - `brew install whisper-cpp` → modello `ggml-small.bin` da mettere in `~/.jarvis/models/`
  - `pip install piper-tts` + una voce italiana in `~/.jarvis/piper/`

## Installare (il passaggio che macOS rende noioso)

Fulcro **non è firmato con un account Apple sviluppatore** (costa 99 $ l'anno e non ha
senso per un progetto personale), quindi Gatekeeper lo blocca al primo avvio. Non è un
virus: è una firma locale che il tuo Mac non conosce.

1. Trascina `Fulcro.app` nella cartella **Applicazioni**.
2. Aprilo la prima volta **con il tasto destro → Apri** (non con doppio clic), poi
   «Apri» nella finestra. Se macOS dice che l'app è danneggiata o non verificabile:
   **Impostazioni di Sistema → Privacy e sicurezza** → in basso c'è il pulsante
   **«Comunque»** (o "Apri comunque"), cliccalo e riprova.
3. In alternativa, da Terminale togli il flag di "scaricata da internet":

   ```
   xattr -dr com.apple.quarantine /Applications/Fulcro.app
   ```

   (scrivi tu il comando: non fidarti di chi te lo fa eseguire da un pulsante)

## Poi gli dai i permessi

All'avvio Fulcro chiede quello che gli serve, e **le voci che non hai concesso non
spariscono: dicono «permesso negato»**. Nella finestra, in basso a sinistra, ci sono i
quattro pulsanti che aprono la schermata giusta:

- **Registrazione schermo** — per leggere cosa c'è sullo schermo
- **Microfono** — per ⌥Spazio
- **Accessibilità** — per scrivere e premere tasti al posto tuo
- **Accesso completo al disco** — solo se vuoi che legga iMessage in arrivo

## Cosa configurare (tutto opzionale, tutto in `~/.jarvis/`)

Al **primo avvio** Fulcro non sa niente di te: chiede come ti vuole chiamare e
comincia a scrivere la sua memoria nei file qui sotto. Non c'è nessun dato di chi ha
scritto il programma: nome, città e host del Raspberry non sono compilati dentro
l'app, si leggono da questi file.

| File | A cosa serve |
| --- | --- |
| `nome.txt` | **come ti chiami**: una riga sola, è il nome che Fulcro usa nelle frasi |
| `citta.txt` | la tua città: senza quella il meteo lo dice e te la chiede, non indovina |
| `raspberry.txt` | l'host del tuo Raspberry Pi in rete, se ce l'hai |
| `numero.txt` | il **tuo** numero: le prove di invio messaggi si fanno solo lì |
| `prove.txt` | altri contatti a cui è lecito mandare una prova (uno per riga) |
| `profilo.md` | cosa Fulcro deve sapere di te: lo legge a ogni conversazione |
| `compiti.md` | la lista dei compiti (`- [ ] scadenza · materia · cosa · pagina`) |
| `contatti.txt` | nomi → numeri |
| `prove.txt` | altri contatti a cui è lecito mandare una prova (uno per riga) |
| `bambu.conf` | serial + codice di accesso di una stampante Bambu in rete locale |
| `gemini.txt` | chiave Gemini, se vuoi che spieghi le cose con il cloud (di default resta tutto locale) |
| `distrazioni.txt` | le app che ti rubano il tempo, per il controllo sui compiti |

## Cosa fa, in breve

⌥Spazio per parlare · «la giornata» per il briefing · «che compiti ho» · «apri il
terminale» · «quanti giga liberi ho» · «che tempo fa» · «chi sta vincendo il mondiale» ·
«apri Keka» (le app le apre **in background**, senza rubarti lo schermo, e alla fine
richiude quelle che ha aperto lei) · «mandami un messaggio di prova» · «spiegami quello
che ho copiato» · stato e temperature di una stampante 3D Bambu in LAN · diagnostica del
Mac in tempo reale nella colonna a destra.

## Cosa NON fa

- Non legge le temperature dei sensori del Mac: macOS non le fa leggere senza root, e
  senza root non le chiede. Quelle righe sono state tolte invece di mettere numeri
  inventati.
- Non manda mail da solo: serve una casella configurata.
- Non carica niente su internet: le uniche uscite di rete sono letture (meteo, formule,
  notizie) e, solo se glielo chiedi esplicitamente, la spiegazione con Gemini.

## Disinstallare

Trascina `Fulcro.app` nel Cestino e, se vuoi cancellare anche i suoi dati:

```
ls -la ~/.jarvis        # guarda cosa c'è dentro prima di toglierlo
```

I log sono in `~/.jarvis/logs/`: lì dentro ci sono le tue chat, quindi decidi tu.


**Nota sul nome della cartella.** I file di configurazione stanno in `~/.jarvis/`: è il
nome storico del progetto, non un altro programma. Dentro quella cartella ci sono solo
cose tue (profilo, compiti, log, modelli) e la puoi cancellare quando vuoi.
