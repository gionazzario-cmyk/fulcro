import Foundation

/// Il **ponte** che Jarvis si costruisce da sé quando sul Mac compare una app nuova.
///
/// Lui la chiama "estensione", e di un'estensione ha la stessa forma: un pezzo che
/// aggiunge all'assistente la conoscenza di una cosa che non c'era. Qui dentro non c'è
/// codice compilato — che sarebbe la strada sbagliata, perche' significherebbe
/// ricompilare l'app ogni volta che installa qualcosa (e chi scarica il programma non
/// potrebbe farlo). C'è una scheda di testo in `~/.jarvis/app/integrazioni/<app>.md`,
/// letta quando il nome di quell'app compare nella domanda: cosi' il modello non deve
/// esplorare lo strumento e non deve indovinare i verbi.
///
/// Da dove vengono le informazioni. **Tutto quello che l'app dichiara da sé lo legge il
/// bundle**: categoria, versione, architettura, schemi URL, tipi di file che apre, verbi
/// AppleScript della sua `.sdef`. A Gemini si chiede solo il pezzo che un bundle non
/// contiene: come la nomina una persona, quali tre verbi convengono davvero, cosa non si
/// può farle fare da script. E il testo che parte è costruito apposta **senza percorsi e
/// senza nome dell'utente** (`bozzaPerGemini`): l'unica cosa che esce dal Mac è il nome
/// dell'app e le sue capacità pubbliche.
enum Integrazione {
    /// Nei test si punta a una cartella provvisoria, per non scrivere schede finte nella
    /// sua (`JARVIS_INTEGRAZIONI`, stessa idea di `BAMBU_CONF`).
    static var cartella: URL {
        if let prova = cartellaDiProva { return prova }
        if let dev = ProcessInfo.processInfo.environment["JARVIS_INTEGRAZIONI"], !dev.isEmpty {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }
        return AppPaths.jarvisRoot.appendingPathComponent("app/integrazioni")
    }

    /// Solo per i test: sposta la cartella senza toccare l'ambiente, cosi' le schede finte
    /// non finiscono nelle sue.
    static var cartellaDiProva: URL?

    static func filePer(_ nome: String) -> URL {
        cartella.appendingPathComponent(InventarioApp.senzaAccenti(nome) + ".md")
    }

    static func esiste(_ nome: String) -> Bool {
        FileManager.default.fileExists(atPath: filePer(nome).path)
    }

