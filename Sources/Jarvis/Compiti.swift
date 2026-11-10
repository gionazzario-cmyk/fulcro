import Foundation
import AppKit

/// I compiti dell'utente, salvati in ~/.jarvis/compiti.md: un file che lui puo'
/// aprire e correggere anche a mano, senza passare da Jarvis.
///
///     - [ ] 2026-10-20 · matematica · esercizi 14-18 pag. 132 · https://youtube.com/watch?v=...
///
/// Ogni riga e': spunta · scadenza · materia · cosa · pagina.
/// Scadenza e pagina sono opzionali; la pagina e il punto dove il watchdog
/// riportall'utente quando si sconcentra.
enum Compiti {
    struct C {
        var materia: String
        var cosa: String
        var scadenza: String
        var pagina: String
        var fatto: Bool
    }

    static var path: URL { AppPaths.jarvisRoot.appendingPathComponent("compiti.md") }

    private static let testata = """
        # Compiti
        # Un compito per riga, cosi:  - [ ] scadenza · materia · cosa fare · pagina
        # Le righe che iniziano con # non sono compiti: sono la legenda.
        # [x] vuol dire gia' finito. Come scadenza va bene "domani", "venerdi", "20-11" o "2026-11-20".

        """

    // MARK: - lettura e scrittura

