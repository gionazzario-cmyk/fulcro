import Foundation
import AppKit

/// Jarvis e le app del Mac — tutte quante, non solo quelle per cui qualcuno ha
/// scritto un pezzo di codice.
///
/// L'idea: invece di scrivere una skill per ciascuna app (impossibile: sono 150 e
/// l'utente ne installa altre), l'inventario si costruisce da solo leggendo quello
/// che ogni bundle dichiara già nel suo `Info.plist`:
///
/// - gli **schemi URL** (`CFBundleURLTypes`): sono la vera porta d'ingresso. Con
///   `spotify:search:...`, `obsidian://new`, `x-apple.systempreferences:...` ci si
///   arriva dentro senza premere tasti alla cieca;
/// - i **tipi di documento** che apre: così «apri questo file con la app giusta» non
///   è più un'ipotesi;
/// - se **si lascia pilotare** (`NSAppleScriptEnabled`, o una `.sdef` dentro
///   `Contents/Resources`): in quel caso esistono comandi veri, non screenshot;
/// - l'**architettura** del binario (arm64 / Intel / universale): utile per dirgli
///   quali app andranno lente o rotte su Apple Silicon;
/// - l'**ultimo uso**, preso dal registro di Spotlight in un solo colpo per tutte.
///
/// Niente di questo chiede permessi nuovi: legge file già leggibili e chiama `mdls`.
/// L'inventario sta in `~/.jarvis/app/inventario.json`; le note su cosa Jarvis ha
/// imparato di una app stanno in `~/.jarvis/app/schede/<nome>.md`.
struct SchedaApp: Codable {
    var nome: String
    var percorso: String
    var id: String
    var categoria: String
    var versione: String
    var schemi: [String]
    var estensioni: [String]
    var pilotabile: Bool
    var architettura: String
    var ultimoUso: Date?
    /// I verbi che l'app **dichiara da sé** nella sua `.sdef` ("playpause", "make new
    /// document", …). È la differenza tra "si può pilotare" e "so cosa dirle": senza
    /// questi il modello indovina, con questi legge un vocabolario scritto da chi ha
    /// fatto l'app. Opzionale perche' l'inventario vecchio sul disco non ce l'ha.
    var comandiAppleScript: [String]? = nil

    /// "MAI APERTA" o "3 giorni fa": la riga che fa capire all'utente se Jarvis
    /// sta parlando dell'app giusta.
    var usoUmano: String {
        guard let ultimoUso else { return "mai aperta (secondo Spotlight)" }
        let secondi = Date().timeIntervalSince(ultimoUso)
        if secondi < 3600 { return "aperta da poco" }
        let ore = Int(secondi / 3600)
        if ore < 24 { return ore < 2 ? "meno di due ore fa" : "\(ore) ore fa" }
        let giorni = ore / 24
        if giorni < 31 { return "\(giorni) giorni fa" }
        return "\(giorni / 30) mesi fa"
    }
}

enum InventarioApp {
    static var cartella: URL { AppPaths.jarvisRoot.appendingPathComponent("app") }
    static var file: URL { cartella.appendingPathComponent("inventario.json") }
    static var schede: URL { cartella.appendingPathComponent("schede") }

    /// Le cartelle dove macOS tiene le app. `Utilities` sta dentro /Applications,
    /// quindi non serve metterla a parte: viene da sola con la scansione profonda 1.
    static let radici: [String] = [
        "/Applications",
        "/System/Applications",
        FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"
    ]

    // MARK: - categorie in italiano

    /// La categoria in italiano. **Bug trovato la notte del 2026-10-22**: la forma vera
    /// dichiarata da Apple è `public.app-category.<nome>` — il trattino sta DENTRO il nome
    /// (`public.app-category.graphics-design`) — e qui si spezzava su
    /// `"public.app-category-"`, che non compare mai: risultato, **tutte e 168 le app
    /// uscivano "altro"**. Il test non l'ha mai beccato perché passava una forma finta
    /// (`public.app-category-games`), cioè lo stesso errore del codice. I test vanno
    /// scritti con l'input vero, non con l'input che assomiglia al codice.
    static func categoriaUmana(_ grezza: String) -> String {
        let mappa = [
            "games": "giochi", "productivity": "produttività", "utilities": "utilità",
            "utility": "utilità", "developer-tools": "programmazione",
            "graphics-design": "grafica e 3D", "design": "grafica e 3D",
            "video": "video", "music": "musica", "entertainment": "intrattenimento",
            "entertainment-apps": "intrattenimento", "social-networking": "social",
            "social-media": "social", "education": "scuola",
            "kids": "bambini", "finance": "soldi", "lifestyle": "tempo libero",
            "health-fitness": "sport e salute", "news": "notizie", "reference": "referenze",
            "browser": "internet", "business": "lavoro", "travel": "viaggi",
            "photo": "foto", "photography": "foto", "weather": "meteo",
            "navigation": "mappe", "maps": "mappe", "food-recipe": "cucina",
            "food-and-drink": "cucina", "sports": "sport", "shopping": "acquisti",
            "book": "libri", "books": "libri", "reference-books": "libri",
            "stickers": "adesivi", "networking": "rete", "it-services": "servizi"
        ]
        let basso = grezza.lowercased()
        var coda = basso
        var prefissoTolto = false
        for prefisso in ["public.app-category.", "public.app-category-"] where coda.hasPrefix(prefisso) {
            coda = String(coda.dropFirst(prefisso.count))
            prefissoTolto = true
        }
        if let trovata = mappa[coda] { return trovata }
        guard prefissoTolto, !coda.isEmpty else { return "altro" }
        // categoria che Apple ha aggiunto dopo e che non conosciamo: meglio la sua parola
        // letta umana che "altro", che non dice niente
        return coda.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - scansione

    /// Legge i bundle a fondo 1 (e a fondo 2 solo per `Utilities`, dove stanno le
    /// app di sistema più nascoste). Nessun permesso nuovo, nessuna scrittura.
    static func scansiona() -> [SchedaApp] {
        let fm = FileManager.default
        var fuori: [SchedaApp] = []
        for radice in radici {
            let url = URL(fileURLWithPath: radice)
            guard let voci = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for voce in voci {
                if voce.pathExtension == "app" {
                    if let s = leggiBundle(voce) { fuori.append(s) }
                } else if fm.fileExists(atPath: voce.appendingPathComponent("Contents").path) == false
                            && voce.lastPathComponent.lowercased().contains("utilit") {
                    // cartelle tipo /Applications/Utilities: un giro piu' dentro
                    if let seconde = try? fm.contentsOfDirectory(at: voce, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles]) {
                        for seconda in seconde where seconda.pathExtension == "app" {
                            if let s = leggiBundle(seconda) { fuori.append(s) }
                        }
                    }
                }
            }
        }
        return fuori.sorted { $0.nome.lowercased() < $1.nome.lowercased() }
    }

