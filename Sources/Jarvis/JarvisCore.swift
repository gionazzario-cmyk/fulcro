import Foundation
import AppKit

struct Bubble: Identifiable, Equatable {
    let id: UUID
    var role: String
    var text: String
    init(id: UUID = UUID(), role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Una cosa che Jarvis sta facendo adesso: serve per l'animazione del pensiero.
struct Passo: Identifiable, Equatable {
    let id: String
    var etichetta: String
    var fatto: Bool
}

@MainActor
final class JarvisCore: ObservableObject {
    static let shared = JarvisCore()

    @Published var bubbles: [Bubble] = []
    @Published var draft = ""
    @Published var thinking = false
    @Published var listening = false
    @Published var voiceOn = true
    @Published var micLevel = 0.0
    @Published var headline = "\(Marca.nome) sta partendo…"
    @Published var pendingCommand: String?
    @Published var webOn = true
    @Published var webLine = "chat iPad in avvio…"
    @Published var chat: [ChatSessione] = []
    @Published var chatAttuale = ""
    /// Le cose che Jarvis sta facendo adesso, per l'animazione del pensiero.
    @Published var passi: [Passo] = []

    private let agent = Agent()
    /// Le conferme in coda. Prima ce n'era UNA sola: se due strumenti chiedevano il
    /// clic insieme, la seconda sovrascriveva la prima e quella continuazione non si
    /// risvegliava mai — lo strumento restava in `await`, `thinking` restava true e
    /// l'app sembrava morta fino al riavvio. Il timeout non era conservato, quindi
    /// poteva anche negare una conferma successiva con lo stesso testo.
    private final class Attesa {
        let comando: String
        let cont: CheckedContinuation<Bool, Never>
        var timeout: Task<Void, Never>?
        init(comando: String, cont: CheckedContinuation<Bool, Never>) {
            self.comando = comando
            self.cont = cont
        }
    }
    private var attese: [Attesa] = []
    /// Tiene il conto di quali frasi della risposta in corso sono gia' state dette:
    /// si azzera a ogni `handle`, perche' ogni risposta riparte da testo vuoto.
    private var divisore = DivisoreDiFrasi()

    private init() {
        AppPaths.prepare()
        Tools.confirm = { [weak self] cmd in await self?.askConfirmation(cmd) ?? false }
        // Il watchdog dei compiti scrive nella chat come se fosse Jarvis che parla.
        Studio.shared.onNote = { [weak self] riga in self?.note(riga) }
        // Anche gli avvisi dei messaggi in arrivo finiscono nella chat.
        Orecchio.shared.onArrivo = { [weak self] riga in self?.note(riga) }
        // Mode debug/test: niente scorciatoia, niente server, niente finestra.
        // La suite --test pompa il run loop, quindi qui dentro girarebbe davvero.
        if SelfTest.modeCLICorrente { return }
        // Il cavo che entra o esce lo dice IOKit. Prima se ne accorgeva solo il battito
        // del timer, fino a due minuti dopo: con la scelta «esci» erano due minuti di
        // batteria buttata, con «dormi» un risveglio quando capitava.
        Alimentazione.osservaCambiCorrente {
            Task { @MainActor in JarvisCore.shared.applicaRisparmio() }
        }
        // ⌥Spazio non apre piu' il microfono: apre la barra. La voce sta li' dentro
        // (pulsante micro), perche' un tasto che fa una cosa sola e' piu' facile
        // da ricordare di due tasti per due cose.
        Hotkey.shared.onPress = { BarraRapida.shared.alterna() }
        Hotkey.shared.onSelezione = { BarraRapida.shared.apriConSelezione() }
        // E QUI si registra davvero. Fino al 2026-11-02 questa riga non c'era: le
        // scorciatoie venivano assegnate ma mai registrate, quindi ⌥Spazio non ha
        // MAI funzionato — il microfono si apriva solo dal pannello della barra.
        // E' anche il motivo per cui la voce risulta usata una volta su 232.
        Hotkey.shared.register()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            portaFinestraAvanti()
        }
        DispatchQueue.global(qos: .utility).async {
            Speaker.verificaPiper()
            Task { @MainActor in self.bootstrap() }
        }
    }

    /// Il sistema non porta fuori la finestra se Jarvis parte in background: ci pensiamo noi.
    func portaFinestraAvanti() {
        // NSApp non esiste nei mode da terminale: senza questo controllo si schianta li'.
        guard let app = NSApp else { return }
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        for f in app.windows where f.title == "\(Marca.nome)" && String(describing: type(of: f)).contains("AppKitWindow") {
            f.makeKeyAndOrderFront(nil)
        }
    }

    var busy: Bool { thinking || listening }

    /// Dice una frase a voce se la voce e' accesa: la usano gli avvisi automatici
    /// (watchdog dei compiti, fine stampa) che non passano dalla chat.
    func dillo(_ testo: String) {
        if voiceOn { Speaker.shared.say(testo) }
    }

    /// Scrive nella chat SENZA parlare: serve alle cose automatiche che devono stare
    /// zitte, come gli appunti durante una riunione (regola sua: mai voce in call).
    func notaSenzaVoce(_ testo: String) {
        bubbles.append(Bubble(role: "note", text: testo))
        Store.shared.record(role: "jarvis", text: testo, source: "riunione")
    }

    /// Una domanda secca al modello locale, senza strumenti: serve da riserva quando
    /// il secondo cervello non ha la chiave.
    func rispostaLocale(_ domanda: String) async -> String {
        let giri = [ChatTurn(role: "system", content: Self.systemPrompt()),
                   ChatTurn(role: "user", content: domanda)]
        var accumulato = ""
        let risultato = try? await Brain.shared.stream(turns: giri, tools: []) { pezzo in accumulato += pezzo }
        let testo = (risultato?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return testo.isEmpty ? accumulato : testo
    }

    /// Cambia voce dal finestrone o a voce: scrive ~/.jarvis/voce.txt e aggiorna la riga di stato.
    func cambiaVoce(_ nome: String) {
        let esito = AppPaths.scegliVoce(nome)
        let parti = headline.components(separatedBy: " · voce ")
        if parti.count == 2 { headline = parti[0] + " · voce " + Speaker.shared.voiceName }
        note(esito)
    }

    /// La scelta "a batteria" della barra laterale (o detta a voce): scrive passo.txt
    /// e riapplica subito il piano, perche' se lui dice "esci" l'app deve uscire adesso,
    /// non al prossimo risveglio del timer.
    func cambiaPasso(_ nuovo: Risparmio.Modo) {
        let esito = Risparmio.imposta(nuovo)
        applicaRisparmio()
        note(esito)
    }

    /// Chiede il clic all'utente: dopo 2 minuti la risposta diventa "no" da sola.
    /// Se nel frattempo ne arriva un'altra si accoda, e la card mostra sempre la prima.
    private func askConfirmation(_ cmd: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let attesa = Attesa(comando: cmd, cont: c)
            let primaInCoda = attese.isEmpty
            attese.append(attesa)
            pendingCommand = attese.first?.comando
            if primaInCoda, voiceOn { Speaker.shared.say("Mi serve una conferma prima di continuare.") }
            attesa.timeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.chiudi(attesa, con: false)
            }
        }
    }

