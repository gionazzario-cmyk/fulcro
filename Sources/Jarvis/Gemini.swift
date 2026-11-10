import Foundation
import AppKit
import IOKit.ps

/// Il secondo cervello: Gemini Flash, usato solo quando qwen3 in locale non ci arriva.
///
/// Regole scelte con l'utente, non decise da me:
/// - la chiave sta in ~/.jarvis/gemini.txt, la scrive lui, non passa mai dalla chat;
/// - si chiama SOLO per ragionare e spiegare (studio, concetti, testi lunghi):
///   messaggi, mail, screenshot e percorsi dei file restano locali;
/// - se la chiave non c'e', non esplode e non finge: lo dice.
enum Gemini {
    static var chiaveFile: URL { AppPaths.jarvisRoot.appendingPathComponent("gemini.txt") }
    static var modelloFile: URL { AppPaths.jarvisRoot.appendingPathComponent("gemini-modello.txt") }
    static let modelloDiDefault = "gemini-3.8-flash"

    /// Google ritira i modelli vecchi senza avvisare: se uno da 404 si passa al
    /// successivo e quello buono si ricorda in ~/.jarvis/gemini-modello.txt.
    /// Modelli provati in ordine: i "lite" servono a batteria, dove la risposta
    /// deve arrivare subito. Quelli che non esistono rispondono 404 e si saltano.
    static let candidati = ["gemini-3.8-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash-lite",
                            "gemini-2.5-flash", "gemini-2.0-flash", "gemini-flash-lite-latest",
                            "gemini-flash-latest"]