    static func leggiBundle(_ url: URL) -> SchedaApp? {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { return nil }
        let nome = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let id = (info["CFBundleIdentifier"] as? String) ?? ""
        if id.isEmpty { return nil }

        var schemi: [String] = []
        for tipo in (info["CFBundleURLTypes"] as? [[String: Any]]) ?? [] {
            for s in (tipo["CFBundleURLSchemes"] as? [String]) ?? [] where !s.isEmpty {
                if !schemi.contains(s) { schemi.append(s) }
            }
        }

        var estensioni: [String] = []
        for tipo in (info["CFBundleDocumentTypes"] as? [[String: Any]]) ?? [] {
            for e in (tipo["CFBundleTypeExtensions"] as? [String]) ?? [] {
                let pulita = e.lowercased().replacingOccurrences(of: ".", with: "")
                if !pulita.isEmpty, pulita != "*", !estensioni.contains(pulita) { estensioni.append(pulita) }
            }
        }

        let abilitataAppleScript = (info["NSAppleScriptEnabled"] as? Bool ?? false)
            || (info["AppleScriptEnabled"] as? Bool ?? false)
            || (info["OSAScriptingDefinition"] != nil)
        let risorse = (try? FileManager.default.contentsOfDirectory(
            at: url.appendingPathComponent("Contents/Resources"), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        let sdefFile = risorse.first { $0.pathExtension.lowercased() == "sdef" }
        let sdef = sdefFile != nil

        return SchedaApp(
            nome: nome,
            percorso: url.path,
            id: id,
            categoria: categoriaUmana((info["LSApplicationCategoryType"] as? String) ?? ""),
            versione: (info["CFBundleShortVersionString"] as? String) ?? "?",
            schemi: Array(schemi.prefix(8)),
            estensioni: estensioniPerLaScheda(estensioni),
            pilotabile: abilitataAppleScript || sdef,
            architettura: architettura(bundle.executableURL),
            ultimoUso: nil,
            comandiAppleScript: sdefFile.map { verbiDaSdef($0) }
        )
    }

    /// Le estensioni "vere" prima di quelle numeriche: Keka dichiara `.001` … `.014`
    /// (archivi spezzati) e con l'ordine alfabetico puro quelle prendevano il posto di
    /// zip/7z/rar nella scheda e nel ponte — visto sul ponte di Keka alle 23:31.
    static func estensioniPerLaScheda(_ estensioni: [String]) -> [String] {
        Array(estensioni.sorted { a, b in
            let aNumerica = !a.isEmpty && a.allSatisfy(\.isNumber)
            let bNumerica = !b.isEmpty && b.allSatisfy(\.isNumber)
            if aNumerica != bNumerica { return !aNumerica }
            return a < b
        }.prefix(24))
    }

    /// Legge il vocabolario AppleScript dell'app: solo l'inizio del file (una `.sdef`
    /// di iTunes arriva a 300 KB e non serve leggerla tutta per contare i verbi) e
    /// solo i primi `massimo` comandi, perche' finiscono nel prompt di testa.
    static func verbiDaSdef(_ file: URL, massimo: Int = 14) -> [String] {
        guard let fh = try? FileHandle(forReadingFrom: file),
              let testa = try? fh.read(upToCount: 262_144),
              let xml = String(data: testa, encoding: .utf8) else { return [] }
        return comandi(xml, "command", "name").prefix(massimo).map { $0 }
    }

    /// arm64 / Intel / universale, letto dalla testa del binario (Mach-O).
    /// Serve perche' su Apple Silicon un'app solo Intel gira con Rosetta: piu' lenta,
    /// e a volte rotta — e l'utente deve saperlo prima di arrabbiarsi con il Mac.
    static func architettura(_ exec: URL?) -> String {
        guard let exec, let fh = try? FileHandle(forReadingFrom: exec),
              let testa = try? fh.read(upToCount: 4096), testa.count >= 8 else { return "?" }
        func u32(_ data: Data, _ off: Int, bigEndian: Bool) -> UInt32 {
            let r = data.startIndex + off
            guard r + 3 < data.endIndex else { return 0 }
            let b = [data[r], data[r + 1], data[r + 2], data[r + 3]]
            let v = bigEndian
                ? (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
                : (UInt32(b[3]) << 24) | (UInt32(b[2]) << 16) | (UInt32(b[1]) << 8) | UInt32(b[0])
            return v
        }
        let magic = u32(testa, 0, bigEndian: true)
        let ARM64: UInt32 = 0x0100000C, X86_64: UInt32 = 0x01000007, I386: UInt32 = 7, PPC: UInt32 = 18
        var tipi: Set<UInt32> = []
        if magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            let numero = Int(u32(testa, 4, bigEndian: true))
            for i in 0..<min(numero, 20) {
                let off = 8 + i * 20
                guard off + 4 <= testa.count else { break }
                tipi.insert(u32(testa, off, bigEndian: true))
            }
        } else {
            let magicoPiccolo = u32(testa, 0, bigEndian: false)
            if magicoPiccolo == 0xFEEDFACF || magicoPiccolo == 0xFEEDFACE {
                tipi.insert(u32(testa, 4, bigEndian: false))
            } else {
                return "?"
            }
        }
        let silicio = tipi.contains(ARM64)
        let intel = tipi.contains(X86_64) || tipi.contains(I386) || tipi.contains(PPC)
        if silicio && intel { return "Apple Silicon + Intel" }
        if silicio { return "Apple Silicon" }
        if intel { return "Intel (gira con Rosetta)" }
        return "sconosciuta"
    }

    // MARK: - ultime aperture (un solo `mdls` per tutte: 150 subprocess would be slow)

    static func riempiaUltimoUso(_ app: [SchedaApp]) async -> [SchedaApp] {
        guard !app.isEmpty else { return app }
        let percorsi = app.map(\.percorso)
        let outo = await Shell.run("/usr/bin/mdls",
                                   ["-name", "kMDItemLastUsedDate"] + percorsi, timeout: 25)
        let righe = outo.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var conDate = app
        if righe.count != app.count {
            // Output inatteso (mdls saltato o Spotlight spento): meglio dire "non lo so"
            // che mettere date sbagliate: lui si fiderebbe.
            return app
        }
        for (i, riga) in righe.enumerated() {
            let pezzo = riga.components(separatedBy: "=").dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
            if pezzo != "(null)", let d = f.date(from: pezzo) { conDate[i].ultimoUso = d }
        }
        return conDate
    }

    // MARK: - archivio su disco

    static func salva(_ app: [SchedaApp]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cartella, withIntermediateDirectories: true)
        try? fm.createDirectory(at: schede, withIntermediateDirectories: true)
        if let dati = try? JSONEncoder().encode(app) { try? dati.write(to: file) }
    }

    static func caricato() -> [SchedaApp]? {
        guard let dati = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode([SchedaApp].self, from: dati)
    }

    /// O riusa l'inventario salvato, o lo fa nuovo se non c'e'. `forza` = dopo una
    /// installazione nuova.
    static func corrente(forza: Bool = false) async -> [SchedaApp] {
        if !forza, let vec = caricato() { return vec }
        let fresco = await riempiaUltimoUso(scansiona())
        salva(fresco)
        return fresco
    }

    static func quandoScansione() -> String {
        guard let attributi = try? FileManager.default.attributesOfItem(atPath: file.path),
              let data = attributi[.modificationDate] as? Date else { return "mai fatta" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMMM 'alle' HH:mm"
        return f.string(from: data)
    }

    // MARK: - trovare l'app giusta

    /// Il nome che una app mette a schermo non e' unico: i due CyberBrick di Bambu si
    /// chiamano entrambi "CyberBrick" e si distinguono solo dalla cartella
    /// (`CyberBrick.app` e `CyberBrick 2.app`). `risolvi` dice quale dei tre casi e',
    /// cosi' Jarvis chiede invece di aprirne uno a caso.
    static func nomeCartella(_ s: SchedaApp) -> String {
        URL(fileURLWithPath: s.percorso).deletingPathExtension().lastPathComponent
    }

    static func risolvi(_ testo: String, in app: [SchedaApp]) -> (una: SchedaApp?, troppe: [SchedaApp]) {
        let pulito = senzaAccenti(testo).replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if pulito.isEmpty { return (nil, []) }
        // Il nome a schermo NON e' il nome della cartella, e sul suo Mac i due modi di
        // chiamare una app si incrociano davvero: `ChatGPT Classic.app` si presenta come
        // "ChatGPT", e `ChatGPT (Classic).app` si presenta come "ChatGPT Classic".
        // Chi dice "ChatGPT Classic" puo' volere l'una o l'altra: non si prende la prima
        // che capita, si chiede.
        // L'id del bundle e' l'unico nome sicuro, e `chiediQuale` lo propone: se non
        // venisse accettato, la frase sarebbe una bugia.
        let perId = app.filter { $0.id.lowercased() == pulito }
        if perId.count == 1 { return (perId[0], []) }
        let perNome = app.filter { senzaAccenti($0.nome) == pulito }
        let perCartella = app.filter { senzaAccenti(nomeCartella($0)) == pulito }
        var candidati: [SchedaApp] = []
        for c in perId + perNome + perCartella where !candidati.contains(where: { $0.id == c.id }) {
            candidati.append(c)
        }
        if candidati.count == 1 { return (candidati[0], []) }
        if candidati.count > 1 { return (nil, candidati) }
        if let una = trova(testo, in: app) { return (una, []) }
        return (nil, [])
    }

    /// La frase da dire quando un nome puo' indicare piu' d'un'app.
    static func chiediQuale(_ liste: [SchedaApp]) -> String {
        let righe = liste.map { "  • «\($0.nome)» — \(nomeCartella($0)).app (id \($0.id))" }
        return "Più d'un'app corrisponde a quel nome e non indovino: quale delle due?\n" + righe.joined(separator: "\n")
            + "\nRichiama con il nome della cartella o con l'id, che e' unico."
    }

    /// "blender", "Blender.app", "capcut", "anticravity" -> la scheda vera.
    /// Match in tre passi: esatto, inizio del nome,substring + distanza minima.
    static func trova(_ testo: String, in app: [SchedaApp]) -> SchedaApp? {
        let pulito = senzaAccenti(testo).replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if pulito.isEmpty { return nil }
        let nomi = app.map { (senzaAccenti($0.nome).replacingOccurrences(of: ".app", with: "", options: .caseInsensitive), $0) }
        if let esatto = nomi.first(where: { $0.0 == pulito }) { return esatto.1 }
        if let inizio = nomi.first(where: { $0.0.hasPrefix(pulito) || pulito.hasPrefix($0.0) }) { return inizio.1 }
        if let dentro = nomi.filter({ $0.0.contains(pulito) || pulito.contains($0.0) }).first { return dentro.1 }
        // una svista di battitura: "corsOver" deve comunque trovare "CrossOver"
        if pulito.count >= 5 {
            let simile = nomi.min { distanza($0.0, pulito) < distanza($1.0, pulito) }
            if let s = simile, distanza(s.0, pulito) <= 2 { return s.1 }
        }
        return nil
    }

    static func senzaAccenti(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    /// Leveinstein limitato (sotto 20 caratteri per riga: le liste di app sono corte).
    static func distanza(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if a.count > 24 || b.count > 24 { return 99 }
        var mat = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { mat[i][0] = i }
        for j in 0...b.count { mat[0][j] = j }
        let ca = Array(a), cb = Array(b)
        for i in 1...a.count {
            for j in 1...b.count {
                let costo = ca[i - 1] == cb[j - 1] ? 0 : 1
                mat[i][j] = min(mat[i - 1][j] + 1, mat[i][j - 1] + 1, mat[i - 1][j - 1] + costo)
            }
        }
        return mat[a.count][b.count]
    }

    // MARK: - novita'

    /// Le app installate dopo l'ultimo inventario: il confronto e' sul bundle id,
    /// perche' i nomi si somigliano ("ChatGPT Classic" e "ChatGPT (Classic)").
    static func nuove() -> [String] {
        guard let vecchio = caricato() else { return [] }
        let conosciute = Set(vecchio.map(\.id))
        return scansiona().filter { !conosciute.contains($0.id) }.map(\.nome).sorted()
    }

    /// La scheda dell'app citata nella domanda, in forma corta, da mettere nel prompt
    /// di testa. Niente di lungo: qwen3 legge poche righe e poi risponde.
    static func notaSullaDomanda(_ domanda: String, in lista: [SchedaApp]? = nil) -> String {
        guard let inventario = lista ?? caricato(), !inventario.isEmpty else { return "" }
        // La nota vale per le DOMANDE ("cosa sai di Blender?"). Se invece lui sta
        // ordinando un'azione, dirle "non chiamare lo strumento" e un autogol: successo
        // con "apri Bluetooth File Exchange", in cui il modello, intima di non chiamare
        // `app`, ne ha chiamato un altro a caso.
        let ordini = ["apri", "aprimi", "avvia", "lancia", "chiudi", "spegni", "metti", "sali",
                      "fammi vedere", "mostrami", "vai su", "sull'app"]
        let basso = domanda.lowercased()
        if ordini.contains(where: { basso.contains($0) }) { return "" }
        let testo = senzaAccenti(domanda)
        var trovate: [SchedaApp] = []
        for s in inventario {
            let nome = senzaAccenti(s.nome)
            guard nome.count >= 4, !nome.hasPrefix("prova-") else { continue }
            if testo.contains(nome), !trovate.contains(where: { $0.id == s.id }) {
                trovate.append(s)
            }
            if trovate.count == 2 { break }
        }
        guard !trovate.isEmpty else { return "" }
        var fuori = "APP NOMINATE NELLA DOMANDA (dati veri letti dal loro bundle, non a memoria):\n"
            + trovate.map { sintesi($0) }.joined(separator: "\n")
        // il ponte, se esiste: e' li' che sta "come si pilota davvero", e portarlo gia'
        // letto evita il giro in cui il modello chiede la scheda per forza
        for s in trovate {
            let ponte = Integrazione.sintesiPerIlPrompt(s)
            if !ponte.isEmpty { fuori += "\n" + ponte }
        }
        return fuori
            + "\nQuesti dati li hai gia' letti: non serve richiamo `apri_app` per contarli. Rispondi "
            + "dicendo cosa PUOI FARE TU con questa app (aprire, chiudere, andare a un punto "
            + "preciso con lo schema URL, pilotarla con i comandi, che file le dai da aprire)."
    }

    static func sintesi(_ s: SchedaApp) -> String {
        var riga = "  • \(s.nome) [\(s.categoria)] · \(s.architettura) · ultimo uso: \(s.usoUmano)"
        let verbi = s.comandiAppleScript ?? []
        if !verbi.isEmpty {
            // il vocabolario vero, non "prova a pilotarla": e' quello che rende Jarvis
            // compatibile con le app senza che nessuno scrivano un ponte per una
            riga += " · comandi AppleScript suoi: " + verbi.joined(separator: ", ")
        } else if s.pilotabile {
            riga += " · si pilota con comandi AppleScript (vedi `app azione=script`)"
        }
        if !s.schemi.isEmpty { riga += " · schemi URL: " + s.schemi.prefix(3).joined(separator: ", ") }
        if !s.estensioni.isEmpty { riga += " · apre file: " + s.estensioni.prefix(6).joined(separator: ", ") }
        return riga
    }

    /// Righe di stato per la riga in alto e per il prompt: poche, vere.
    static func riepilogo(_ app: [SchedaApp]) -> String {
        let pilotabili = app.filter(\.pilotabile).count
        let conSchema = app.filter { !$0.schemi.isEmpty }.count
        return "\(app.count) app nell'inventario (scansione \(quandoScansione())): "
            + "\(pilotabili) si possono pilotare con comandi veri, \(conSchema) hanno uno schema URL "
            + "per arrivarci dentro"
    }
}

// MARK: - lo strumento che vede il modello

extension Tools {
    @MainActor static func appSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in ((args[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        // Il modello, chiesto di UNA app, a volte risponde con `stato` o `lista` e mette
        // il nome negli altri campi: invece di girare a vuoto gli do la scheda di quella
        // app, che e' quello che voleva.
        // `apri_app` e' la bocca vecchia: se la chiama senza dire cosa fare, vuole aprire
        let azioni = a("azione").isEmpty ? "apri" : a("azione").lowercased()
        let azioniDaScheda = ["stato", "lista", "recenti", "intel"]
        if !a("nome").isEmpty, azioniDaScheda.contains(azioni) {
            var scheda = args
            scheda["azione"] = "scheda"
            return await Tools.appSkill(scheda)
        }
        switch azioni {
        case "stato":
            let inventario = await InventarioApp.corrente()
            let n = InventarioApp.nuove()
            var out = InventarioApp.riepilogo(inventario)
            if !n.isEmpty { out += "\nNovità dall'ultima scansione: " + n.joined(separator: ", ") }
            return out

        case "lista":
            let inventario = await InventarioApp.corrente()
            let filtro = InventarioApp.senzaAccenti(a("testo"))
            let categoria = InventarioApp.senzaAccenti(a("categoria"))
            var scelte = inventario
            if !filtro.isEmpty { scelte = scelte.filter { InventarioApp.senzaAccenti($0.nome).contains(filtro) } }
            if !categoria.isEmpty { scelte = scelte.filter { InventarioApp.senzaAccenti($0.categoria).contains(categoria) } }
            if !a("solo").isEmpty {
                let voluti = a("solo").lowercased()
                if voluti.contains("pilot") { scelte = scelte.filter(\.pilotabile) }
                if voluti.contains("schema") { scelte = scelte.filter { !$0.schemi.isEmpty } }
                if voluti.contains("intel") { scelte = scelte.filter { $0.architettura.contains("Intel") } }
            }
            guard !scelte.isEmpty else { return "Nessun'app con quel filtro." }
            let gruppi = Dictionary(grouping: scelte, by: \.categoria)
            var righe: [String] = []
            for (cat, lista) in gruppi.sorted(by: { $0.key < $1.key }) {
                righe.append(cat + ": " + lista.map(\.nome).sorted().joined(separator: ", "))
            }
            return "\(scelte.count) app\n" + righe.joined(separator: "\n")

        case "scheda":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non ho nell'inventario un'app che somigli a «\(a("nome"))». Con `lista` vedi come si chiamano davvero."
            }
            var fuori = "[\(s.categoria)] \(s.nome) — \(s.id) · versione \(s.versione) · \(s.architettura) · ultimo uso: \(s.usoUmano)\n"
            fuori += "percorso: \(s.percorso)\n"
            fuori += "cosa posso fare con questa app:\n"
            fuori += "  • apri / chiudi / metti davanti: `app azione=apri nome=\(s.nome)` (e chiudi, davanti)\n"
            if !s.schemi.isEmpty {
                fuori += "  • saltare dentro con uno schema URL (`azione=vai`): " + s.schemi.joined(separator: ", ") + "\n"
            }
            if let verbi = s.comandiAppleScript, !verbi.isEmpty {
                fuori += "  • comandi che l'app dichiara da sé (dalla sua `.sdef`): " + verbi.joined(separator: ", ") + "\n"
                fuori += "    sono verbi suoi, non ipotesi: usali cosi' con `app azione=script`\n"
            } else if s.pilotabile {
                fuori += "  • pilotarla con comandi AppleScript veri: i comandi disponibili si leggono dalla sua `.sdef` (chiedi `script`)\n"
            }
            if !s.estensioni.isEmpty {
                fuori += "  • file che apre di solito: " + s.estensioni.prefix(14).joined(separator: ", ") + "\n"
            }
            if let nota = InventarioApp.nota(s.nome), !nota.isEmpty {
                fuori += "  • cosa so già da quando la abbiamo usata:\n" + nota
            }
            fuori += Integrazione.esiste(s.nome)
                ? "  • il ponte c'e': \(Integrazione.filePer(s.nome).path) (rifarlo: `app azione=integra nome=\(s.nome)`)\n"
                : "  • ponte non ancora costruito: `app azione=integra nome=\(s.nome)` — lo fa da sé quando installi una app nuova\n"
            return fuori

        case "apri":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))». Se l'hai appena installata di' `app azione=aggiorna`."
            }
            return await Silenzio.apriSenzaMostrare(percorso: s.percorso, id: s.id, nome: s.nome)

        case "chiudi":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))»."
            }
            let nome = URL(fileURLWithPath: s.percorso).deletingPathExtension().lastPathComponent
            let outo = await Shell.run("/usr/bin/osascript", ["-e", "tell application \"\(nome)\" to quit"], timeout: 20)
            return outo.hasPrefix("Il comando e' finito male") || outo.lowercased().contains("error")
                ? "\(s.nome) non si lascia chiudere così: o ha finestre da salvare o non accetta `quit`. Chiudila tu dalla barra."
                : "Chiusa: \(s.nome)."