    /// Risponde alla conferma che si vede: la prima della coda.
    func answer(_ ok: Bool) {
        guard let prima = attese.first else {
            // niente in coda: succede solo quando una schermata di prova scrive
            // `pendingCommand` a mano per fare uno scatto. Si pulisce e basta.
            pendingCommand = nil
            return
        }
        chiudi(prima, con: ok)
    }

    /// Toglie la richiesta dalla coda, la sblocca, annulla il suo timeout e mette
    /// davanti la prossima. Nessuna continuazione puo' restare appesa.
    private func chiudi(_ attesa: Attesa, con ok: Bool) {
        guard let i = attese.firstIndex(where: { $0 === attesa }) else { return }
        attese.remove(at: i)
        attesa.timeout?.cancel()
        pendingCommand = attese.first?.comando
        attesa.cont.resume(returning: ok)
    }

    func setWeb(_ on: Bool) {
        webOn = on
        if on { JarvisWeb.shared.start() } else { JarvisWeb.shared.stop() }
        refreshWeb()
    }

    func refreshWeb() {
        let w = JarvisWeb.shared
        webLine = w.running ? "\(w.address) · codice \(w.pin)" : "chat iPad spenta"
    }

    private func bootstrap() {
        _ = Marca.codiceApp          // nasce qui, non quando apri la barra laterale
        aggiornaListaChat()
        riprendiChat()
        if Orecchio.shared.attivo { _ = Orecchio.shared.accendi() }
        if webOn {
            JarvisWeb.shared.start()
            // il listener e' pronto un istante dopo: aspetto prima di scrivere l'indirizzo
            Task { @MainActor in
                for _ in 0..<12 where !JarvisWeb.shared.running {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                self.refreshWeb()
            }
        }
        Task {
            let alive = await Brain.shared.isAlive()
            let model = await Brain.shared.resolveModel()
            // Il modello NON si carica piu' qui: prima restava in RAM 30 minuti a
            // scaldare il Mac anche senza parlare. Adesso lo carica il microfono
            // quando inizi a parlare, e Ollama lo richiude 30 s dopo l'ultimo
            // messaggio (Brain.riposo).
            let stt = STT.isReady
            await MainActor.run {
                if !alive {
                    headline = "Ollama spento: aprilo dalle App"
                } else if model == nil {
                    headline = "Nessun modello locale pronto: ollama pull qwen3:8b"
                } else {
                    let parti = [model ?? "?",
                                 "ascolto " + (stt ? "pronto" : "assente"),
                                 "voce " + Speaker.shared.voiceName]
                    headline = parti.joined(separator: " · ")
                }
                self.aggiornaStatoCervello()
                self.raccogliDiagnostica()
                self.ultimaLettura = Date()
                self.annota("pronto: \(self.headline)")
                // i chip del momento devono esserci subito, non trenta secondi dopo
                // (con --shot in piu' si possono guardare: senza questa chiamata escono vuoti)
                self.raccogliSuggerimenti()
                // Prima lettura dell'inventario, una tantum: se l'inventario non c'e'
                // ancora lo costruisce adesso, ma e' l'unica volta che costa finche'
                // il piano non dice che si puo' rifare.
                if InventarioApp.caricato() == nil {
                    Task {
                        let esito = await InventarioApp.vigila()
                        await MainActor.run { if let n = esito.annuncio { JarvisCore.shared.notaSenzaVoce(n) } }
                    }
                }
                // Il piano si decide prima di accendere i timer: se parte a batteria
                // non deve nemmeno svegliarsi a leggere la CPU ogni cinque secondi.
                applicaRisparmio()
                self.timerSecondoIlPiano()
                // il buongiorno e' gia' stato calcolato alle 7:30 dal LaunchAgent:
                // qui si mette in chat, cosi' aprendo lo trovi senza chiederlo
                if let buongiorno = Buongiorno.daMostrare() {
                    Buongiorno.segnaVisto()
                    self.bubbles.append(Bubble(role: "jarvis", text: buongiorno))
                    self.headline = "buongiorno pronto"
                }
            }
        }
    }

    /// Il registro a schermo (colonna destra del tema olografico): SOLO cose successe
    /// davvero, con l'ora vera. Niente "[00:00:03] Connessione ai moduli locali
    /// stabilita" scritto a mano: quella riga era una bugia, e lui l'aveva gia' notata.
    struct Evento: Identifiable, Equatable { var id = UUID(); var ora: String; var testo: String }
    @Published var eventi: [Evento] = []

    /// Numeri veri della macchina: carico, RAM, motore, termico, rete.
    struct Diagnostica: Equatable {
        var cpuUso = "—"
        var carico = "—"
        var ramUsata = "—"
        var ramEtichetta = "RAM"
        var ramPercentuale = 0
        var motore = "—"
        var termico = "—"
        var rete = "—"
    }
    @Published var diagnostica = Diagnostica()
    /// Il passo dell'app in questo momento (corrente, calore, scelta sua in passo.txt).
    @Published var piano = Risparmio.Piano.attivo
    /// Quando sono stati letti davvero i numeri: se il piano dice "non leggere", la
    /// finestra lo dice invece di far finta di essere fresca.
    @Published var ultimaLettura = Date.distantPast

    /// Gli anelli girano solo quando c'e' un perche'. A batteria sonno stanno fermi
    /// (muovere tre cerchi a 8 fotogrammi e' corrente), ma se sta davvero pensando o
    /// ascoltando il movimento e' un'informazione che lui chiede, non decorazione.
    var reattoreFermo: Bool { !piano.animazioni && !thinking && !listening }

    // MARK: - chi guarda davvero lo schermo

    /// La finestra grande e il pop-up della barra dicono qui se sono visibili
    /// (`RilevatoreVisibilita`). Non e' un dettaglio di grafica: i chip dei suggerimenti
    /// e le misure si ricalcolano **solo quando qualcuno li guarda**, perche' rifare il
    /// giro ogni trenta secondi a finestra chiusa vuol dire ridisegnare tre colonne di
    /// pannelli con la sfumatura dietro — ed e' GPU, cioe' ventole.
    @Published var finestraInSchermo = false
    @Published var pannelloInSchermo = false
    var schermoInUso: Bool { finestraInSchermo || pannelloInSchermo }
    private var qualcunGuardavaGia = false

    /// Qualcuno ha appena aperto (o chiuso) una finestra. Due effetti: i timer di misura
    /// si accendono/spegnono con lo schermo, e appena compare una finestra si rinfresca
    /// tutto subito — il prossimo battito puo' anche essere tra trenta secondi e lui
    /// guarda adesso.
    ///
    /// Si chiama SENZA parametri e guarda `schermoInUso`, non il flag del singolo
    /// chiamante: con la finestra aperta e il pop-up che si chiude, il campionatore non
    /// deve spegnersi — qualcuno sta ancora guardando.
    @MainActor func schermoCambiato() {
        let adesso = schermoInUso
        guard adesso != qualcunGuardavaGia else { return }
        qualcunGuardavaGia = adesso
        timerSecondoIlPiano()
        guard adesso, piano.diagnostica || piano.sorveglianza else { return }
        aggiornaStatoCervello()
        raccogliSuggerimenti()
        raccogliDiagnostica()
        campionaCpu()
    }

    /// Una riga del registro, con l'ora in cui e' successa.
    func annota(_ cosa: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm:ss"
        let nuovo = Evento(ora: f.string(from: Date()), testo: cosa)
        var liste = eventi
        liste.append(nuovo)
        if liste.count > 40 { liste.removeFirst(liste.count - 40) }
        eventi = liste
    }

    /// Tutto letto da API vere: `getloadavg`, `host_statistics64`, `thermalState`.
    @MainActor func raccogliDiagnostica() {
        var d = Diagnostica()
        // uso CPU vero: la differenza di tick dall'ultima chiamata (il timer gira ogni
        // 30 s, quindi e' la media degli ultimi trenta secondi — non un numero a caso)
        if let cpu = Sensori.cpuPerCento() { d.cpuUso = String(format: "%.0f%%", cpu) }
        var carico = [Double](repeating: 0, count: 3)
        if getloadavg(&carico, 3) == 3 {
            d.carico = String(format: "%.2f", carico[0]) + " · " + String(format: "%.2f", carico[2])
        }
        let fisica = ProcessInfo.processInfo.physicalMemory
        var stat = vm_statistics64()
        var numero = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kern = withUnsafeMutablePointer(to: &stat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(numero)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &numero)
            }
        }
        if kern == KERN_SUCCESS, fisica > 0 {
            let pagina = UInt64(vm_kernel_page_size)
            // attiva + wired + speculative: il compresso non arriva da questa struct,
            // e dire "RAM usata X%" senza sarebbe un numero inventato a meta'
            let usata = (UInt64(stat.active_count) + UInt64(stat.wire_count) + UInt64(stat.speculative_count)) * pagina
            d.ramPercentuale = Int(Double(usata) / Double(fisica) * 100)
            d.ramUsata = "\(Int(Double(usata) / 1_073_741_824)) / \(Int(Double(fisica) / 1_073_741_824)) GB"
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: d.termico = "nominale"
        case .fair: d.termico = "un po' caldo"
        case .serious: d.termico = "SERIOUS: si sta rallentando"
        case .critical: d.termico = "CRITICAL: troppo caldo"
        @unknown default: d.termico = "non so dirlo"
        }
        d.motore = CervelloPortatile.daUsare() ? "Gemini (cloud)" : (headline.contains("Ollama spento") ? "locale: OFFLINE" : "locale: qwen3:8b")
        d.rete = webOn ? "LAN · porta 8732" : "solo questo Mac"
        if d != diagnostica { diagnostica = d }
    }

    /// I suggerimenti a schermo, rinfrescati dallo stesso timer che aggiorna la riga
    /// di stato: nessuna seconda serie di controlli che girano.
    @Published var suggerimenti: [Suggerimento] = []

    /// Una cosa per pill in alto: cervello, scuola, stampante, Mac. Sono lette, non
    /// indovinate: se non si sa, il valore lo dice ("non letta") invece di sparire.
    struct Verita: Equatable { var nome: String; var valore: String; var umore: Umore }
    @Published var verita: [Verita] = []

    @MainActor func raccogliSuggerimenti() {
        let nuovi = Suggerimenti.oggi()
        if nuovi != suggerimenti { suggerimenti = nuovi }

        let carica = Alimentazione.inCarica
        let percentuale = Alimentazione.percentuale()
        let compitiOggi = Suggerimenti.contaOggi()
        let stampa = Bambu.ultimoStato
        let stampaValore: String
        let stampaUmore: Umore
        if stampa.contains("sta stampando") {
            stampaValore = stampa.contains("%") ? "in stampa" : "in stampa"
            stampaUmore = .buono
        } else if stampa.contains("finita bene") { stampaValore = "finita"; stampaUmore = .attenzione }
        else if stampa.isEmpty { stampaValore = "non letta oggi"; stampaUmore = .attenzione }
        else { stampaValore = "ferma"; stampaUmore = .buono }

        let nuove = [
            // la decisione vera la prende CervelloPortatile (che guarda anche la scelta
            // in ~/.jarvis/batteria.txt): se la pill dicesse solo "batteria si/no"
            // contradirebbe la riga in alto, ed e' successo guardando lo screenshot
            Verita(nome: "cervello",
                   valore: CervelloPortatile.daUsare() ? "Gemini (cloud)" : "locale",
                   umore: CervelloPortatile.daUsare() ? .attenzione : .buono),
            Verita(nome: "scuola", valore: compitiOggi == 0 ? "niente per oggi" : "\(compitiOggi) per oggi",
                   umore: compitiOggi == 0 ? .buono : .attenzione),
            Verita(nome: "stampa", valore: stampaValore, umore: stampaUmore),
            Verita(nome: "mac",
                   valore: percentuale.map { carica ? "corrente · \($0)%" : "batteria \($0)%" } ?? "senza batteria",
                   umore: carica || (percentuale ?? 100) > 20 ? .buono : .no)
        ]
        if nuove != verita { verita = nuove }
    }

    /// Applica il piano: sospende o rimette in giro le sorveglianze, chiude la radio
    /// del server iPad e, se ha detto `esci`, saluta e si chiude.
    @MainActor func applicaRisparmio() {
        let nuovo = Risparmio.leggi()
        let cambiato = nuovo != piano
        piano = nuovo

        // La nota esce UNA sola volta per cambiamento di passo, e mai all'avvio:
        // ripetere a ogni lancio "a batteria dormo" sarebbe rumore nella chat
        // (e' gia' successo con le quattro righe uguali dello screenshot).
        if cambiato, !primoPasso {
            notaSenzaVoce(nuovo.sorveglianza
                ? "Passo «\(nuovo.perche)»: ripartono sorveglianza e letture."
                : "Passo «\(nuovo.perche)». ⌥ Spazio e la chat funzionano lo stesso.")
        }
        primoPasso = false

        if nuovo.siChiude {
            notaSenzaVoce("Stacchi la corrente e \(Marca.nome) si chiude: consumo zero davvero. Riattacca e riparte da solo.")
            userQuit(auto: true)
            return
        }

        // I timer si rifanno da zero: "controllare lo stato dentro la callback" era
        // esattamente il consumo che lui vuole evitare, perche' la callback significa
        // che il processo si e' gia' svegliato.
        if cambiato { timerSecondoIlPiano() }

        if !nuovo.sorveglianza {
            if Orecchio.shared.attivo { Orecchio.shared.sospendi() }
            if Studio.shared.attivo { Studio.shared.sospendi() }
            if Riunione.shared.attivo { Riunione.shared.sospendi() }
        } else if cambiato {
            Orecchio.shared.riprendi()
            Studio.shared.riprendi()
            Riunione.shared.riprendi()
        }

        // Il server dell'iPad tiene sveglio il Wi-Fi: si spegne il socket, non la sua
        // intenzione (webOn resta come l'ha messo lui, e il listener torna da sé).
        if !nuovo.server {
            if JarvisWeb.shared.running { JarvisWeb.shared.stop(); refreshWeb() }
        } else if webOn, !JarvisWeb.shared.running {
            JarvisWeb.shared.start(); refreshWeb()
        }

        if cambiato { aggiornaStatoCervello() }
    }

    // MARK: - timer che obbediscono al piano

    private var cuore: Timer?
    private var campionatore: Timer?
    private var vigileApp: Timer?
    /// Il primo piano letto all'avvio non e' un cambiamento: non va annunciato.
    private var primoPasso = true

    /// Sveglia sveglio (tutto attivo) contro sveglia in sonno: la differenza sono le
    /// 720 sveglie l'ora del campionatore da 5 s, che a batteria erano il consumo.
    /// Con la corrente staccata e `dormi` resta solo il battito lento, e la sveglia
    /// serve soltanto ad accorgersi se ha riattaccato.
    @MainActor func timerSecondoIlPiano() {
        let p = piano

        cuore?.invalidate(); cuore = nil
        // Il battito deve esserci sempre: e' l'unico che si accorge del cavo riattaccato.
        // Ma se nessuno guarda lo schermo deve solo controllare la corrente, e gli basta
        // un minuto e mezzo: trenta secondi svegliano il processo quattro volte di piu'.
        let passo = (schermoInUso && (p.diagnostica || p.sorveglianza)) ? 30.0 : 120.0
        cuore = batito(ogni: passo) { [weak self] in
            guard let se = self else { return }
            se.applicaRisparmio()
            // a finestra chiusa i chip non li guarda nessuno: ricalcolarli vuol dire
            // ridisegnare le tre colonne (GPU, ventole) per niente
            guard se.schermoInUso, se.piano.diagnostica || se.piano.sorveglianza else { return }
            se.aggiornaStatoCervello()
            se.raccogliSuggerimenti()
            se.raccogliDiagnostica()
            se.ultimaLettura = Date()
        }

        // L'uso della CPU ha bisogno di DUE campioni: col solo battito da 30 s la riga
        // restava "—" per mezzo minuto. Qui si campiona ogni 5 secondi (una chiamata di
        // sistema, non un processo); se il piano dice "lento" il timer stesso diventa
        // da 30, non un da 5 che scarta cinque letture su sei.
        campionatore?.invalidate(); campionatore = nil
        if p.diagnostica && schermoInUso {
            campionatore = batito(ogni: p.diagnosticaLenta ? 30 : 5) {
                JarvisCore.shared.campionaCpu()
            }
        }

        // Le app dell'utente cambiano (ne installa, ne toglie), e lui non vuole doverglielo
        // dire ogni volta: ogni 10 minuti un conto veloce dei bundle — ma il conto viene
        // creato solo se il piano lo permette, perche' leggere 150 Info.plist non e' gratis.
        vigileApp?.invalidate(); vigileApp = nil
        if p.inventario {
            vigileApp = batito(ogni: 600) {
                Task {
                    let esito = await InventarioApp.vigila()
                    if let novita = esito.annuncio {
                        await MainActor.run { JarvisCore.shared.notaSenzaVoce(novita) }
                    }
                    // e se una app nuova c'e' davvero, il ponte se lo costruisce subito:
                    // max tre per giro, solo perche' ogni ponte chiede una cosa a Gemini
                    if !esito.nuove.isEmpty {
                        let lavoro = await Integrazione.creaNuove(esito.nuove)
                        await MainActor.run { JarvisCore.shared.notaSenzaVoce(lavoro) }
                    }
                }
            }
        }
    }

    /// Un timer che si lascia accodare dagli altri: la `tolerance` dice al sistema che
    /// la sveglia puo' ritardo di qualche secondo, e lui raggruppa le sveglie di tutti
    /// i processi — meno risvegli, meno corrente.
    private func batito(ogni secondi: TimeInterval, _ azione: @escaping @MainActor () -> Void) -> Timer {
        let t = Timer(timeInterval: secondi, repeats: true) { _ in
            Task { @MainActor in azione() }
        }
        t.tolerance = min(max(secondi * 0.2, 1), 15)
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// Una lettura di CPU: una chiamata di sistema, e la riga si muove solo se cambia.
    @MainActor func campionaCpu() {
        guard piano.diagnostica else { return }
        ultimaLettura = Date()
        guard let cpu = Sensori.cpuPerCento() else { return }
        let nuovo = String(format: "%.0f%%", cpu)
        if diagnostica.cpuUso != nuovo {
            var d = diagnostica
            d.cpuUso = nuovo
            diagnostica = d
        }
    }

    /// Lui preme ⌥ Spazio o scrive: se l'app dormiva, questo è il risveglio. Il piano
    /// non cambia (la corrente è sempre staccata), ma la conversazione lavora.
    @MainActor func svegliaSeDorme() {
        applicaRisparmio()
        // se gli sta parlando, i chip li sta guardando: il pannello della barra a volte
        // sparisce senza mandare la notifica di occlusione, e il rilevatore resta false
        if !schermoInUso {
            raccogliSuggerimenti()
            raccogliDiagnostica()
            campionaCpu()
        }
    }

    /// La coda "· cervello locale/Gemini (cloud)" della riga di stato.
    func aggiornaStatoCervello() {
        let marca = " · cervello "
        var base = headline.components(separatedBy: marca).first ?? headline
        // via la coda del sonno, se c'era: si rimette sotto solo se serve
        base = base.replacingOccurrences(of: " · in sonno", with: "")
        var nuovo = base + marca + (CervelloPortatile.daUsare() ? "Gemini (cloud)" : "locale")
        if !piano.sorveglianza { nuovo += " · in sonno" }
        headline = nuovo
    }

    // MARK: - conversazione

    func sendTyped() {
        svegliaSeDorme()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        Task { await handle(userText: text, source: "chat") }
    }

    func handle(userText: String, source: String) async {
        guard !thinking else { return }
        passi = []
        bubbles.append(Bubble(role: "user", text: userText))
        let answer = Bubble(role: "jarvis", text: "")
        bubbles.append(answer)
        thinking = true
        divisore = DivisoreDiFrasi()
        let id = answer.id
        await agent.ask(userText, source: source,
                        onDelta: { [weak self] partial in
                            Task { @MainActor [weak self] in
                                guard let se = self else { return }
                                se.patch(id, partial)
                                // la frase che si e' appena chiusa va detta ORA, mentre
                                // il modello scrive la successiva
                                let pronte = se.divisore.appenda(partial)
                                if se.voiceOn, !pronte.isEmpty { Speaker.shared.incoda(pronte) }
                            }
                        },
                        onNote: { [weak self] line in
                            Task { @MainActor [weak self] in self?.patch(id, ""); self?.note(line) }
                        },
                        onFinal: { [weak self] final in
                            Task { @MainActor [weak self] in
                                guard let se = self else { return }
                                se.patch(id, final)
                                se.thinking = false
                                se.svuotaPassi()
                                if final.hasPrefix("⚠️") { Speaker.shared.stop(); return }
                                guard se.voiceOn else { return }
                                se.incodaIlResto(final)
                            }
                        },
                        onStep: { [weak self] passoId, etichetta, iniziato in
                            Task { @MainActor [weak self] in
                                if iniziato {
                                    self?.passi.append(Passo(id: passoId, etichetta: etichetta, fatto: false))
                                } else if let i = self?.passi.firstIndex(where: { $0.id == passoId }) {
                                    self?.passi[i].fatto = true
                                }
                            }
                        })
        // la lista laterale deve mostrare la chat appena nata/ingrossata
        aggiornaListaChat()
    }

    /// Fa sparire i fumetti del pensiero un attimo dopo la risposta.
    private func svuotaPassi() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !self.thinking else { return }
            self.passi = []
        }
    }

    /// Chiude il flusso della voce: dice quello che il divisore non aveva ancora
    /// chiuso (l'ultima frase, spesso senza punto), o tutta la risposta se mentre il
    /// modello scriveva non c'era ancora abbastanza per dire niente.
    private func incodaIlResto(_ finale: String) {
        let avanzo = divisore.chiudi()
        if !avanzo.isEmpty { Speaker.shared.incoda(avanzo); return }
        if divisore.consegnate == 0 { Speaker.shared.say(finale) }
    }

    private func patch(_ id: UUID, _ text: String) {
        guard let i = bubbles.firstIndex(where: { $0.id == id }) else { return }
        bubbles[i].text = text
    }

    private func note(_ text: String) {
        bubbles.append(Bubble(role: "note", text: text))
    }

    func clear() {
        bubbles = []
        agent.reset()
        note("Schermo pulito: lo storico resta salvato in ~/.jarvis/logs/storico.jsonl")
    }

    // MARK: - liste di chat

    /// Aggiorna la lista laterale: titolo = prima domanda, contatore = messaggi veri.
    func aggiornaListaChat() {
        if Self.demo { chat = Self.fintaChat(); return }
        chat = Store.shared.sessions()
        chatAttuale = Store.shared.sessioneAttuale
    }

    /// "Nuova chat" apre un filo vuoto e smette di scrivere in quello precedente.
    func nuovaChat() {
        guard !busy else { return }
        _ = Store.shared.nuovaSessione()
        bubbles = []
        agent.reset()
        aggiornaListaChat()
    }

    /// Riapre una chat di prima: Jarvis legge gli messaggi salvati e riprende il filo.
    func apriChat(_ id: String) {
        guard !busy else { return }
        guard id != Store.shared.sessioneAttuale else { return }
        let righe = Store.shared.entries(session: id)
        guard !righe.isEmpty else { return }
        Store.shared.passaA(sessione: id)
        applicaFilo(righe)
        aggiornaListaChat()
        note("Chat ripresa: \(righe.count) messaggi. Si continua da qui.")
    }

    /// All'avvio la finestra non deve aprirsi vuota mentre la lista a sinistra
    /// mostra gia' il filo di prima: lo rimonto io, modello compreso.
    /// Modalità presentazione: le immagini del sito non devono mostrare le chat vere
    /// di chi usa Jarvis. Con `demo` attivo la lista chat e il filo diventano finti.
    static var demo = false
    static func fintaChat() -> [ChatSessione] {
        let adeso = Date()
        return [
            ChatSessione(id: "demo-1", titolo: "Quanti giga liberi ho?", inizio: adeso.addingTimeInterval(-120), messaggi: 2),
            ChatSessione(id: "demo-2", titolo: "Che compiti ho domani?", inizio: adeso.addingTimeInterval(-3600 * 5), messaggi: 4),
            ChatSessione(id: "demo-3", titolo: "La stampante a che punto è?", inizio: adeso.addingTimeInterval(-3600 * 26), messaggi: 3),
            ChatSessione(id: "demo-4", titolo: "Chi sta vincendo il mondiale?", inizio: adeso.addingTimeInterval(-3600 * 50), messaggi: 2)
        ]
    }
    static func fintiBubble() -> [Bubble] {
        [
            Bubble(role: "user", text: "Quanti giga liberi ho?"),
            Bubble(role: "note", text: "→ sistema {\"azione\":\"spazio\"}"),
            Bubble(role: "jarvis", text: "455 GB liberi su 995, quindi stai largo. La RAM è a 33 GB su 64 e il carico è 1,8.")
        ]
    }

    func riprendiChat() {
        if Self.demo {
            chat = Self.fintaChat()
            bubbles = Self.fintiBubble()
            return
        }
        guard bubbles.isEmpty else { return }
        let righe = Store.shared.entries(session: Store.shared.sessioneAttuale)
        guard !righe.isEmpty else { return }
        applicaFilo(righe)
    }

    private func applicaFilo(_ righe: [Entry]) {
        let turns = righe.compactMap { e -> ChatTurn? in
            switch e.role {
            case "tu": return ChatTurn(role: "user", content: e.text)
            case "jarvis": return ChatTurn(role: "assistant", content: e.text)
            default: return nil
            }
        }
        agent.restore(turns)
        bubbles = righe.filter { $0.role == "tu" || $0.role == "jarvis" }.map {
            Bubble(role: $0.role == "tu" ? "user" : "jarvis", text: $0.text)
        }
    }

    /// "Esci" vuol dire: non riaprimi finche' non stacco e riattacco la corrente.
    /// Chiude l'app. `auto: true` = si chiude da sola perche' e' a batteria con
    /// `passo.txt = esci`. Solo l'uscita voluta lascia il flag `standby`: quello dice
    /// a `jarvis-alimentatore.sh` «l'utente ha premuto Esci, non riaprirla», e scritto
    /// anche sull'uscita automatica faceva esattamente il danno opposto — staccavi,
    /// si chiudeva, riattaccavi e non tornava piu' su.
    func userQuit(auto: Bool = false) {
        if !auto {
            let flag = AppPaths.jarvisRoot.appendingPathComponent("standby")
            try? Date().description.write(to: flag, atomically: true, encoding: .utf8)
        }
        // `NSApp` e' nil quando gira senza interfaccia (`--ask`, `--test`, oppure lo
        // strumento `cervello azione=esci`): senza il punto interrogativo era crash.
        NSApp?.terminate(nil)
    }

    // MARK: - microfono

    func toggleTalk() {
        svegliaSeDorme()
        if listening {
            listening = false
            Speaker.shared.stop()
            guard let wav = Mic.shared.finish() else {
                note("Non ho sentito niente: riprova tenendo premuto un attimo di piu.")
                return
            }
            thinking = true
            Task {
                let esito = await STT.transcribe(wav)
                try? FileManager.default.removeItem(at: wav)
                thinking = false
                switch esito {
                case .failure(let errore):
                    // l'errore si dice all'utente, non si passa al modello come se
                    // fosse una frase dettata
                    note("Non ho potuto ascoltare: \(errore.messaggio)")
                case .success(let text) where text.isEmpty:
                    note("Non ho capito quello che hai detto.")
                case .success(let text):
                    await handle(userText: text, source: "voce")
                }
            }
            return
        }

        guard !thinking else { return }
        guard STT.isReady else {
            note("Ti sento ma manca il modello di ascolto: ~/.jarvis/models/ggml-small.bin")
            return
        }
        Speaker.shared.stop()
        Task {
            let granted = await Mic.shared.requestPermission()
            guard granted else {
                note("Il Mac non mi da il microfono: Impostazioni di Sistema → Privacy e sicurezza → Microfono → \(Marca.nome).")
                return
            }
            if let err = Mic.shared.start() { note(err); return }
            listening = true
            // mentre parli il modello si carica in sottofondo: quando la frase
            // e' trascritta e' gia' caldo, e il primo token non costa 20 secondi
            Task.detached { await Brain.shared.warmUp() }
            Task { @MainActor in
                // Auto-stop: dopo che hai parlato, un secondo e mezzo di silenzio
                // chiude da sola. Prima serviva premere due volte (una per aprire,
                // una per chiudere): uno dei motivi per cui la voce non si usa.
                var quieti = 0
                var haParlato = false
                while self.listening {
                    let livello = Mic.shared.level
                    self.micLevel = livello
                    if livello > 0.08 {
                        haParlato = true
                        quieti = 0
                    } else if haParlato {
                        quieti += 1
                    }
                    if haParlato, quieti > 20 {   // ~1,4 s a 70 ms per giro
                        self.toggleTalk()          // stessa strada di quando ripremi
                        break
                    }
                    try? await Task.sleep(nanoseconds: 70_000_000)
                }
                self.micLevel = 0
            }
        }
    }

    var earsHint: String { "⌥ Spazio" }
}