    static var modelloMemorizzato: String? {
        get {
            let v = ((try? String(contentsOf: modelloFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        set { try? newValue?.write(to: modelloFile, atomically: true, encoding: .utf8) }
    }

    /// La chiave: il file puo' contenere solo la chiave, o `chiave=... modello=...`
    static func configurazione() -> (chiave: String, modello: String)? {
        guard let grezzo = try? String(contentsOf: chiaveFile, encoding: .utf8) else { return nil }
        var chiave = "", modello = modelloDiDefault
        for pezzo in grezzo.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
            let riga = pezzo.lowercased()
            if riga.hasPrefix("modello=") { modello = String(pezzo.dropFirst(8)) }
            else if riga.hasPrefix("chiave=") { chiave = String(pezzo.dropFirst(7)) }
            else if riga.hasPrefix("chiave=") { chiave = String(pezzo.dropFirst(7)) }
            else if chiave.isEmpty, !pezzo.isEmpty { chiave = String(pezzo) }
        }
        chiave = chiave.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chiave.count > 20 else { return nil }
        return (chiave, modello)
    }

    static var pronto: Bool { configurazione() != nil }

    /// Una domanda secca, risposta secca: niente strumenti, niente cronologia.
    static func chiedi(_ domanda: String, contesto: String = "") async -> String {
        guard let (chiave, modello) = configurazione() else {
            return "Non hai ancora messo la chiave di Gemini in ~/.jarvis/gemini.txt: senza quella \(Marca.nome) ragiona solo in locale."
        }
        var sistema = "Sei il secondo cervello di \(Marca.nome), l'assistente di \(Identita.nome). "
            + "Italiano semplice, frasi corte, prima la risposta poi il perche'. "
            + "Se e' materia scolastica, spiega come farebbe un compagno sveglio che ha capito la lezione."
        if !contesto.isEmpty { sistema += " Contesto: \(contesto)" }

        let corpo: [String: Any] = [
            "systemInstruction": ["parts": [["text": sistema]]],
            "contents": [["role": "user", "parts": [["text": domanda]]]],
            "generationConfig": ["temperature": 0.4, "maxOutputTokens": 1400]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: corpo) else {
            return "Non riesco a preparare la domanda per Gemini."
        }
        guard URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modello):generateContent") != nil else {
            return "Indirizzo di Gemini non valido."
        }
        // prima quello che ha funzionato l'ultima volta, poi la lista
        var ordine: [String] = []
        if let ricordato = modelloMemorizzato { ordine.append(ricordato) }
        ordine.append(modello)
        for c in candidati where !ordine.contains(c) { ordine.append(c) }

        var ultimoErrore = ""
        for nome in ordine {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(nome):generateContent") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // la chiave va nell'header: in un processo figlio sarebbe finita nella riga
            // di comando, leggibile da chiunque guardi i processi
            req.setValue(chiave, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = data
            req.timeoutInterval = 45

            guard let (risposta, codice) = try? await URLSession.shared.data(for: req) else {
                return "Gemini non risponde: internet c'e'?"
            }
            let stato = (codice as? HTTPURLResponse)?.statusCode ?? -1
            let testo = String(decoding: risposta, as: UTF8.self)
            if stato == 200, let dati = try? JSONSerialization.jsonObject(with: risposta) as? [String: Any] {
                if nome != modello { modelloMemorizzato = nome }
                let estratto = estraiTesto(dati)
                return estratto.isEmpty ? "Gemini ha risposto vuoto." : estratto
            }
            if stato == 404 { ultimoErrore = "modello \(nome) non disponibile"; continue }
            if stato == 503 {
                // "high demand" di Google: non e' un no definitivo, si passa al
                // modello dopo e poi si riprova con calma
                ultimoErrore = "modello \(nome) saturo"
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            if stato == 400 || stato == 403 { return "Gemini ha rifiutato la chiave (controlla ~/.jarvis/gemini.txt)." }
            if stato == 429 { return "Gemini ha finito il gratuito di oggi: si riprova domani o si resta su locale." }
            return "Gemini ha risposto male (\(stato)): \(String(testo.prefix(200)))"
        }
        return "Nessun modello Gemini disponibile con questa chiave (\(ultimoErrore))."
    }

    /// Il JSON di Gemini ha la risposta sepolta in candidates[].content.parts[].text
    private static func estraiTesto(_ dati: [String: Any]) -> String {
        guard let candidati = dati["candidates"] as? [[String: Any]] else { return "" }
        var parti: [String] = []
        for c in candidati {
            guard let contenuto = c["content"] as? [String: Any],
                  let elenco = contenuto["parts"] as? [[String: Any]] else { continue }
            for p in elenco { if let t = p["text"] as? String { parti.append(t) } }
        }
        return parti.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Come dire all'utente di mettere la chiave, senza chiedergliela in chat.
    static func istruzioniChiave() -> String {
        """
        La chiave non me la dare qui: aprila tu con questo comando nel Terminale e incollala nel file che si apre, poi salva.
        Il file resta sul Mac e lo leggo solo io.
        """
    }
}

extension Tools {
    /// `spiegami`: la domanda di studio va dritta al secondo cervello.
    static func spiegamiSkill(_ args: [String: Any]) async -> String {
        let domanda = (args["domanda"] as? String) ?? ""
        let materia = (args["materia"] as? String) ?? ""
        guard !domanda.isEmpty else { return "Dimmi cosa devo spiegarti." }
        if !Gemini.pronto {
            // senza chiave si fa lo stesso, in locale: meglio una risposta cosi' che niente
            let locale = await JarvisCore.shared.rispostaLocale("Spiega a \(Identita.nome), in italiano semplice e corto: \(domanda)")
            return locale + "\n\n(Voce: il secondo cervello non e' attivo perche' manca la chiave in ~/.jarvis/gemini.txt.)"
        }
        let risposta = await Gemini.chiedi(domanda, contesto: materia.isEmpty ? "" : "materia \(materia)")
        return risposta.isEmpty ? "Gemini non ha risposto: riprovo in locale." : risposta
    }

    /// `gemini`: stato della chiave e prova rapida.
    static func geminiSkill(_ azione: String) async -> String {
        switch azione {
        case "stato":
            guard let c = Gemini.configurazione() else {
                return "Chiave Gemini: non messa. " + Gemini.istruzioniChiave()
            }
            return "Chiave Gemini: presente (modello \(c.modello)). \(Marca.nome) la usa solo per spiegare, mai per messaggi, mail o schermate."
        case "apri_file":
            NSWorkspace.shared.open(Gemini.chiaveFile)
            return "Ho aperto il file della chiave: incolla la tua chiave nella prima riga e salva."
        case "prova":
            return await Gemini.chiedi("Rispondi con una sola frase: chi sei?")
        default:
            return "Azioni: stato, apri_file, prova."
        }
    }

    /// `cervello`: dove Jarvis ragiona quando la spina e' staccata, e che passo
    /// tiene l'app in generale. Due file diversi perche' sono due scelte diverse:
    /// `batteria.txt` = gemini/locale (dove pensa), `passo.txt` = dormi/esci/lavora
    /// (quanto gira).
    static func cervelloSkill(_ azione: String) -> String {
        let a = azione.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch a {
        case "stato":
            return CervelloPortatile.stato() + " Passo ora: \(Risparmio.descrizione(Risparmio.modalita)) — "
                + Risparmio.leggi().perche
        case "gemini", "cloud": return CervelloPortatile.imposta("gemini")
        case "locale", "offline", "giu": return CervelloPortatile.imposta("locale")
        case "dormi", "esci", "lavora":
            let esito = Risparmio.imposta(Risparmio.Modo(rawValue: a)!)
            Task { @MainActor in JarvisCore.shared.applicaRisparmio() }
            return esito
        default: return "Azioni: stato, gemini, locale (dove ragiona a batteria); dormi, esci, lavora (quanto gira a batteria). Adesso: " + CervelloPortatile.stato()
        }
    }
}

// MARK: - Gemini che chiama gli strumenti (per lavorare a batteria)

/// A batteria il modello locale costa: 6,6 GB in RAM e secondi di CPU piena.
/// Gemini gira sui server di Google e sul Mac non consuma quasi niente, quindi
/// a corrente staccata il cervello si sposta li' mentre le mani (shell, file,
/// meteo, F1) restano qui. Le regole di privacy valgono lo stesso: niente
/// screenshot, niente contenuti di mail e messaggi, niente percorsi personali.
enum CervelloPortatile {
    static var fileScelta: URL { AppPaths.jarvisRoot.appendingPathComponent("batteria.txt") }

    /// "gemini" (default) o "locale".
    static func scelta() -> String {
        let v = ((try? String(contentsOf: fileScelta, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? "gemini" : v
    }

    /// Vero quando questo deve andare sul cloud. Forzabile per i test con
    /// JARVIS_BATTERIA=1 / =0, perche' qui non posso staccare la spina.
    static func daUsare() -> Bool {
        let forza = forzatoPerTest ?? ambienteForzato
        if let f = forza { return f && scelta() == "gemini" && Gemini.pronto }
        guard !Alimentazione.inCarica else { return false }
        return scelta() == "gemini" && Gemini.pronto
    }

    /// Solo i test la toccano: nell'app reale decide IOKit.
    static var forzatoPerTest: Bool?

    static var ambienteForzato: Bool? {
        switch ProcessInfo.processInfo.environment["JARVIS_BATTERIA"] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    static func imposta(_ nuova: String) -> String {
        let v = nuova.lowercased() == "locale" ? "locale" : "gemini"
        do { try v.write(to: fileScelta, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a scrivere \(fileScelta.path): \(error.localizedDescription)" }
        return v == "gemini"
            ? "A batteria ragiono con Gemini (le mani restano sul Mac, e i contenuti di messaggi, mail e schermo non partono)."
            : "A batteria uso il modello locale: piu' preciso e tutto offline, pero' consuma batteria."
    }

    static func stato() -> String {
        "Alimentazione: \(Alimentazione.descrizione()). Scelta a batteria: \(scelta()). Chiave Gemini: \(Gemini.pronto ? "presente" : "assente"). "
            + (daUsare() ? "In questo momento il cervello e' sul cloud."
                         : "In questo momento il cervello e' locale.")
    }

    /// Una riga sola, da mettere nel prompt di testa.
    static func statoBreve() -> String {
        daUsare() ? "cervello sul cloud (Gemini), strumenti sul Mac"
                  : "cervello locale (\(Brain.modelloSalvato ?? "qwen3")), tutto offline"
    }

    /// Gli strumenti il cui contenuto non deve lasciare il Mac.
    ///
    /// Il 2026-10-30 questa lista era incompleta: mancavano agenda, compiti, orario,
    /// l'archivio `cose`, i file letti e l'output dei comandi. Risultato: i titoli
    /// degli impegni, i voti, gli indirizzi salvati e il contenuto di qualunque file
    /// partivano verso Google come se fossero pubblici.
    static let privatoPerIlCloud: Set<String> = [
        "messaggi", "mail", "whatsapp", "orecchio", "leggi_schermo", "schermo",
        "compiti_da_classeviva", "contatti", "aggiorna_profilo", "leggi_profilo", "cerca_nella_storia",
        "agenda", "compiti", "leggi_orario", "cose", "appunti",
        "leggi_file", "esegui_comando", "sistema", "conversazione"
    ]
}

/// Lo stato dell'alimentazione, letto da IOKit: niente processo figlio, niente shell.
enum Alimentazione {
    /// True se l'alimentatore e' attaccato (o se il Mac non ha batteria).
    ///
    /// `JARVIS_ALIMENTATORE=0` finge il cavo staccato: serve solo a chi prova, perche'
    /// qui nessuno puo' staccare la spina al Mac per vedere cosa fa il piano. Senza la
    /// variabile non cambia niente.
    static var inCarica: Bool {
        switch ProcessInfo.processInfo.environment["JARVIS_ALIMENTATORE"] {
        case "0": return false
        case "1": return true
        default: break
        }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let lista = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !lista.isEmpty else { return true }
        for ps in lista {
            guard let descrizione = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if (descrizione[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue { return true }
        }
        return false
    }

    /// Il Mac e' staccato: chi decide cosa fermare e' `Risparmio.decidi()` (passo.txt),
    /// non una verifica fatta dentro la callback del timer — li' il processo si e' gia'
    /// svegliato, e lo svegliarsi e' esattamente il costo che lui vuole azzerare.

    /// Percento di batteria, letto da IOKit come tutto il resto (nil se il Mac non
    /// ha batteria: un desktop restituisce "nessuna pill", non un finto 100%).
    static func percentuale() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let lista = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in lista {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let attuale = d[kIOPSCurrentCapacityKey] as? Int,
                  let piena = d[kIOPSMaxCapacityKey] as? Int, piena > 0 else { continue }
            return Int((Double(attuale) / Double(piena) * 100).rounded())
        }
        return nil
    }

    static func descrizione() -> String {
        inCarica ? "corrente attaccata" : "a batteria"
    }

    // MARK: - accorgersi del cavo senza timer

    /// `NSWorkspace` su macOS non ha una notifica per l'alimentatore (ha solo «sto
    /// spegnendo»): la sorgente giusta e' questa, la stessa famiglia di chiamate che
    /// usiamo per leggere la carica. Arriva sul run loop principale, quindi non
    /// introduce nessun filo nuovo e nessun risveglio a vuoto.
    private final class Ascoltatore {
        let azione: () -> Void
        init(_ azione: @escaping () -> Void) { self.azione = azione }
    }
    private static var ascoltatori: [Ascoltatore] = []
    private static var sorgenti: [CFRunLoopSource] = []

    /// Chiama `azione` ogni volta che il cavo entra o esce. Il contesto di IOKit e' un
    /// puntatore C e non puo' portarsi dietro una closure: l'ascoltatore resta in una
    /// lista statica, che e' anche il motivo per cui la sorgente non muore subito.
    @discardableResult
    static func osservaCambiCorrente(_ azione: @escaping () -> Void) -> Bool {
        let ascoltatore = Ascoltatore(azione)
        let contesto = Unmanaged.passUnretained(ascoltatore).toOpaque()
        guard let sorgente = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Ascoltatore>.fromOpaque(ctx).takeUnretainedValue().azione()
        }, contesto)?.takeRetainedValue() else { return false }
        ascoltatori.append(ascoltatore)
        sorgenti.append(sorgente)
        CFRunLoopAddSource(CFRunLoopGetMain(), sorgente, .commonModes)
        return true
    }
}

extension Gemini {
    /// Quello che un giro sul cloud ha prodotto, perche' l'Agent lo possa registrare.
    struct EsitoNuvola {
        var testo = ""
        var chiamati: [String] = []
        var ultimoOutput = ""
        /// Testo rimasto qui sul Mac perche' privato: va messo nella risposta finale.
        var contenutoLocale = ""
        /// Falso quando Gemini non ha proprio risposto (no rete, chiave morta).
        var haLavorato = false
        /// Motivo del salto al modello locale, da dire all'utente senza nasconderlo.
        var erroreCloud = ""
    }

    /// Mascera cio' che non deve salire: i percorsi di casa e i contenuti privati.
    static func daMandare(_ nome: String, _ out: String, locale: inout String) -> String {
        let pulito = out.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if CervelloPortatile.privatoPerIlCloud.contains(nome) {
            locale = locale.isEmpty ? pulito : locale + "\n\n" + pulito
            return "[contenuto letto sul Mac e non inviato: \(pulito.count) caratteri]"
        }
        return String(pulito.prefix(4000))
    }

    /// Spedisce lo stesso corpo su piu' modelli finche' uno risponde: Google
    /// risponde 503 ("saturo") e 404 ("non c'e' piu'") senza che la chiave cambi.
    static func invia(con corpo: [String: Any], chiave: String, ordine: [String]) async -> ([String: Any]?, Int, String) {
        guard let data = try? JSONSerialization.data(withJSONObject: corpo) else { return (nil, 0, ordine.first ?? "") }
        var ultimoCodice = 0
        for nome in ordine {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(nome):generateContent") else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(chiave, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = data
            req.timeoutInterval = 40
            var risposta: Data?
            var codice = 0
            do {
                let giro = try await URLSession.shared.data(for: req)
                risposta = giro.0
                codice = (giro.1 as? HTTPURLResponse)?.statusCode ?? 0
            } catch { codice = -1 }
            ultimoCodice = codice
            if codice == 404 || codice == 503 || codice == -1 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            guard codice == 200, let risposta,
                  let dizionario = try? JSONSerialization.jsonObject(with: risposta) as? [String: Any] else {
                return (nil, codice, nome)
            }
            return (dizionario, codice, nome)
        }
        return (nil, ultimoCodice, ordine.last ?? "")
    }

    /// Un giro completo con gli strumenti: Gemini decide, Jarvis esegue in locale.
    static func chiediConStrumenti(storia: [(ruolo: String, testo: String)],
                                   strumenti: [[String: Any]],
                                   sistema: String,
                                   massimoGiri: Int = 5,
                                   suNota: @escaping (String) -> Void = { _ in },
                                   suPasso: @escaping (String, String, Bool) -> Void = { _, _, _ in }) async -> EsitoNuvola {
        var esito = EsitoNuvola()
        guard let (chiave, modello) = configurazione() else {
            esito.testo = "A batteria ho bisogno della chiave Gemini in ~/.jarvis/gemini.txt."
            return esito
        }
        // le nostre definizioni sono gia' in JSON Schema: serve solo togliere "type": "function"
        let dichiarazioni = strumenti.compactMap { $0["function"] as? [String: Any] }.map { f in
            ["name": f["name"] ?? "", "description": f["description"] ?? "", "parameters": f["parameters"] ?? [:]]
        }
        var partiStoria: [[String: Any]] = []
        for giro in storia {
            partiStoria.append(["role": giro.ruolo == "user" ? "user" : "model",
                                "parts": [["text": giro.testo]]])
        }
        // prima il modello che ha funzionato l'ultima volta, poi quello nel file, poi la lista
        var ordine: [String] = []
        if let ricordato = modelloMemorizzato { ordine.append(ricordato) }
        ordine.append(modello)
        for c in candidati where !ordine.contains(c) { ordine.append(c) }

        for _ in 0...massimoGiri {
            var corpo: [String: Any] = [
                "systemInstruction": ["parts": [["text": sistema]]],
                "contents": partiStoria,
                "generationConfig": ["temperature": 0.3, "maxOutputTokens": 1200]
            ]
            if !dichiarazioni.isEmpty {
                corpo["tools"] = [["functionDeclarations": dichiarazioni]]
                corpo["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
            }
            let (dizionario, codice, modelloOk) = await Gemini.invia(con: corpo, chiave: chiave, ordine: ordine)
            guard let dizionario else {
                esito.erroreCloud = codice == -1 ? "Gemini non raggiunge la rete" : "Gemini ha risposto HTTP \(codice)"
                return esito
            }
            if modelloOk != modello { modelloMemorizzato = modelloOk }
            esito.haLavorato = true
            guard let candidati = dizionario["candidates"] as? [[String: Any]],
                  let contenuto = candidati.first?["content"] as? [String: Any],
                  let parti = contenuto["parts"] as? [[String: Any]] else {
                esito.testo = "Gemini ha risposto in una forma che non capisco."
                return esito
            }
            var testo = ""
            var chiamate: [[String: Any]] = []
            for p in parti {
                if let t = p["text"] as? String { testo += t }
                if let f = p["functionCall"] as? [String: Any] { chiamate.append(f) }
            }
            esito.testo = testo
            guard !chiamate.isEmpty else { return esito }

            // la risposta del modello entra nella storia, poi eseguiamo qui e rispondiamo
            var partiModello: [[String: Any]] = []
            if !testo.isEmpty { partiModello.append(["text": testo]) }
            for f in chiamate { partiModello.append(["functionCall": f]) }
            partiStoria.append(["role": "model", "parts": partiModello])

            var risposte: [[String: Any]] = []
            for f in chiamate {
                let nome = (f["name"] as? String) ?? ""
                let argomenti = (f["args"] as? [String: Any]) ?? [:]
                esito.chiamati.append(nome)
                var argomentoJson = ""
                if let d = try? JSONSerialization.data(withJSONObject: argomenti),
                   let s = String(data: d, encoding: .utf8) { argomentoJson = String(s.prefix(90)) }
                suNota("→ \(nome) \(argomentoJson)")
                let passoId = UUID().uuidString
                suPasso(passoId, Agent.etichetta(nome, ""), true)
                let out = await Tools.shared.run(nome, argomenti)
                suPasso(passoId, nome, false)
                // anche qui il canale deve lasciare il segno vero: se lo strumento dice
                // "NON INVIATO", Gemini non puo' rispondere "inviato"
                if ["messaggi", "mail", "whatsapp"].contains(nome) {
                    Agent.esitoCanaleAttuale = out
                    Agent.esitoCanaleFallito = out.uppercased().contains("NON INVIATO")
                }
                if out.count > esito.ultimoOutput.count { esito.ultimoOutput = out }
                let mask = daMandare(nome, out, locale: &esito.contenutoLocale)
                risposte.append(["functionResponse": ["name": nome,
                                                     "response": ["risultato": mask]]])
            }
            partiStoria.append(["role": "user", "parts": risposte])
        }
        return esito
    }
}