        case "davanti":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))»."
            }
            if let processo = NSWorkspace.shared.runningApplications.first(where: {
                    ($0.bundleIdentifier ?? "").lowercased() == s.id.lowercased() }) {
                processo.unhide()
                processo.activate(options: [.activateIgnoringOtherApps])
                return "\(s.nome) in vista, portata davanti."
            }
            _ = await Shell.run("/usr/bin/open", [s.percorso], timeout: 20)
            return "\(s.nome) aperta e portata davanti."

        case "vai":
            // Solo schemi che QUELLA app dichiara: cosi' `vai` non puo' diventare un
            // buco per aprire indirizzi a caso.
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))»."
            }
            guard !s.schemi.isEmpty else {
                return "\(s.nome) non dichiara schemi URL: per arrivarci dentro devo usare tasti e schermo (`leggi_schermo`)."
            }
            let coda = a("dentro")
            guard let scelta = s.schemi.first(where: { coda.lowercased().hasPrefix($0.lowercased() + ":") }) ?? s.schemi.first else {
                return "Niente schemi per \(s.nome)."
            }
            let indirizzo = coda.isEmpty ? "\(scelta):" : (coda.lowercased().hasPrefix(scelta.lowercased() + ":")
                ? coda : "\(scelta):\(coda)")
            // uno schema URL di solito porta la app in primo piano: si segna chi c'era
            // davanti e si rimette a posto dopo
            let prima = Silenzio.frontale()
            let outo = await Shell.run("/usr/bin/open", ["-g", indirizzo], timeout: 20)
            Silenzio.rimettiAPosto(davanti: prima)
            return outo.isEmpty
                ? "Andato a \(indirizzo) in \(s.nome) senza portartela davanti: lo schermo resta il tuo."
                : outo

        case "script":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))»."
            }
            let risorse = URL(fileURLWithPath: s.percorso).appendingPathComponent("Contents/Resources")
            guard let file = try? FileManager.default.contentsOfDirectory(at: risorse, includingPropertiesForKeys: nil),
                  let sdef = file.first(where: { $0.pathExtension.lowercased() == "sdef" }) else {
                return "\(s.nome) non ha una `.sdef`: non si pilota con comandi veri, solo con tasti e schermo."
            }
            guard let testo = try? String(contentsOf: sdef, encoding: .utf8) else {
                return "La `.sdef` di \(s.nome) non si legge (\(sdef.lastPathComponent))."
            }
            let comandi = InventarioApp.comandiDaSdef(testo)
            return "\(s.nome) si pilota. Comandi e parametri disponibili (da \(sdef.lastPathComponent)):\n" + comandi
                + "\nPer eseguirli: `esegui_comando` con osascript (chiede il tuo clic, come sempre)."

        case "nota":
            // nello schema ho dichiarato `testo_nota`, ma il modello scrive quasi sempre
            // `testo`: prendo quello che c'e' tra i due, cosi' non risponde a vuoto.
            let scritto = a("testo_nota").isEmpty ? a("testo") : a("testo_nota")
            guard !a("nome").isEmpty, !scritto.isEmpty else {
                return "Per `nota` servono `nome=` e il testo da ricordare (`testo_nota=`)."
            }
            return Tools.scriviNotaPerApp(nome: a("nome"), testo: scritto)

        case "recenti":
            let inventario = await InventarioApp.corrente()
            let vive = Set(NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier }.map { $0.lowercased() })
            let ordinate = inventario.filter { $0.ultimoUso != nil }.sorted { ($0.ultimoUso ?? .distantPast) > ($1.ultimoUso ?? .distantPast) }
            var righe: [String] = []
            let quante = Int(String(a("quante").filter { $0.isNumber })) ?? 12
            for s in ordinate.prefix(max(1, min(quante, 30))) {
                righe.append((vive.contains(s.id.lowercased()) ? "▸ " : "  ") + s.nome + " — " + s.usoUmano)
            }
            return righe.isEmpty ? "Spotlight non ha date di uso per le app nell'inventario."
                : "Le piu' usate di recente (▸ = aperta adesso):\n" + righe.joined(separator: "\n")

        case "intel":
            let inventario = await InventarioApp.corrente()
            let vecchie = inventario.filter { $0.architettura.contains("Intel") && !$0.architettura.contains("Silicio") }
            guard !vecchie.isEmpty else { return "Tutte le app che ho controllato girano native su Apple Silicon." }
            return "\(vecchie.count) app girano con Rosetta (piu' lente, a volte rotte):\n"
                + vecchie.map { "  \($0.nome) — \($0.usoUmano)" }.joined(separator: "\n")

        case "ripulisci", "chiudi-aperte":
            return await Silenzio.chiudiAperte(soloMezzo: false)

        case "visibilita":
            // la sua regola, cambiabile a voce senza toccare file
            let scelta = a("testo")
            if scelta.isEmpty {
                return Silenzio.vuoleVedereLeApp()
                    ? "Adesso le app che apro te le mostro (in ~/.jarvis/schermo.txt c'e' `visibile`)."
                    : "Adesso apro le app in background e ti do solo il resoconto: e' cosi' che le vuoi. "
                        + "Se le vuoi vedere dimmi «mostrami le app quando le apri»."
            }
            return Silenzio.cambiaVisibilita(scelta)

        case "aggiorna":
            let prima = Set(caricato_orId())
            let fresco = await InventarioApp.riempiaUltimoUso(InventarioApp.scansiona())
            InventarioApp.salva(fresco)
            let nUove = fresco.filter { !prima.contains($0.id) }.map(\.nome)
            var fuori = "Inventario aggiornato: \(fresco.count) app."
            if !nUove.isEmpty { fuori += "\nNuove da quando avevo guardato l'ultima volta: " + nUove.joined(separator: ", ") }
            return fuori

        case "integra", "ponte":
            let inventario = await InventarioApp.corrente()
            let scelto = InventarioApp.risolvi(a("nome"), in: inventario)
            if !scelto.troppe.isEmpty { return InventarioApp.chiediQuale(scelto.troppe) }
            guard let s = scelto.una else {
                return "Non la trovo nell'inventario: «\(a("nome"))». Se l'hai appena installata di' `app azione=aggiorna`."
            }
            return await Integrazione.integra(s)

        case "integrazioni", "ponti":
            let inventario = await InventarioApp.corrente()
            let vive = Set(inventario.map { InventarioApp.senzaAccenti($0.nome) })
            let cartella = Integrazione.cartella
            let file = ((try? FileManager.default.contentsOfDirectory(atPath: cartella.path)) ?? [])
                .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
            guard !file.isEmpty else {
                return "Nessun ponte costruito ancora. Se ne installi una nuova lo faccio da me al prossimo giro "
                    + "(solo con il cavo attaccato), oppure: `app azione=integra nome=Keka`."
            }
            // i ponti non si cancellano da soli quando una app sparisce: sono conoscenza
            // accumulata (le Ricette provate), e se lui reinstalla la app quella resta. Ma
            // vanno detti, altrimenti l'elenco mente su cosa c'e' davvero sul Mac.
            // il nome bello, non lo "slug" del file: due app possono avere lo stesso slug
            // (ChatGPT e ChatGPT Classic), e `uniqueKeysWithValues` ci schianta sopra
            let bei = Dictionary(inventario.map { (InventarioApp.senzaAccenti($0.nome), $0.nome) },
                                uniquingKeysWith: { primo, _ in primo })
            let fuori = file.map { slug -> String in
                let nome = bei[slug] ?? slug
                return nome + (vive.contains(slug) ? "" : " (app non più presente: la scheda resta per quando torna)")
            }
            return "\(file.count) ponti in ~/.jarvis/app/integrazioni: " + fuori.joined(separator: ", ")

        default:
            return "Azioni: stato, lista (testo=), scheda, apri, chiudi, davanti, vai (dentro=), script, nota, recenti, intel, visibilita (testo=visibile|invisibile), aggiorna, integra (nome=), integrazioni."
        }
    }

    private static func caricato_orId() -> Set<String> {
        Set(InventarioApp.caricato()?.map(\.id) ?? [])
    }

    private static func scriviNotaPerApp(nome: String, testo: String) -> String {
        let f = InventarioApp.schede.appendingPathComponent(InventarioApp.senzaAccenti(nome) + ".md")
        try? FileManager.default.createDirectory(at: InventarioApp.schede, withIntermediateDirectories: true)
        let vecchio = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        let riga = "- \(testo)\n"
        if vecchio.contains(riga.trimmingCharacters(in: .whitespaces)) { return "Già scritto, non l'ho ripetuto." }
        try? (vecchio + "# \(nome)\n" + riga).write(to: f, atomically: true, encoding: .utf8)
        return "Segnato per \(nome): \(testo)"
    }
}