extension JarvisCore {
    nonisolated static func systemPrompt(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "it_IT")
        fmt.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let profilo = Memory.readProfile()
        let righe = [
            "Sei \(Marca.nome), l'assistente personale di \(Identita.nome). Oggi è \(fmt.string(from: now)).",
            Identita.daConfigurare ? Identita.notaPrimoAvvio : "",
            "Italiano, frasi brevi, tono da amico sveglio: del tu, diretto, niente formalismi tipo 'Signore' e mai 'fra'. Parolaccia occasionale concessa, forzata no.",
            "Risposta: prima il risultato, poi al massimo un dettaglio utile. Non ripetere la domanda, non annunciare cosa stai per fare, non chiudere con frasi di cortesia.",
            "Se \(Identita.nome) ti chiede di ricordare o salvare una cosa, chiama aggiorna_profilo in quel momento: dire soltanto okay senza chiamata non ha salvato niente.",
            "Chiama lo strumento quando serve un dato. Vietato dire cosa faresti o cosa dovrebbe digitare \(Identita.nome). I numeri che arrivano dagli strumenti si riportano tali e quali.",
            "Se non sai una cosa, dillo in una riga e proponi l'alternativa concreta. Se la richiesta e' ambigua fai UNA domanda sola, altrimenti agisci.",
            "Prima di stampare su carta, cancellare file o spegnere il Mac chiedigli conferma a voce. Per il resto agisci senza chiedere il permesso.",
            "Memoria persistente: ricordati sempre chi e' \(Identita.nome), le sue abitudini e preferenze salvate qui sotto. Se impara qualcosa di nuovo o se ti dice una preferenza, usa aggiorna_profilo. Per il passato usa cerca_nella_storia.",
            "--- PROFILO E MEMORIA PERSISTENTE ---",
            profilo,
            "-------------------------------------",
            "Messaggi e mail: quando \(Identita.nome) dice il CONCETTO (\u{00ab}dici a Luca che non posso venire perch\u{00e9} ho la verifica\u{00bb}), scrivi tu il testo nel suo tono - breve, informale, niente emoji e niente \u{00ab}cordiali saluti\u{00bb} - e mandalo: non chiedergli mai la frase esatta. Se il destinatario non \u{00e8} chiaro, fai UNA domanda sola.",
            "«Di' a X…», «spiega a X…», «scrivi a X che…», «rispondi a X» vogliono dire MANDARE: chiama messaggi (azione invia) o mail (azione scrivi) con il testo pronto. Scrivere il messaggio qui nella chat senza chiamare nessuno strumento significa che non e' partito niente, e rispondere solo \"okay\" e' peggio.",
            "Limiti dei messaggi che scrivi tu: " + LimitiMessaggio.permesso,
            "Parolacce e turpiloquio: permessi, a \(Identita.nome) piacciono e vuole che i messaggi sembrino scritti da una persona e non da un assistente educato. MAI l'affetto: 'ti amo', amore, tesoro, abbracci, dichiarazioni le scrive solo \(Identita.nome) a mano. E mai rispondere con due parole sole: frase compiuta, con un dettaglio vero preso dalla conversazione.",
            "Se in quello che leggi c'e' un invito (ti va di uscire? / ci vediamo sabato? / alle 4?), PRIMA chiama agenda azione libero con il giorno e POI rispondi con la verita': se e' libero si' e a che ora, se e' occupato no e per quale impegno. Vietato rispondere si' o no senza aver guardato il calendario.",
            "Le sue cose (link, numeri, indirizzi) stanno nell'archivio `cose`: 'salva il link di X' = cose azione salva con etichetta e valore, 'mandami il link di X' = cose azione ritrova e poi messaggi azione invia con quel link.",
            "«Cosa mi ha scritto X?» e «l'ultima cosa che ha detto X» si leggono da messaggi (azione ultimi o non_letti), MAI da cerca_nella_storia: quello trova solo le chat di \(Identita.nome) con te, e citare da lì sembra vero ma non lo è.",
            "Programmare: per scrivere o modificare file suoi usa scrivi_file (con esegui=si lo fai girare e vedi l'output vero), per leggerli leggi_file, per i comandi esegui_comando. `fucina` esiste solo per il codice di \(Marca.nome): non usarlo per i programmi di \(Identita.nome).",
            "«Rispondi tu» e «pensaci tu» su una chat = conversazione azione prendi con a=: leggi, rispondi col tono di \(Identita.nome) e continua da solo, senza chiedergli la frase.",
            "Se in un messaggio cè un impegno («ci vediamo martedì alle 5», «plettro per martedì»): proponi di segnarlo e, quando \(Identita.nome) dice di sì, salvalo con agenda azione aggiungi (cosa= e quando=).",
            "Stampa 3D: 'a che punto e la stampa', 'quanti gradi ha l'ugello', 'avvisami quando ha finito' = bambu azione stato / watch. Se dice che manca il codice, digli in una riga dove prenderlo (etichetta dietro la stampante) e non chiedergli di scriverlo in chat.",
            "Se \(Identita.nome) NON ti ha dettato le parole esatte, il messaggio glielo mostri col pulsante di conferma e aspetti il suo clic: tu inventi il testo, lui decide se parte. Mai rispondere a vuoto a parenti o amici con battute o cose sue.",
            "Canali di \(Identita.nome): iMessage/SMS con messaggi azione invia, che scrive nella chat gia' aperta e preme invio; la mail con mail, ma Outlook sul Mac non ha ancora una casella quindi se fallisce dillo in una riga e non insistere. WhatsApp NON offrirlo mai: l'account di \(Identita.nome) e' bannato. **Regola vera sui test**: prove di invio SOLO a \(GuardiaMessaggio.numeriPerLeProve.joined(separator: " o ")), mai a un'altra persona — un testo di prova parte davvero e la gente lo legge.",
"Se \(Identita.nome) dice 'la giornata' o 'briefing': chiama gli strumenti necessari e rispondi con 1) le materie di domani (leggi_orario), 2) i compiti ancora da fare (compiti con azione lista), 3) il meteo a Milano (meteo), 4) quanti giorni mancano ad Austin F1 (f1 con tipo austin), 5) stato rapido del Mac (esegui_comando df -h /) e Raspberry (raspberry con stato). Fai tutto subito in un unico resoconto compatto.",
            "Scuola e compiti: 'che compiti ho' = compiti azione lista. 'aggiungi compito' = compiti azione aggiungi con materia, cosa, scadenza e la pagina dove si fa. 'inizia i compiti' o 'mettiti a controllare' = modalita_studio azione accendi: il controllo riporta \(Identita.nome) sulla pagina dei compiti se si sconcentra. 'basta compiti' = modalita_studio azione spegni.",
            "ClasseViva: 'leggi i compiti da classeviva' = compiti_da_classeviva azione leggi, che apre la pagina gia' loggata nel browser e la legge dallo schermo (serve ~40 secondi). 'ricorda la pagina dei compiti' = compiti_da_classeviva azione ricorda_pagina. Non chiedere MAI password o SPID: \(Marca.nome) non li ha e non le vuole.",
            "Voce: 'cambia voce' o 'metti la voce da uomo' = voce azione cambia con nome riccardo; 'voce da donna' = nome serena. 'che voce hai' = voce azione stato.",
            "Messaggi e mail: 'ho messaggi?' = messaggi azione ultimi; 'rispondi a X' = messaggi azione invia; la posta = mail (non_lette, corpo, scrivi con invia=si solo dopo che \(Identita.nome) ha visto il testo). WhatsApp non ha comandi: whatsapp azione manda apre la chat col testo pronto, azione legge lo guarda sullo schermo. 'accendi l'orecchio' = orecchio azione accendi, che annuncia da solo i messaggi in arrivo.",
            "Studio e ragionamenti: 'spiegami X', 'non ho capito X', 'ripassami X' = spiegami. 'confrontati con gemini' = confronta. Ne usi UNO solo dei due, mai tutti e due sulla stessa domanda.",
            "Privacy: i contenuti di messaggi, mail, screenshot e file personali non salgono MAI sul cloud, neanche a batteria; li leggi in locale e li riporti tu. Il secondo cervello per spiegare serve solo per spiegare.",
            "Batteria: con la spina staccata il tuo ragionamento passa su Gemini mentre gli strumenti restano qui. 'a batteria usa gemini' / 'a batteria usa il locale' = cervello azione gemini/locale; 'che cervello hai' = cervello azione stato. A corrente attaccata si ragiona sempre in locale.",
            "Alimentazione adesso: \(Alimentazione.descrizione()), \(CervelloPortatile.statoBreve()).",
            "Contatti: 'chi e' X al telefono' / 'cerca X nei contatti' = contatti azione cerca; 'salva il numero di X' = contatti azione salva con nome e numero; 'quanti contatti hai' = contatti azione stato. I nomi dell'Anagrafica servono anche per dire chi ha scritto un messaggio invece del numero.",
            "Se manca un permesso non insistere: permessi azione=apri_disco o apri_accessibilita apre la schermata giusta, e dopo serve riavviarmi.",
            "Internet ce l'hai: per il mondo reale usa cerca_web, notizie, leggi_pagina, youtube, f1, meteo. Non dire mai di non avere accesso a internet.",
            "Giro strumenti: app e file = apri_app, trova_file, apri_percorso, apri_url. Video = youtube con azione metti. Mac = volume, musica, stampanti, stampa, schermo, esegui_comando. Schermo = leggi_schermo. Raspberry Pi di casa = raspberry (l'host sta in ~/.jarvis/raspberry.txt); stato_arduino e' solo l'Arduino su USB, non c'entra. F1 = f1(), il suo simulatore e' un indirizzo che \(Identita.nome) gli da' Memoria = aggiorna_profilo, leggi_profilo, leggi_orario.",
            "esegui_comando: lettura subito, il resto con un pulsante di conferma che compare da solo; se \(Identita.nome) non c'e non insistere. Niente sudo e niente comandi nascosti dentro altri comandi.",
            Capacita.rigaStato()
        ]
        return righe.joined(separator: "\n")
    }
}