    /// Legge la lista. Con `tutti: true` riporta anche i gia' fatti.
    static func leggi(tutti: Bool = false) -> [C] {
        let testo = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var out: [C] = []
        for riga in testo.components(separatedBy: .newlines) {
            let t = riga.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- [") else { continue }
            let finito = t.hasPrefix("- [x]") || t.hasPrefix("- [X]")
            if finito && !tutti { continue }
            let corpo = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            // le versioni vecchie del file avevano l'esempio come riga vera: non va salvato come compito
            if corpo.hasPrefix("scadenza · materia") || corpo.hasPrefix("scadenza - materia") { continue }
            let parti = corpo.components(separatedBy: " · ").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            var i = 0
            var scadenza = ""
            if i < parti.count, eData(parti[i]) { scadenza = parti[i]; i += 1 }
            let materia = i < parti.count ? parti[i] : ""
            if i < parti.count { i += 1 }
            let cosa = i < parti.count ? parti[i] : ""
            if i < parti.count { i += 1 }
            let pagina = i < parti.count ? parti[i] : ""
            // se ha scritto solo una cosa senza materia, quella diventa la materia
            if cosa.isEmpty { out.append(C(materia: scadenza.isEmpty ? "compiti" : materia,
                                          cosa: materia.isEmpty ? corpo : materia,
                                          scadenza: scadenza, pagina: pagina, fatto: finito)) }
            else { out.append(C(materia: materia.isEmpty ? "compiti" : materia,
                                cosa: cosa, scadenza: scadenza, pagina: pagina, fatto: finito)) }
        }
        return out
    }

    /// Riscrive tutto il file: in cima cosa' che scade prima, i fatti in fondo.
    @discardableResult
    static func salva(_ lista: [C]) -> String {
        let ordinate = lista.sorted { a, b in
            if a.fatto != b.fatto { return !a.fatto }
            if a.scadenza != b.scadenza {
                if a.scadenza.isEmpty { return false }
                if b.scadenza.isEmpty { return true }
                return a.scadenza < b.scadenza
            }
            return false
        }
        var corpo = testata
        for c in ordinate {
            let parti = [c.scadenza, c.materia, c.cosa, c.pagina].filter { !$0.isEmpty }
            let stato = c.fatto ? "x" : " "
            corpo += "- [\(stato)] \(parti.joined(separator: " · "))\n"
        }
        do { try corpo.write(to: path, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a scrivere ~/.jarvis/compiti.md: \(error.localizedDescription)" }
        return "salvato in ~/.jarvis/compiti.md"
    }

    // MARK: - azioni

    static func aggiungi(materia: String, cosa: String, scadenza raw: String, pagina: String) -> String {
        let m = materia.trimmingCharacters(in: .whitespaces)
        let c = cosa.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return "Dimmi cosa devi fare, non solo la materia." }
        let nuovo = C(materia: m.isEmpty ? "compiti" : m, cosa: c,
                      scadenza: normalizzaData(raw), pagina: pagina.trimmingCharacters(in: .whitespaces),
                      fatto: false)
        var lista = leggi(tutti: true)
        if lista.contains(where: { !$0.fatto && $0.cosa.lowercased() == nuovo.cosa.lowercased() }) {
            return "C'era gia' nella lista: \(nuovo.materia) — \(nuovo.cosa)"
        }
        lista.append(nuovo)
        let dove = nuovo.scadenza.isEmpty ? "" : " entro \(nuovo.scadenza)"
        return "Aggiunto: \(nuovo.materia) — \(nuovo.cosa)\(dove) (\(salva(lista)))"
    }

    /// Spunta il compito che contiene una parola dell'utente; se uno solo, prende quello.
    static func fatto(_ testo: String) -> String {
        let aperta = leggi()
        guard !aperta.isEmpty else { return "La lista compiti e' vuota: niente da segnare come fatto." }
        let chiave = testo.lowercased().trimmingCharacters(in: .whitespaces)
        var scelto: C?
        if chiave.isEmpty {
            scelto = aperta.count == 1 ? aperta[0] : nil
            if scelto == nil { return "Dimmi quale: \(aperta.map { $0.materia }.joined(separator: ", "))" }
        } else {
            scelto = aperta.first { $0.materia.lowercased().contains(chiave) || $0.cosa.lowercased().contains(chiave) }
            guard scelto != nil else {
                return "Non ho trovato «\(testo)» tra: \(aperta.map { $0.materia }.joined(separator: ", "))"
            }
        }
        var tutti = leggi(tutti: true)
        guard let i = tutti.firstIndex(where: { $0.cosa == scelto!.cosa && $0.materia == scelto!.materia }) else {
            return "Il file e' cambiato mentre leggevo: riprova."
        }
        tutti[i].fatto = true
        return "Fatto: \(tutti[i].materia) — \(tutti[i].cosa). \(salva(tutti))"
    }

    static func togli(_ testo: String) -> String {
        let aperta = leggi()
        let chiave = testo.lowercased()
        guard let primo = aperta.first(where: {
            $0.materia.lowercased().contains(chiave) || $0.cosa.lowercased().contains(chiave)
        }) else { return "Nessun compito con «\(testo)»." }
        var tutti = leggi(tutti: true)
        tutti.removeAll { $0.cosa == primo.cosa && $0.materia == primo.materia }
        return "Tolto: \(primo.materia) — \(primo.cosa). \(salva(tutti))"
    }

    /// Il resoconto che legge Jarvis: ordine di scadenza, pagina inclusa.
    static func lista() -> String {
        let aperta = leggi()
        guard !aperta.isEmpty else {
            return "La lista dei compiti e' vuota: dimmi materia e cosa devi fare e la scrivo in ~/.jarvis/compiti.md."
        }
        var righe: [String] = []
        let finita = leggi(tutti: true).filter { $0.fatto }.count
        for (n, c) in aperta.enumerated() {
            var testo = "\(n + 1). \(c.materia): \(c.cosa)"
            if let g = giorniPer(c.scadenza) { testo += g }
            if !c.pagina.isEmpty { testo += " [pagina: \(c.pagina)]" }
            righe.append(testo)
        }
        let coda = finita > 0 ? "\nGià chiusi: \(finita)." : ""
        return "\(aperta.count) compiti da fare:\n" + righe.joined(separator: "\n") + coda
    }

    /// Il primo da fare: scadenza piu' vicina; chi non ha scadenza va per ultimo.
    static func prossimo() -> C? {
        leggi().sorted { a, b in
            if a.scadenza.isEmpty { return false }
            if b.scadenza.isEmpty { return true }
            return a.scadenza < b.scadenza
        }.first
    }

    /// "qual e' la pagina dei compiti": prima quella del compito in cima, poi il resto.
    static func paginaDiStudio() -> String {
        if let p = prossimo()?.pagina, !p.isEmpty { return p }
        return leggi().first(where: { !$0.pagina.isEmpty })?.pagina ?? ""
    }

    // MARK: - date

    private static func eData(_ s: String) -> Bool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return s.count == 10 && f.date(from: s) != nil
    }

    /// Accetta "oggi", "domani", "venerdi", "20-11", "20 novembre", "2026-11-20"
    /// e restituisce sempre yyyy-MM-dd (o stringa vuota se non capisce).
    private static func normalizzaData(_ raw: String) -> String {
        let s = raw.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if eData(s) { return s }
        if let offset = offsetFrase(s) { return traGiorni(offset) }
        if let wd = giornoSettimana(s) { return prossimo(weekday: wd) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        for formato in ["dd-MM", "dd/MM", "d MMM", "d MMMM", "dd MMMM", "dd MMM yyyy", "d MMM yyyy"] {
            f.dateFormat = formato
            if let date = f.date(from: s) {
                // senza anno: se la data e' gia' passata, l'utente intende l'anno prossimo
                if !formato.contains("yyyy"), date < Date(),
                   let sp = Calendar.current.date(byAdding: .year, value: 1, to: date) {
                    return formaData(sp)
                }
                return formaData(date)
            }
        }
        return ""
    }

    /// "oggi", "domani", "dopodomani", "tra tre giorni", "la settimana prossima".
    private static func offsetFrase(_ s: String) -> Int? {
        let pulito = s.replacingOccurrences(of: "il ", with: "")
        switch pulito {
        case "oggi", "adesso", "stasera", "oggi stesso": return 0
        case "domani", "doman": return 1
        case "dopodomani", "dopo domani": return 2
        case "dopodomani sera": return 2
        default: break
        }
        let numeri = ["uno": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5,
                      "sei": 6, "sette": 7, "otto": 8, "nove": 9, "dieci": 10, "undici": 11, "dodici": 12]
        if pulito.hasPrefix("tra ") {
            let coda = String(pulito.dropFirst(4))
            var n = Int(coda.components(separatedBy: " ").first ?? "")
            if n == nil { n = numeri[coda.components(separatedBy: " ").first ?? ""] }
            if let n, coda.contains("mese") { return n * 30 }
            if let n, coda.contains("settim") { return n * 7 }
            if let n { return n }
        }
        if pulito.contains("settimana prossima") || pulito.contains("prossima settimana") { return 7 }
        return nil
    }

    /// I giorni della settimana, con o senza accenti: "venerdi", "mercoledi'".
    private static func giornoSettimana(_ s: String) -> Int? {
        let senzaAccenti = s
            .replacingOccurrences(of: "ì", with: "i")
            .replacingOccurrences(of: "è", with: "e")
            .replacingOccurrences(of: "é", with: "e")
            .replacingOccurrences(of: "'", with: "")
        let mappa = ["lunedi": 2, "lun": 2, "martedi": 3, "mar": 3, "mercoledi": 4, "mer": 4,
                     "giovedi": 5, "gio": 5, "venerdi": 6, "ven": 6, "sabato": 7, "sab": 7,
                     "domenica": 1, "dom": 1]
        for (nome, giorno) in mappa where senzaAccenti.contains(nome) { return giorno }
        return nil
    }

    private static func prossimo(weekday: Int) -> String {
        let cal = Calendar.current
        let oggi = cal.component(.weekday, from: Date())
        // "entro venerdi" detto di venerdi = il venerdi della settimana prossima
        let distanza = (weekday - oggi + 7) % 7
        return traGiorni(distanza == 0 ? 7 : distanza)
    }

    private static func traGiorni(_ n: Int) -> String {
        formaData(Calendar.current.date(byAdding: .day, value: n, to: Date()) ?? Date())
    }

    private static func formaData(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private static func giorniPer(_ scadenza: String) -> String? {
        guard !scadenza.isEmpty, let date = data(scadenza) else { return nil }
        let cal = Calendar.current
        let giorni = cal.dateComponents([.day], from: cal.startOfDay(for: Date()),
                                       to: cal.startOfDay(for: date)).day ?? 0
        if giorni < 0 { return " (in ritardo di \(-giorni) giorni)" }
        if giorni == 0 { return " (OGGI)" }
        if giorni == 1 { return " (domani)" }
        return " (entro \(giorni) giorni)"
    }

    private static func data(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

/// Il watchdog dei compiti: mentre l'utente studia guarda quale app sta davanti
/// e, se scivola su una distrazione, lo riporta sulla pagina dei compiti.
/// Usa solo NSWorkspace: nessun permesso nuovo di macOS.
@MainActor
final class Studio: ObservableObject {
    static let shared = Studio()

    @Published var attivo = false
    @Published var pagina = ""
    @Published var minutiRimasti = 0

    /// Scrive una riga nella chat di Jarvis quando succede qualcosa.
    var onNote: ((String) -> Void)?

    /// App che fanno sconcentrare, lette da ~/.jarvis/distrazioni.txt
    static var distrazioniPath: URL { AppPaths.jarvisRoot.appendingPathComponent("distrazioni.txt") }

    private var timer: Timer?
    private var daQuanto: Date?
    private var ultimaScossa = Date.distantPast
    private var fine: Date?

    private let distrazioneMinima = 40.0
    private let ripetiOgni = 150.0

    /// Le soglie si possono forzare solo per i test, cosi' il watchdog si puo'
    /// provare in pochi secondi invece che aspettare tre quarti d'ora.
    static var sogliaForzato: TimeInterval?
    static var ripetiForzato: TimeInterval?

    /// Quale app finge di avere davanti nei test: con lo schermo bloccato il sistema
    /// non restituisce niente, e il collaudo dipenderebbe da chi sta al Mac.
    static var davantiPerTest: String?

    private init() {}

    /// Le distrattici, con un file di esempio gia' scritto per farle modificare all'utente.
    static func distrazioni() -> [String] {
        let base = """
        # Le app che distraggono: una per riga, basta il nome (anche parziale).
        # Jarvis le ignora finche non ci sta sopra piu' di 40 secondi di fila.
        Fortnite
        Minecraft
        Steam
        SuperTuxKart
        Netflix
        TikTok
        Discord
        Telegram
        WhatsApp
        Messaggi
        Anteprima
        """
        if let testo = try? String(contentsOf: distrazioniPath, encoding: .utf8), !testo.isEmpty {
            return righe(testo)
        }
        try? base.write(to: distrazioniPath, atomically: true, encoding: .utf8)
        return righe(base)
    }

    private static func righe(_ testo: String) -> [String] {
        testo.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// "inizia i compiti": parte il controllo con la pagina dove tornare.
    func accendi(pagina raw: String, minuti: Int) -> String {
        let scelta = raw.isEmpty ? Compiti.paginaDiStudio() : raw
        pagina = scelta
        attivo = true
        daQuanto = nil
        ultimaScossa = Date.distantPast
        let durata = minuti > 0 ? min(minuti, 600) : 90
        fine = Date().addingTimeInterval(TimeInterval(durata * 60))
        minutiRimasti = durata
        timer?.invalidate()
        avviaTimer()
        let dove = scelta.isEmpty
            ? "ti avvisero' e basta, perche' non hai indicato nessuna pagina"
            : "ti riporta su \(scelta)"
        return "Modalita' compiti accesa per \(durata) minuti: \(dove). Di' «spegni i compiti» quando hai finito."
    }

    /// Guardare la app davanti ogni 5 secondi per un'ora e' il lavoro silenzioso che
    /// gli da' fastidio: quando il piano dice "non ora" il timer non viene creato,
    /// non viene creato e poi ignorato.
    private func avviaTimer() {
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in Studio.shared.controllo() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Sospende la sorveglianza senza spegnere la modalita' compiti: se riattacca la
    /// corrente mentre e' in tempo, riparte da sola.
    @MainActor func sospendi() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor func riprendi() {
        guard attivo, timer == nil, let fine = fine, Date() < fine else { return }
        avviaTimer()
    }

    func spegni() -> String {
        attivo = false
        timer?.invalidate()
        timer = nil
        fine = nil
        daQuanto = nil
        return "Modalita' compiti spenta: non ti guardo piu' le spalle."
    }

    var stato: String {
        guard attivo else { return "Modalita' compiti spenta." }
        let davanti = NSWorkspace.shared.frontmostApplication?.localizedName ?? "niente"
        return "Accesa, \(minutiRimasti) minuti ancora. App davanti: \(davanti). Pagina dei compiti: \(pagina.isEmpty ? "non indicata" : pagina)"
    }

    /// La decisione vera, messa qui cosi' si puo' provare senza dipendere
    /// da quale app capita di avere davanti in quel momento.
    nonisolated static func deveScuotere(nome: String, daQuanto: TimeInterval, dallUltima: TimeInterval,
                                         distrazioni: [String], soglia: TimeInterval = 40,
                                         ripeti: TimeInterval = 150) -> Bool {
        guard !nome.isEmpty else { return false }
        guard distrazioni.contains(where: { nome.localizedCaseInsensitiveContains($0) }) else { return false }
        return daQuanto >= soglia && dallUltima >= ripeti
    }

    func controllo() {
        guard attivo else { return }
        if let fine {
            if Date() >= fine {
                onNote?("Modalita' compiti finita da sola: ancora \(Compiti.leggi().count) da fare.")
                JarvisCore.shared.dillo("Time out: la sessione di compiti e' finita.")
                _ = spegni()
                return
            }
            minutiRimasti = max(0, Int((fine.timeIntervalSinceNow / 60).rounded(.up)))
        }
        let nome = Studio.davantiPerTest ?? (NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
        let distratto = !nome.isEmpty && Self.distrazioni().contains(where: {
            nome.localizedCaseInsensitiveContains($0)
        })
        guard distratto else {
            // appena torna su una cosa seria il conteggio riparte da zero
            daQuanto = nil
            return
        }
        if daQuanto == nil { daQuanto = Date() }
        guard let inizio = daQuanto else { return }
        guard Self.deveScuotere(nome: nome,
                                daQuanto: Date().timeIntervalSince(inizio),
                                dallUltima: Date().timeIntervalSince(ultimaScossa),
                                distrazioni: Self.distrazioni(),
                                soglia: Studio.sogliaForzato ?? distrazioneMinima,
                                ripeti: Studio.ripetiForzato ?? ripetiOgni) else { return }
        ultimaScossa = Date()
        scossa(nome: nome, minuti: Int(Date().timeIntervalSince(inizio) / 60))
    }

    /// Riportall'utente sulla pagina dei compiti, a voce e con un clic vero.
    private func scossa(nome: String, minuti: Int) {
        let compito = Compiti.prossimo()
        let cosa: String
        if let c = compito { cosa = "\(c.materia): \(c.cosa)" }
        else { cosa = "i compiti, che non hai ancora scritto nella lista" }
        let testo = minuti <= 0
            ? "Sei su \(nome). Tocca \(cosa)."
            : "Sei su \(nome) da \(minuti) minuti. Tocca \(cosa)."
        onNote?(testo)
        JarvisCore.shared.dillo(testo)
        apriPagina()
    }

    /// Apre la pagina salvata: un indirizzo, un file, o l'app con quel nome.
    func apriPagina() {
        let target = pagina.isEmpty ? Compiti.paginaDiStudio() : pagina
        guard !target.isEmpty else { return }
        if target.hasPrefix("http://") || target.hasPrefix("https://"), let u = URL(string: target) {
            NSWorkspace.shared.open(u)
            return
        }
        if target.hasPrefix("/"), FileManager.default.fileExists(atPath: target) {
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
            return
        }
        // niente link: riportiamo avanti l'app che l'utente usa per i compiti
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(target)
        }) {
            app.activate(options: [.activateAllWindows])
        } else {
            apriConOpen(target)
        }
    }

    /// `open -a Nome` senza aspettare: il processo principale non deve mai bloccarsi qui.
    private func apriConOpen(_ nome: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", nome]
        try? p.run()
    }
}

// MARK: - gambe per il modello

extension Tools {
    /// `compiti`: la lista che l'utente puo' anche editare a mano.
    static func compitiSkill(_ args: [String: Any]) -> String {
        func a(_ k: String) -> String { (args[k] as? String) ?? "" }
        let indizio = a("materia").isEmpty ? a("cosa") : a("materia")
        switch a("azione") {
        case "lista":
            return Compiti.lista()
        case "aggiungi":
            return Compiti.aggiungi(materia: a("materia"), cosa: a("cosa"),
                                    scadenza: a("scadenza"), pagina: a("pagina"))
        case "fatto":
            return Compiti.fatto(indizio)
        case "togli":
            return Compiti.togli(indizio)
        default:
            return "Azioni compiti: lista, aggiungi, fatto, togli."
        }
    }

    /// `modalita_studio`: accende e spegne il watchdog sui compiti.
    static func studioSkill(_ args: [String: Any]) async -> String {
        // valori letti prima: le closure di MainActor.run devono essere @Sendable,
        // quindi non possono catturare una funzione locale che legge args
        let azione = (args["azione"] as? String) ?? ""
        let pagina = (args["pagina"] as? String) ?? ""
        let cifre = ((args["minuti"] as? String) ?? "").filter { $0.isNumber }
        let minuti = Int(String(cifre)) ?? 0
        switch azione {
        case "accendi":
            return await MainActor.run { Studio.shared.accendi(pagina: pagina, minuti: minuti) }
        case "spegni":
            return await MainActor.run { Studio.shared.spegni() }
        case "stato":
            return await MainActor.run {
                Studio.shared.stato + (Alimentazione.inCarica ? ""
                    : "\n(NOTA: a batteria il watchdog e' in pausa e non ti scuote: riattacca la corrente)")
            }
        case "riapri_pagina":
            await MainActor.run { Studio.shared.apriPagina() }
            let pagina = await MainActor.run { Studio.shared.pagina }
            return pagina.isEmpty
                ? "Nessuna pagina salvata nei compiti: dimmi un link o un'app e la ricordo."
                : "Riapro \(pagina)."
        default:
            return "Azioni: accendi, spegni, stato, riapri_pagina."
        }
    }

    /// `voce`: interruptsore vero della parlante, non il volume del Mac.
    static func voceSkill(_ azione: String, nome: String = "") async -> String {
        switch azione {
        case "cambia":
            return AppPaths.scegliVoce(nome)
        case "stato":
            let pronte = AppPaths.disponibili().map { "\($0.nome) (\($0.desc))" }.joined(separator: ", ")
            let accesa = await MainActor.run { JarvisCore.shared.voiceOn }
            return "Voce attuale: \(AppPaths.capitalizza(AppPaths.voceCorrente)), "
                + (accesa ? "accesa." : "spenta (rispondo scritto).") + " Pronte: \(pronte)."
        case "accendi":
            await MainActor.run { JarvisCore.shared.voiceOn = true }
            return "Voce accesa: ora ti rispondo anche a voce."
        case "spegni":
            await MainActor.run { JarvisCore.shared.voiceOn = false }
            return "Voce spenta: rispondo solo scritto."
        default:
            return "Dimmi accendi, spegni, stato, o cambia voce (serena / riccardo)."
        }
    }
}