extension InventarioApp {
    /// Estrae da una `.sdef` i verbi e gli oggetti: la lista che fa dire a Jarvis
    /// "con questa app posso davvero fare X" invece di premere tasti a caso.
    static func comandiDaSdef(_ xml: String) -> String {
        let verbi = comandi(xml, "command", "name")
        let oggetti = comandi(xml, "class", "name")
        var fuori = ""
        if !verbi.isEmpty { fuori += "    comandi: " + verbi.prefix(24).joined(separator: ", ") + "\n" }
        if !oggetti.isEmpty { fuori += "    oggetti: " + oggetti.prefix(18).joined(separator: ", ") + "\n" }
        return fuori.isEmpty ? "    (la .sdef non elenca niente di leggibile)\n" : fuori
    }

    private static func comandi(_ testo: String, _ tag: String, _ attributo: String) -> [String] {
        var fuori: [String] = []
        let pattern = "<" + tag + "[^>]*" + attributo + "=\"([^\"]+)\""
        guard let r = try? NSRegularExpression(pattern: pattern) else { return [] }
        let intervallo = NSRange(testo.startIndex..<testo.endIndex, in: testo)
        for m in r.matches(in: testo, range: intervallo) {
            guard m.numberOfRanges > 1, let rango = Range(m.range(at: 1), in: testo) else { continue }
            let nome = String(testo[rango])
            if !fuori.contains(nome) { fuori.append(nome) }
        }
        return fuori
    }

