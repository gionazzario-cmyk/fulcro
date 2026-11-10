# Fulcro v2 — il progetto (solo progetto: qui non si tocca codice)

Obiettivo in una frase: **che uno la scarichi, la apra e funzioni**, senza dover
installare Ollama, senza brew, senza scaricare modelli da solo. E che l'intelligenza
dietro sia più furiosa di adesso a parità di Mac.

---

## 1. Il problema, misurato stasera

Per far parlare Fulcro oggi servono pezzi che uno deve mettere a mano:

| Cosa | Peso oggi | Chi la installa |
| --- | --- | --- |
| Ollama + `qwen3:8b` (il cervello) | l'app ~200 MB + **5 GB** di modello | l'utente, da terminale |
| `whisper-cpp` + `ggml-small.bin` (l'orecchio) | **465 MB** | l'utente, con brew |
| piper + voci italiane (la bocca) | **168 MB** | l'utente, a mano |

Totale: **~6 GB e tre passaggi da terminale** prima che l'app sia utile. È esattamente
il punto dove uno molla, ed è il motivo per cui sulla pagina pubblica c'è una sezione
"Requisiti" lunga metà pagina.

Secondo problema, misurato in questi giorni: **il cervello da 8 miliardi di parametri
sbaglia comunque la strada** — 19 frasi capite su 28 prima delle correzioni, 28/28 dopo,
ma solo perché ci abbiamo messo sopra quattro reti di sicurezza (indizio dello strumento,
lista strumenti ristretta, rimbalzo, esecuzione deterministica). Con un modello più
piccolo quelle reti non bastano: serve un'architettura diversa.

---

## 2. Cosa c'è già sul Mac, verificato (non ipotizzato)

Ho aperto le interfacce del SDK 27.0 sul tuo Mac. Esistono, sono pubbliche e marcate
`@available(macOS 26.0, ...)`:

- **`FoundationModels.framework`** — il modello di Apple **già dentro il sistema**:
  `SystemLanguageModel`, `LanguageModelSession`, `Instructions`, `Prompt`,
  **`Tool` / `ToolCall` / `ToolCallingMode`** (chiamate di strumenti vere),
  `GenerationSchema` (uscita vincolata a una forma), `Guardrails`,
  `ImageAttachment` (guarda le immagini), `Availability` (per sapere se il modello è
  pronto o no), e perfino `PrivateCloudComputeLanguageModel` (l'appoggio remoto quando
  il prompt è troppo grosso per il chip — da verificare se è utilizzabile da noi).
- **`Speech.framework`** — la trascrizione on-device in Swift: `SpeechAnalyzer`,
  `Transcriber`, `AssetInventory` (i pacchetti linguistici li gestisce il sistema).

Traduzione: **l'orecchio, il cervello e l'occhio possono smettere di essere roba da
installare.** Stanno nel sistema operativo, come `AVFoundation`.

Cosa resta fuori: la **bocca** buona (piper suona molto meglio di quella di sistema) e
il **cervello grosso** (qwen3:8b è più bravo del modello di Apple). Quelle diventano
**aggiunte opzionali**, non prerequisiti.

---

## 3. L'architettura: quattro cervelli in fila, non uno

Il cuore della v2 è una catena con ordine fisso e **scelta osservabile** (si vede
sempre quale ha risposto, come oggi si vede "Locale/Gemini" nella pill MOTORE):

```
1. MODELLO DI SISTEMA   quello già installato nel Mac: zero download, zero rete
2. OLLAMA               se l'utente l'ha messo lui (una sua scelta, non un requisito)
3. GEMINI               solo con la chiave dell'utente, per quello che gli altri due non fanno
4. NESSUNO              l'app esegue comunque i comandi diretti e lo dice chiaro
```

**Scelta sua del 2026-10-21, scritta qui così com'è:** prima il modello che c'è già, poi
— se il compito non è fattibile con quello — Ollama (che resta opzionale: chi non vuole
scaricare 5 GB non lo fa), e infine Gemini con la chiave dell'utente.

**"Se fattibile" non può essere un'opinione del modello.** La regola concreta è una
tabella più dei contatori, non una sensazione:

| Si passa al livello dopo quando | Perché non è "il modello che si tira indietro" |
| --- | --- |
| il modello di sistema **non è disponibile** (`availability` dice no, pacchetto non scarico) | manca il pezzo, non la volontà |
| il compito è nella lista **`soloGrandi`** (più di ~6 strumenti insieme, riassunti lunghi, codice, confronti tra cervelli) | scelta a tavolino, misurata col test delle 28 frasi |
| due giri di fila senza una chiamata a strumento valida, o una chiamata con nome/argomenti fuori lista | il formato non è stato capito: è un errore oggettivo |
| la risposta puzza di invenzione o è vuota (`suonaFalsato` / `suonaRinuncia`, già scritti) | con qwen3 abbiamo già visto il recupero fallire due volte |
| l'utente lo chiede a voce ("spiegamelo bene", "usalo col cloud") | è una richiesta, non un guasto |

Regola che vale su tutti e tre i livelli: **il livello scelto non cambia mai cosa esce
dal Mac.** I testi personali restano dentro (è già `Gemini.daMandare`); se l'unico
livello possibile è il 3 e la chiave non c'è, l'app risponde `NON CONFIGURATO: …` e non
inventa niente.

Ogni livello implementa la **stessa interfaccia** (`rispondi(richiesta, strumenti) →
testo | chiamata a strumento`), quindi si può spegnere o preferire uno alla volta con un
file, e si può misurare lo stesso test su due cervelli diversi senza toccare nient'altro.

**Regola nuova, la più importante:** il modello piccolo **non vede mai i 25 strumenti
tutti insieme**. Prima passa da un **router deterministico** (niente modello: le parole
che già conosciamo — `strumentoGiusto`, i comandi esatti, l'orario, i compiti), e il
modello riceve **solo i 4-6 strumenti plausibili** per quella frase, con il prompt
tagliato al minimo. È lo stesso trucco che ha salvato le 28 frasi stanotte, ma messo
prima invece che dopo: costa meno, sbaglia meno, e ci sta nel contesto corto del
modello di Apple (che va misurato: è il primo numero da prendere, vedi §6).

---

## 4. Le sei cose che cambiano davvero

1. **Ascolto**: `SpeechAnalyzer`/`Transcriber` al posto di whisper.cpp. Guadagno: zero
   installazione, streaming (la frase si vede mentre la dici), e funziona anche a
   batteria senza caricare 465 MB. Rischio: l'italiano del sistema va verificato contro
   whisper con le stesse 10 registrazioni (abbiamo il corpus in `~/.jarvis/tmp` di ieri).
2. **Cervello di default**: FoundationModels. Guadagno: si avvia subito. Rischio: è un
   modello da ~3 miliardi, meno capace a ragionare in catena → per questo esiste il
   router del §3, e per questo `--prova-frasi` diventa il giudice di ogni scelta.
3. **Occhio** (`leggi_schermo`): `ImageAttachment` di Apple invece di `qwen2.5vl:7b`
   (che oggi pesa 6,9 GB e ci mette 30 secondi).
4. **Bocca**: piper resta **consigliato ma non necessario**; senza, si usa la voce di
   sistema (già oggi c'è il ricado).
5. **Strumenti che non trovano nulla**: oggi alcuni rispondono in modo diverso a
   seconda che manchino Ollama o il Raspberry. Nella v2 la regola è una sola: **`NON
   CONFIGURATO: <cosa manca e dove si scrive>`**, e il modello non deve mai inventare su
   quel testo (è già la via di `verdettoDaRiportare`, va estesa a tutti).
6. **Primo avvio**: una finestra di 3 righe — come ti chiami, la tua città, se vuoi la
   voce buona — che scrive `nome.txt`, `citta.txt` e il resto. Oggi questa cosa esiste
   già a metà (`Identita.notaPrimoAvvio`): nella v2 diventa una schermata, perché senza
   Ollama l'app non ha più la scusa di "parlane col terminale".

---

## 4-bis. La wake word, come l'ha voluta lui

> «voglio che funzioni solo con l'alimentatore, e voglio che Jarvis quando non lo chiamo
> sia inerte: poi lo chiamo e si accende»

Sono tre comportamenti diversi, e nessuno dei tre esiste già:

1. **Inerte davvero, a corrente staccata — di default, senza eccezioni.** (Decisione
   presa dopo: chi vuole la wake word anche a batteria se la va ad accendere lui, con
   l'avviso del consumo accanto: vedi §9 punto 2.) Non "in pausa con i timer che
   girano": niente microfono aperto, niente analisi, niente giro di ascolto. Il cancello esiste già
   (`Alimentazione.devePausare()`, usato per Orecchio e Studio) e la wake word ci si
   aggancia, ma in più va **chiuso il flusso audio** (`engine.stop()` e rilascio del nodo
   microfono), non solo ignorato quello che sente. Misura di accettazione: **0% CPU e 0
   accessi al microfono finché non la chiami**, controllata con `top`/`sample` e con la
   spia arancione del microfono che non si accende.
2. **Sotto carica, ascolta solo la parola.** `SpeechAnalyzer` è preciso ma pesante:
   tenerlo acceso sempre è stupido anche con la corrente. Due stadi: uno economico
   (energia del segnale + confronto con l'impronta corta della parola) che, quando
   sospetta, sveglia lo stadio 2 (trascrizione vera) e verifica la parola. Se è quella,
   si accende; altrimenti torna a dormire. Da misurare: **quanti risvegli falsi in
   un'ora di stanza con la TV accesa** e **quante volte non sente che lo chiami**. Sotto
   i 2 secondi di ritardo e meno di 5 risvegli falsi per ora il progetto sta in piedi;
   altrimenti si resta su ⌥ Spazio e la wake word non si fa.
3. **Si accende e si spegne da solo.** "Lo chiamo e si accende" vuol dire anche che
   **smette di ascoltare dopo la risposta** (o dopo N secondi di silenzio): altrimenti è
   un microfono aperto per sempre, che è esattamente quello che non vuoi in casa.

Nota onesta che riguarda il nome: "Jarvis" non è neutro (è il personaggio di Marvel, e
il progetto pubblico adesso si chiama Fulcro). La parola di sveglia va scelta insieme al
nome pubblico: se uno installa Fulcro e deve dire "Jarvis", la pagina mente.

---

## 4-ter. Batteria: come si allunga quando l'alimentatore è staccato

Misurato oggi, non ipotizzato. Il Mac di prova dà questo, **senza root**:

- `pmset -g assertions` funziona da utente e dice chi tiene sveglio il sistema. Adesso
  risultano: `configd → DenySystemSleep "InternetSharingPreference"` (18 minuti),
  `coreaudiod → PreventUserIdleSystemSleep` per `corespeechd` (**3 ore e 46 minuti**,
  con risorse `audio-in audio-out`), e `bluetoothd → UserIsActive` (BLE HID).
- `top -l 2 -o cpu` non ha una colonna "power" su questo sistema: si ragiona con
  `%CPU` e `TIME` (tempo CPU cumulato). E lì spiccano `boringNotch` (19% CPU,
  **30 h 37 m** cumulate) e `triald` (59% in questo istante).

Quindi i modi ci sono, e sono in quest'ordine di guadagno:

1. **Non consumare per niente quando non serve** — è già il guadagno più grosso della
   giornata: l'animazione del reattore a 120 Hz costava **25-35% di CPU a riposo**, ora
   0-4%. Sulla batteria quello è il 20-30% dell'autonomia che torna.
2. **Rispettare la Modalità Risparmio Energetico del sistema.** `ProcessInfo.isLowPowerModeEnabled`
   si legge senza permessi: quando lui la accende, l'app passa al minimo da sola — niente
   animazioni, niente ascolto passivo, niente server iPad, niente sorveglianza Bambu,
   sondaggi diradati. Oggi l'app non la guarda nemmeno.
3. **Dimezzare i timer invece di spegnerli.** A batteria: CPU 5 s → 60 s (la riga
   DIAGNOSTICA mostra "ultima lettura delle 21:40" invece di mentire fresca), inventario
   600 s → spento, orecchio 20 s → **non si gira proprio**: si aspetta l'evento sul file
   (`DispatchSource` su `chat.db`) invece di interrogarlo 3 volte al minuto. È il pezzo
   che costa di più in radio/dischi quando il Mac è in idle.
4. **Non caricare modelli a batteria, mai.** Né whisper (465 MB) né piper: si toccano
   solo quando preme ⌥ Spazio, e appena ha risposto si scaricano (`keep_alive: 0` su
   Ollama quando si passa a Gemini, che già succede a metà).
5. **Chiudere il server iPad a batteria**: è un listener che tiene sveglio il Wi-Fi e
   risponde a keepalive.
6. **Non tenere mai un'asserzione di sonno**: verifica di sicurezza, si controlla con
   `pmset -g assertions` e si pretende che Fulcro non compaia nell'elenco.
7. **La funzione nuova che vale davvero — "chi mi sta mangiando la batteria?"**: l'app
   legge `pmset -g assertions` + `top -l 2 -o cpu` e li traduce in italiano con nome e
   cognome: *«Internet Sharing sta bloccando il sonno da 18 minuti»*, *«corespeechd ha un
   blocco audio aperto da quasi 4 ore: c'è una voce che gira»*, *«boringNotch ha consumato
   30 ore di CPU»*. Nessuna root, nessuna ipotesi, e sono cose che si possono sistemare.

Da non duplicare: `~/RisparmioEnergia/` (LaunchDaemon + `battery-saver.sh`) fa già il
profilo di sistema (`pmset -b …`, stop Internet Sharing, stop Siri in loop, sonno a 1
minuto) e ha `pausa-risparmio.sh`. Fulcro **non** deve rifare quelle cose: deve (a) non
ostacolarle, (b) leggere lo stato di `/var/tmp/risparmio-energia.pausa` per dire perché
il profilo è in pausa, e (c) aggiungere solo la parte che il sistema non può sapere,
cioè i propri consumi e i propri blocchi.

Accettazione proposta: con l'alimentatore staccato, **Fulcro non deve comparire tra i
primi 10 consumatori** in un `top -l 5 -o cpu` da 30 secondi, e deve poter dire in una
riga quanta CPU ha usato nell'ultimo ora (`TIME` del proprio processo).

---

## 4-quater. Perché "dimezzare l'hardware" non è la leva giusta

Domanda sua: *«non basta dimezzare tutto? 16 core ne diventano 8, 8 core GPU diventano
4, 64 GB di RAM diventano 32»*. Verificato sul suo Mac: l'M1 Max ha **8 core performance
+ 2 efficiency** (`hw.perflevel0/1.physicalcpu`) e 64 GB. Risposta onesta: no, e il
motivo è che quelle manopole non esistono (e comunque non sono lì i watt).

| Idea | Cosa si può fare davvero |
| --- | --- |
| "spegnere metà CPU" | nessuna API da utente; e il sistema già parcheggia i core vuoti. La leva vera è la **classe di qualità del lavoro** (`DispatchQoS.background`/`.utility`): se lo marchi così, finisce sui 2 core **efficiency**, che costano una frazione dei performance. Oggi i timer di Jarvis girano con la classe di default: è il primo "dimezzamento" da fare, per lavoro e non per hardware |
| "dimezzare la GPU" | i core grafici non si dividono; si dimezza **il lavoro grafico**: niente blur, niente ombre, niente ridisegni a 120 Hz. È esattamente quello che ha recuperato 25-35% di CPU oggi |
| "dimezzare la RAM" | 64 GB non diventano 32, e la RAM inutilizzata non consuma quasi niente. Consuma la **pressione**: quando finisce lo spazio, macOS comprime (CPU) e scrive su SSD (energia + usura). La regola giusta è "non caricare quello che non serve": il modello da 5 GB e whisper da 465 MB sono esattamente quel tipo di consumo |
| "andare più piano" | il numero che conta è il **ciclo di veglia**: tre risvegli al secondo tengono il chip fuori dal sonno profondo e costano più di un 5% una volta al minuto. Per questo "dimezzare i timer" è la parte sensata dell'idea, e per questo l'ideale non è dimezzarli ma **eliminarli** (evento sul file invece di interrogazione) |

E c'è già un interruttore che fa il dimezzamento hardware al posto nostro: la
**Modalità Risparmio Energetico** limita la frequenza della CPU, abbassa la luminosità,
spegne gli effetti e cambia la curva della ventola. È Apple che lo fa dal livello del
sistema, dove noi non possiamo arrivare: il lavoro dell'app è **ascoltarla**
(`isLowPowerModeEnabled`) e non ostacolarla, non reinventarla.

**Come si misura**, senza root (che è vietato): **secondi CPU per ora** del processo, che
per la quota dell'app è quasi lineare con i wattora. Target proposto: **sotto i 30
secondi di CPU per ora** a riposo con la batteria staccata, e zero comparizioni in
`pmset -g assertions`.

---

## 4-quinquies. Il piano è stato scritto e misurato (2026-10-21, notte)

La regola sua — *a batteria consuma zero, all'alimentatore scalda il meno possibile* — è
finita in `Sources/Jarvis/Risparmio.swift`: una funzione pura `decidi(carica:termica:
risparmioSistema:modo:)` che restituisce un `Piano` (sorveglianza, inventario, letture,
animazioni, server, "chiuditi", priorità) e otto controlli nella suite `--test`, così si
prova senza staccare il cavo.

Il punto che contava davvero: **i timer non devono esistere**, non devono "controllare se
è il caso" dentro la callback — perché la callback significa che il processo si è già
svegliato, e il risveglio è il costo. `JarvisCore.timerSecondoIlPiano()` crea e distrugge
i tre timer (battito, campionatore CPU, conto delle app) seguendo il piano, e ognuno ha la
`tolerance` messa: dice a macOS che la sua sveglia può ritardare, così lui le raggruppa
con quelle di tutti gli altri processi.

La scelta di cosa fare a batteria sta in `~/.jarvis/passo.txt` — `dormi` (default), `esci`,
`lavora` — e si cambia dalla barra laterale (riga «A batteria») o a voce con lo strumento
`cervello`. Non si chiama `batteria.txt` perché quel file esiste già dal 19 ottobre e
contiene un'altra scelta (gemini/locale, cioè *dove* ragiona): leggere lo stesso file
avrebbe voluto dire che una domanda sul cervello spegneva la sorveglianza.

**Numeri misurati** (`ps -o cputime`, risoluzione del centesimo di secondo; Mac sotto
carica, finestra aperta):

| Situazione | CPU | per ora |
| --- | --- | --- |
| alimentatore, tutto attivo (regime stabile) | 1,47 s in 90 s = 1,63% di un core | **≈ 59 s/h** |
| batteria simulata, `dormi` | 0,31 s in 150 s = 0,21% di un core | **≈ 7 s/h** |
| batteria simulata, `esci` | l'app si è chiusa da sola in 2 s | 0 |

Il target del §4-quater (sotto i 30 s/h a batteria) è dentro il segno, e `pmset -g
assertions` non lo nomina proprio: nessuna pretesa di tenere sveglio il Mac.
«Zero» letterale non esiste — esiste *non svegliarsi*: 7 secondi l'ora sono il battito
lento da 120 s che controlla se ha riattaccato, più la finestra che disegna.

Due cose oneste da dire: la batteria simulata viene da `JARVIS_ALIMENTATORE=0` (nessuno
può staccare il cavo da qui), e **i 59 s/h all'alimentatore sono il costo della finestra
aperta**: con gli anelli fermi e la finestra non in primo piano il numero scende, perché
la parte grafica ora si pausa da sola (`RilevatoreVisibilita` + `core.reattoreFermo`).
Il `repeatForever` che restava acceso a microfono chiuso è stato tolto da entrambi i
pannelli, e `CerchioNucleo` (view morta, mai usata) cancellato.

---

## 5. Cosa NON è la v2 (per non perderci dentro)

- **Non** è un modello dentro il `.app`: 5 GB non si spedivano e non si spediscono.
- **Non** è un servizio nostro: niente server, niente account, niente chiavi condivise.
- **Non** è un orecchio sempre acceso: la wake word c'è, ma **solo con l'alimentatore
  attaccato**, ed è il pezzo che cambia di più la vita quotidiana dell'app (§4-bis).
- **Non** toglie Ollama: chi ce l'ha continua ad averlo come cervello migliore.

---

## 6. Le cinque cose da verificare prima di scrivere una riga

Sono sonde da venti minuti ciascuna, e ognuna può cambiare il progetto:

1. **Il modello Apple è pronto su questo Mac?** `SystemLanguageModel.default.availability`
   → se risponde che va abilitato da Impostazioni, la v2 non può essere "zero install"
   per tutti: cambia il piano (e la pagina di download deve dirlo).
2. **Quanto contesto ha davvero**, e quanti token consumano oggi il nostro prompt di
   sistema + 25 definizioni di strumento (misura che già esiste: `--costo`).
   Se non ci sta, il router del §3 non è un'opzione: è obbligatorio.
3. **Come chiama gli strumenti**: il formato di `Tool` di Apple è Swift tipizzato, non
   JSON libero come Ollama. Va verificato che regga i nostri argomenti opzionali
   (`azione`, `testo`, `a=`, `testo=`) e cosa succede quando ne sbaglia uno.
4. **L'italiano di `SpeechAnalyzer`**: 10 registrazioni vere, trascrizione a confronto
   con whisper, con e senza rumore di fondo.
5. **Pavimento di versione**: FoundationModels chiede **macOS 26**, il progetto oggi è
   `.macOS(.v14)`. Alzare il pavimento significa che chi ha macOS 15 non può più
   scaricare l'app: è una scelta tua, non tecnica.

---

## 7. Come si giudica se è meglio (misure, non sensazioni)

| Misura | Oggi | Target v2 |
| --- | --- | --- |
| Passi per avere un'app funzionante da zero | 3 installazioni + 6 GB | **0 installazioni** |
| Frasi capite (`--prova-frasi`, 28) | 28/28 con qwen3:8b | ≥ 24/28 **senza Ollama** |
| Tempo prima risposta semplice | 6,6 s locale | ≤ 3 s on-device |
| Tempo "la giornata" (senza modello) | 0,9 s | 0,9 s (non deve peggiorare) |
| RAM a riposo | ~137 MB | ≤ 200 MB senza modello caricato |
| Test rapidi verdi | 107/107 | ≥ 107/107 |

Il test delle 28 frasi va eseguito **due volte, stesso file**: con Ollama e senza. Se
senza Ollama scende sotto 24, il router va rivisto prima di scrivere altro.

---

## 8. Come la taglierei, in quattro pezzi

1. **Sonda** (mezza giornata): le cinque verifiche del §6, con i numeri scritti qui
   dentro. Alla fine si sa se il piano sta in piedi.
2. **Catena dei cervelli** (1-2 giorni): interfaccia unica, Apple come default, Ollama
   come preferenza, pill MOTORE che dice quale ha risposto, `--prova-frasi` su entrambi.
3. **Router + strumenti a sottoinsieme** (1-2 giorni): prompt per intento, 4-6
   strumenti per giro, e le reti di sicurezza di stanotte semplificate (col router prima,
   molte meno servono dopo).
4. **Orecchio e occhio di sistema** (1 giorno): Speech al posto di whisper,
   ImageAttachment al posto del modello visivo, piper declassato a "consigliato".

Ogni pezzo finisce con: build, suite, e **la pagina del sito aggiornata** (perché oggi
dice "serve Ollama": se non lo serve più, va riscritta, altrimenti la prima riga del
sito mente).

---

## 9. Decisioni

**Preso il 2026-10-21 (prima infornata):** catena *modello di sistema → Ollama → Gemini*
(Ollama e Gemini restano scelte di chi installa, con la sua chiave).

**Preso il 2026-10-21 (seconda infornata):**

1. **Il pavimento si alza.** FoundationModels chiede macOS 26: si alza lì (e se una cosa
   serve solo sul 27, si usa il 27). La sua regola è *"più in alto possono stare, meglio
   è"*: niente binari paralleli per i sistemi vecchi, una sola versione fatta bene.
   **Conseguenza obbligatoria sulla pagina pubblica:** i requisiti dicono
   `macOS 26 o più nuovo`, non `14`: oggi il sito mente, e va corretto quando si pubblica
   la v2 (non prima, altrimenti si promette quello che l'app non è).
2. **A corrente staccata l'app è inerte, e basta.** Niente ascolto, niente timer di
   risveglio, niente risvegli falsi: si chiama con ⌥ Spazio o con la chat. **Se uno
   vuole la wake word anche a batteria, se la deve andare ad accendere lui**, con una
   scelta esplicita (e il avviso onesto accanto: "ascoltare consuma"). Cambia il §4-bis
   punto 1: non è più "wake word solo sotto carica", è "wake word spenta di default
   fuori corrente, attivabile a rischio e consumo dell'utente".
3. **Gemini: la mia opinione, che lui ha chiesto.** Resta **spiegazione e riserva**, non
   diventa il cervello di default. Tre motivi, in ordine di peso:
   - *l'app deve essere completa senza chiave.* Se Gemini fosse il cervello quando il Mac
     è debole, chi scarica Fulcro e non ha una chiave API si ritrova un assistente monco:
     la pagina direbbe una cosa e il prodotto un'altra. Invece senza chiave deve funzionare
     tutto: comandi, strumenti, memoria, "la giornata", meteo, stampante.
   - *la regola tua sulla privacy regge solo se il cloud è eccezione.* Appena il cloud
     diventa il percorso normale, "i testi personali non escono" diventa una promessa
     difficile da tenere d'occhio invece di una porta chiusa.
   - *la qualità di Gemini non è quella che manca.* Le 9 frasi sbagliate di stanotte non
     le ha sbagliate perché il modello era "poco intelligente": le ha sbagliate perché non
     sapeva **quale strumento chiamare**. Quello si sistema col router del §3, che costa
     zero e funziona anche offline.
   **Dove lo voglio invece:** nei compiti marcati `soloGrandi` (spiegazioni lunghe,
   confronti, testo da riscrivere) e come **riserva dichiarata** quando il modello di
   sistema non ci sta dentro. In entrambi i casi con una riga a schermo che dice
   "risposta dal cloud: è uscito solo il testo della domanda, non i tuoi file", e con il
   consenso chiesto **una volta sola** e salvato in `~/.jarvis/`.

---

## 9-bis. Linux

**È v3 e non se ne parla adesso.** Segnato solo per non dimenticarsi due cose quando
arriverà: il motore è già portabile (comandi, ponticelli Python, MQTT, SQLite) mentre
barra dei menu, ⌥ Spazio, ascolto e voce di sistema no; e quando si farà va detto sul
sito com'è davvero («in arrivo»), non promesso prima.

---

## 10. Stato di quello che esiste già (per non ripartire da zero)

- App: `~/programmi/jarvis`, firma «Jarvis Locale», `--test` 107/107, de-personalizzata
  (nessun nome/città/numero nel `.app`), marchio pubblico **Fulcro** via `Marca.swift`.
- Sito: pubblicato su `fulcro-mac-g2sw5a2j1j8.qoder.website`, **privato** per ora; ha la
  sezione commenti con il codice dell'installazione come cancello (`HLDNMQ7Y` sul tuo
  Mac) e la tabella `commenti` (schema versione 1). Da verificare dal vivo appena diventa
  pubblico: la scrittura dei commenti non è ancora stata provata contro il servizio reale.
- Da non dimenticare: il `--prova-frasi` va rilanciato dopo **ogni** modifica al routing, e le
  temperature SMC restano illeggibili senza root (righe tolte, non bug).