    static func quante() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: cartella.path)) ?? [])
            .filter { $0.hasSuffix(".md") }.count
    }

    static func letta(_ nome: String) -> String? {
        try? String(contentsOf: filePer(nome), encoding: .utf8)
    }

    // MARK: - cosa esce dal Mac

    /// La domanda a Gemini, con le redini corte: se le si chiede "descrivi l'app" risponde
    /// con tre paragrafi e comandi inventati, e un comando inventato che poi parte da `esegui_comando`
    /// è peggio di nessun comando.
    static let istruzioniNuvola = """
    Mi serve il "ponte" per questa app, da usare dentro un assistente locale che la pilota \
    con i suoi comandi dichiarati. Regole strette: non inventare comandi che non sono nella \
    lista, non scrivere percorsi di file, non aggiungere niente che non derivi dai dati qui \
    sotto o da ciò che è pubblicamente noto dell'app. Rispondi SOLO con queste quattro righe, \
    senza titoli e senza markdown:
    FRASI: tre modi diversi in cui uno le chiede una cosa, in italiano
    VERBI: i tre comandi più utili tra quelli dichiarati nella sua .sdef
    SCHEMI: a cosa serve il suo schema URL, in una riga (o "nessuno")
    LIMITI: una riga su cosa NON si può farle fare da script
    """

    /// Il messaggio che parte per il cloud. `percorso` **non** c'è apposta: è l'unica cosa
    /// che identificherebbe il Mac di chi usa Jarvis insieme al suo nome.
    static func bozzaPerGemini(_ s: SchedaApp) -> String {
        let verbi = s.comandiAppleScript ?? []
        var t = "app: \(s.nome)\n"
        t += "bundle id: \(s.id)\n"
        t += "categoria: \(s.categoria) · versione: \(s.versione) · architettura: \(s.architettura)\n"
        t += "schemi URL dichiarati: " + (s.schemi.isEmpty ? "nessuno" : s.schemi.joined(separator: ", ")) + "\n"
        t += "estensioni di file che apre: " + (s.estensioni.isEmpty ? "nessuna" : s.estensioni.prefix(12).joined(separator: ", ")) + "\n"
        t += "verbi AppleScript dichiarati dalla sua .sdef: " + (verbi.isEmpty ? "nessuno" : verbi.prefix(20).joined(separator: ", "))
        return t
    }

    // MARK: - la scheda

    /// Lo scheletro, scritto con i soli dati del bundle: esiste anche senza chiave Gemini,
    /// perche' il 90% del ponte lo sa già l'app stessa.
    static func scheletro(_ s: SchedaApp, nuvola: String?, motivo: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let verbi = s.comandiAppleScript ?? []
        var t = "# \(s.nome)\n"
        t += "<!-- ponte generato il \(f.string(from: Date())) da \(Marca.nome) · "
        t += "dati letti dal bundle · Gemini: \(nuvola != nil ? "usato per frasi e limiti" : "non usato" + (motivo.map { " (\($0))" } ?? "")) -->\n\n"
        t += "## Cosa può fare (dichiarato dal suo bundle)\n"
        t += "- categoria: \(s.categoria) · versione \(s.versione) · \(s.architettura)\n"
        t += "- schemi URL: " + (s.schemi.isEmpty ? "nessuno" : s.schemi.joined(separator: ", ")) + "\n"
        t += "- apre file: " + (s.estensioni.isEmpty ? "nessuno" : s.estensioni.prefix(14).joined(separator: ", ")) + "\n"
        t += "- verbi AppleScript suoi: " + (verbi.isEmpty ? "nessuno (si pilota con tasti e schermo)" : verbi.joined(separator: ", ")) + "\n\n"
        if let nuvola, !nuvola.isEmpty {
            t += "## Letto da Gemini (solo frasi e limiti, mai comandi inventati)\n"
            t += nuvola.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        // Si dichiara: cosa è uscito dal Mac per costruire questa scheda. Se un giorno
        // lui vuole controllare cosa parte verso il cloud, la risposta è scritta qui.
        t += "## Cosa è uscito dal Mac per questa scheda\n"
        t += "- nome dell'app, bundle id, categoria, versione, architettura\n"
        t += "- gli schemi URL, i tipi di file e i verbi che l'app dichiara nel suo bundle\n"
        t += "- **non** i percorsi dei file, **non** il nome di chi usa \(Marca.nome), **non** niente delle sue chat\n\n"
        t += "## Come si usa da qui\n"
        t += "- aprire: `app azione=apri nome=\(s.nome)` (in background, senza rubarti lo schermo)\n"
        t += "- pilotare: i verbi qui sopra con `esegui_comando` via osascript, che chiede il tuo clic\n"
        t += "- una cosa imparata: `app azione=nota nome=\(s.nome) testo=...` (fine in Ricette)\n\n"
        t += "## Ricette provate\n"
        t += "(nessuna ancora: quando una cosa funziona davvero Jarvis la scrive qui)\n"
        return t
    }

    // MARK: - costruirla

    /// Gemini, dopo le quattro righe chieste, spesso aggiunge il **perché** di ogni scelta
    /// (un secondo blocco FRASI/VERBI/SCHEMI/LIMITI con le scuse). Sono parole sue che non
    /// servono a pilotare niente e che raddoppiano la scheda — e i token nel prompt qui sono
    /// stati misurati, quindi costano risposte. Se non c'è nessuna delle quattro chiavi la
    /// risposta è fuori formato e non entra: la scheda resta locale, e lo dichiara.
    static func ripulisciNuvola(_ testo: String) -> String {
        let chiavi = ["FRASI", "VERBI", "SCHEMI", "LIMITI"]
        var fuori: [String] = []
        var viste = Set<String>()
        for riga in testo.split(separator: "\n", omittingEmptySubsequences: true) {
            let r = riga.trimmingCharacters(in: .whitespaces)
            guard let chiave = chiavi.first(where: { r.uppercased().hasPrefix($0 + ":") }),
                  !viste.contains(chiave) else { continue }
            viste.insert(chiave)
            fuori.append(r)
            if viste.count == chiavi.count { break }
        }
        return fuori.joined(separator: "\n")
    }

    /// Costruisce (o rifà) il ponte di una app. Con la chiave chiede anche la parte che il
    /// bundle non dice; senza, la scheda esce lo stesso e lo dichiara: una scheda che finge
    /// di aver consultato qualcuno è il tipo di bugia che lui ha vietato fin dal primo giorno.
    @MainActor static func integra(_ s: SchedaApp, conNuvola: Bool = true) async -> String {
        var nuvola: String? = nil
        // il motivo per cui la nuvola non è stata usata, detto come sta davvero: "niente
        // chiave" quando manca, "ha risposto fuori formato" quando la chiave c'è ma la
        // risposta non serviva a niente. Una scheda che dice una scusa sbagliata è peggio
        // di una scheda locale.
        var perche: String? = nil
        if !conNuvola {
            perche = "nuvola disattivata per questa prova"
        } else if !Gemini.pronto {
            perche = "nessuna chiave Gemini"
        } else {
            let risposta = await Gemini.chiedi(istruzioniNuvola + "\n\n" + bozzaPerGemini(s))
            // `chiedi` risponde con la scusa quando la chiave non c'e' ("Non hai ancora
            // messo la chiave...") o quando Google non ha risposto: in quei casi il ponte
            // resta locale, e la scheda lo dichiara. Si guarda l'inizio del messaggio, non
            // la parola "chiave": una risposta legittima potrebbe contenerla (i limiti di
            // una app che gestisce password, per dire) e si perderebbe il ponte.
            if risposta.hasPrefix("Non hai ancora") {
                perche = "nessuna chiave Gemini"
            } else {
                let pulita = ripulisciNuvola(risposta)
                if pulita.isEmpty {
                    perche = "Gemini ha risposto fuori formato"
                } else {
                    nuvola = pulita
                }
            }
        }
        let testo = scheletro(s, nuvola: nuvola, motivo: perche)
        do {
            try FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
            try testo.write(to: filePer(s.nome), atomically: true, encoding: .utf8)
        } catch {
            return "Non sono riuscito a scrivere il ponte di \(s.nome): \(error.localizedDescription)"
        }
        let verbi = (s.comandiAppleScript ?? []).count
        return "Ponte di \(s.nome) creato"
            + (nuvola == nil ? " solo con i dati del bundle (\(perche ?? "nuvola non usata"))" : " con l'aiuto di Gemini")
            + ": \(verbi) verbi AppleScript, \(s.schemi.count) schemi URL, \(s.estensioni.count) tipi di file. "
            + "Lo trovo in \(filePer(s.nome).path)."
    }

    /// La scelta di cosa fare in questo giro, separata dall'esecuzione perche' cosi' il
    /// tetto si puo' provare senza chiamare nessuno.
    static func daFare(_ nuove: [SchedaApp], massimo: Int) -> [SchedaApp] {
        Array(nuove.filter { !esiste($0.nome) }.prefix(massimo))
    }

    /// Le app nuove uscite dal conteggio. Non piu' di `massimo` per volta: una chiamata a
    /// Gemini costa tempo e rete, e se lui ha appena installato dieci cose il Mac non
    /// deve mettersi a fare dieci ponti in un giro solo.
    @MainActor static func creaNuove(_ nuove: [SchedaApp], massimo: Int = 3) async -> String {
        let lavoro = daFare(nuove, massimo: massimo)
        guard lavoro.count > 0 else {
            return nuove.isEmpty ? "" : "I ponti c'erano già per tutte."
        }
        var righe: [String] = []
        for s in lavoro { righe.append(await integra(s)) }
        if nuove.count > lavoro.count {
            righe.append("(\(nuove.count - lavoro.count) in coda: le faccio al prossimo giro, "
                         + "o di' «fai il ponte di X» per farne una subito)")
        }
        return righe.joined(separator: "\n")
    }

    /// Le poche righe che finiscono nel prompt di testa quando lui nomina l'app: non la
    /// scheda intera (costa token, e i token qui sono stati misurati), ma il modo di
    /// raggiungerla e i verbi veri.
    static func sintesiPerIlPrompt(_ s: SchedaApp) -> String {
        guard let testo = letta(s.nome) else { return "" }
        var fuori = "PONTE DI \(s.nome) (letto da ~/.jarvis/app/integrazioni, non a memoria):\n"
        var dentro = false
        for riga in testo.split(separator: "\n") {
            let r = String(riga)
            if r.hasPrefix("## ") {
                dentro = r.contains("Cosa può fare") || r.contains("Letto da Gemini")
                continue
            }
            if dentro, r.hasPrefix("-") || r.hasPrefix("FRASI") || r.hasPrefix("VERBI") || r.hasPrefix("LIMITI") {
                fuori += "  " + r + "\n"
            }
        }
        return fuori.count > 900 ? String(fuori.prefix(900)) : fuori
    }
}