    /// La nota imparata per un'app, se c'e'.
    static func nota(_ nome: String) -> String? {
        let f = schede.appendingPathComponent(senzaAccenti(nome) + ".md")
        guard let testo = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        let righe = testo.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        return righe.isEmpty ? nil : righe.prefix(8).joined(separator: "\n")
    }
}

extension InventarioApp {
    /// Si accorge da solo delle app cambiate di recente: installazioni, disinstallazioni,
    /// e aggiorna l'inventario. Viene chiamato dal timer di JarvisCore quando il Mac
    /// e' all'alimentatore (leggere 150 Info.plist non e' gratis).
    /// Ritorna una frase solo se c'e' qualcosa da dire: il silenzio quando non e'
    /// successo niente e` il comportamento giusto.
    /// Racconta cosa è cambiato **e restituisce le app nuove**: chi le vede deve anche
    /// poterci costruire il ponte (`Integrazione`), e rifarle il giro per cercarle
    /// costerebbe una seconda scansione di 167 bundle.
    static func vigila() async -> (annuncio: String?, nuove: [SchedaApp]) {
        let adesso = scansiona()
        guard let vecchio = caricato() else {
            let pieno = await riempiaUltimoUso(adesso)
            salva(pieno)
            return ("Inventario delle app costruito: \(pieno.count) app.", [])
        }
        let prima = Set(vecchio.map(\.id)), ora = Set(adesso.map(\.id))
        let aggiunte = adesso.filter { !prima.contains($0.id) }
        let tolte = vecchio.filter { !ora.contains($0.id) }.map(\.nome).sorted()
        guard !aggiunte.isEmpty || !tolte.isEmpty else { return (nil, []) }
        let pieno = await riempiaUltimoUso(adesso)
        salva(pieno)
        var parti: [String] = []
        let nomi = aggiunte.map(\.nome).sorted()
        if !nomi.isEmpty { parti.append("nuove: " + nomi.joined(separator: ", ")) }
        if !tolte.isEmpty { parti.append("non ci sono piu': " + tolte.joined(separator: ", ")) }
        let annuncio = "Ho ricontato le app (\(pieno.count) in tutto) -> " + parti.joined(separator: "; ")
        // le nuove ordinate per nome: se sono piu' di quelle che si fanno in un giro,
        // la coda deve essere sempre la stessa e non ricominciare da capo ogni volta
        return (annuncio, aggiunte.sorted { $0.nome < $1.nome })
    }
}


/// Il test che ha chiesto l'utente: UNA prova per ogni app, non un campione.
/// Nessuna app viene aperta o chiusa — qui si verifica che Jarvis sappia davvero
/// raggiungere ciascuna, e il modo per dirlo senza toccarla e' LaunchServices:
/// se il numero di bundle torna allo stesso percorso, `apri` la trovera'.
enum ProveApp {
    @MainActor static func tutto() async -> String {
        setbuf(stdout, nil)
        AppPaths.prepare()
        let inventario = await InventarioApp.corrente()
        var promosse = 0
        var collisioni: [String] = []
        var nonRegistrata: [String] = []
        var senzaEseguibile: [String] = []
        var architetturaSconosciuta: [String] = []
        var schedeVuote: [String] = []
        var stesseNome: [String] = []
        print("== PROVA DI OGNI APP (\(inventario.count) app, nessuna aperta) ==\n")
        for s in inventario {
            var difetti: [String] = []

            // 1) il nome che Jarvis legge nella frase deve risolvere a LEI.
            //    Se due app hanno lo stesso nome a schermo la risposta giusta E'
            //    "quale delle due?": non un difetto, ma un caso da elencare a parte.
            let risposta = await Tools.appSkill(["azione": "scheda", "nome": s.nome])
            if risposta.contains("non indovino: quale delle due") {
                stesseNome.append(s.nome)
            } else if !risposta.contains(s.percorso) {
                if risposta.contains("Non ho nell'inventario") { difetti.append("non trovata per nome") }
                else { collisioni.append(s.nome) }
            }
            let resolves = InventarioApp.risolvi(s.nome, in: inventario)
            if let altra = resolves.una, altra.id != s.id {
                // due app con LO STESSO nome a schermo non sono un errore di ricerca:
                // e' il Mac che le chiama uguali, e Jarvis prende quella con la
                // cartella che combacia. Segnalate a parte.
                if InventarioApp.senzaAccenti(altra.nome) == InventarioApp.senzaAccenti(s.nome) {
                    stesseNome.append("\(s.nome) -> \(URL(fileURLWithPath: altra.percorso).deletingPathExtension().lastPathComponent)")
                } else {
                    difetti.append("`risolvi` porta ad «\(altra.nome)»")
                }
            }

            // 2) LaunchServices la conosce per numero di bundle? `apri` di Jarvis passa
            // dal PERCORSO, quindi una app non registrata si apre comunque: qui serve
            // per dirgli la verita' ("esiste sul disco ma il Mac non la cerca per id",
            // che e' il caso di News: tolta/disabilitata, e `open -b` la fallisce).
            let dove = try? NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.id)
            if dove == nil { nonRegistrata.append(s.nome) }

            // 3) il binario c'e' ed e' eseguibile
            if let bundle = Bundle(url: URL(fileURLWithPath: s.percorso)), let exe = bundle.executableURL {
                if !FileManager.default.isExecutableFile(atPath: exe.path) {
                    senzaEseguibile.append(s.nome)
                }
            } else {
                senzaEseguibile.append(s.nome + " (bundle non leggibile)")
            }

            // 4) la scheda non deve essere una riga vuota: e' quello che legge il modello
            if risposta.trimmingCharacters(in: .whitespacesAndNewlines).count < 60 { schedeVuote.append(s.nome) }
            if s.architettura == "sconosciuta" { architetturaSconosciuta.append(s.nome) }

            // "non registrata in LaunchServices" NON e' un difetto di Jarvis: e' un fatto
            // del suo Mac (News tolta/disabilitata). `apri` passa dal percorso, quindi
            // funziona lo stesso: va elencata, non contata come bocciata.
            if difetti.isEmpty, collisioni.last != s.nome,
                senzaEseguibile.last != s.nome, schedeVuote.last != s.nome { promosse += 1 }
            for d in difetti { print("  difetto \(s.nome): \(d)") }
        }
        var fuori = "\n== \(promosse)/\(inventario.count) app senza difetti =="
        func lista(_ titolo: String, _ v: [String]) -> String {
            v.isEmpty ? "" : "\n\(titolo) (\(v.count)): " + v.prefix(24).joined(separator: ", ")
        }
        fuori += lista("nome che risolve un'altra app (da correggere)", collisioni)
        fuori += lista("due app con lo stesso nome a schermo: \(Marca.nome) chiede quale", Array(Set(stesseNome)).sorted())
        fuori += lista("Particolarita' del Mac: esistono su disco ma non sono nel registro di LaunchServices "
            + "(il percorso le apre lo stesso)", nonRegistrata)
        fuori += lista("binario non eseguibile o bundle illeggibile", senzaEseguibile)
        fuori += lista("scheda troppo corta", schedeVuote)
        fuori += lista("architettura non riconoscibile", architetturaSconosciuta)
        print(fuori + "\n")
        try? fuori.write(to: AppPaths.jarvisRoot.appendingPathComponent("logs/prove-app.txt"),
                         atomically: true, encoding: .utf8)
        return fuori
    }
}
