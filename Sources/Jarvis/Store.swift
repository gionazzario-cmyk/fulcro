import Foundation

struct Entry: Codable {
    var ts: Date
    var role: String
    var text: String
    var source: String
    var session: String? = nil
}

/// Una chat della lista laterale: titolo preso dalla prima domanda,
/// quando e' cominciata e quanti messaggi contiene.
struct ChatSessione: Identifiable, Equatable {
    let id: String
    let titolo: String
    let inizio: Date
    let messaggi: Int
}

/// Log di tutto quello che dici e che risponde Jarvis: ~/.jarvis/logs/storico.jsonl
/// Ogni riga e un JSON, cosi puoi aprirlo e cercarci anche tu col Terminale o con Obsidian.
final class Store {
    static let shared = Store()

    let root: URL
    private let file: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var cache: [Entry] = []
    private var loaded = false
    private let lock = NSLock()
    private let sessionFile: URL
    private var sessioneCorrente = ""

    private init() {
        root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".jarvis")
        // --test e --ask non devono sporcare la cronologia vera dell'utente:
        // scrivono in un file separato, che si puo' cancellare quando si vuole.
        file = root.appendingPathComponent(SelfTest.modeCLICorrente ? "logs/storico-test.jsonl"
                                                                   : "logs/storico.jsonl")
        sessionFile = root.appendingPathComponent("logs/sessione-corrente.id")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("logs"),
                                                withIntermediateDirectories: true)
        // Si riprende la chat del giorno prima: la lista lateriale resta utile
        // solo se il filo corrente non cambia ogni volta che apri il Mac.
        if let id = try? String(contentsOf: sessionFile, encoding: .utf8),
           !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessioneCorrente = id.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sessioneCorrente = UUID().uuidString
            try? sessioneCorrente.write(to: sessionFile, atomically: true, encoding: .utf8)
        }
    }

    var sessioneAttuale: String {
        lock.lock(); defer { lock.unlock() }
        return sessioneCorrente
    }

    /// Apre un filo nuovo e lo rende quello corrente.
    @discardableResult
    func nuovaSessione() -> String { creaSessione() }

    /// Riprende un filo gia' esistente: da qui in poi le risposte ci finiscono dentro.
    func passaA(sessione id: String) {
        lock.lock(); sessioneCorrente = id; lock.unlock()
        try? id.write(to: sessionFile, atomically: true, encoding: .utf8)
    }

    private func creaSessione() -> String {
        let id = UUID().uuidString
        passaA(sessione: id)
        return id
    }

    /// Chiave di raggruppamento: le righe vecchie senza sessione formano una chat al giorno.
    private static func chiave(_ e: Entry) -> String {
        if let s = e.session, !s.isEmpty { return s }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "vecchio-" + f.string(from: e.ts)
    }

    /// Le righe scritte dai test e dalla modalita' --ask non sono chat dell'utente:
    /// restano nel log per la ricerca, ma non devono comparire nella lista a sinistra.
    static func daElencare(_ e: Entry) -> Bool {
        e.source != "selftest" && e.source != "debug"
    }

    /// Le chat della lista laterale, dalla piu' recente.
    func sessions(limit: Int = 60) -> [ChatSessione] {
        var ordine: [String] = []
        var raggruppate: [String: [Entry]] = [:]
        for e in all().filter(Self.daElencare) {
            let id = Self.chiave(e)
            if raggruppate[id] == nil { ordine.append(id) }
            raggruppate[id, default: []].append(e)
        }
        return ordine.reversed().prefix(limit).compactMap { id in
            guard let righe = raggruppate[id], let prima = righe.first else { return nil }
            let primaDomanda = righe.first(where: { $0.role == "tu" })?.text ?? "Chat"
            return ChatSessione(id: id,
                                titolo: Self.titolo(primaDomanda),
                                inizio: prima.ts,
                                messaggi: righe.filter { $0.role == "tu" || $0.role == "jarvis" }.count)
        }
    }

    /// Tutti i messaggi di una chat, in ordine (senza le righe dei test).
    func entries(session id: String) -> [Entry] {
        all().filter { Self.daElencare($0) && Self.chiave($0) == id }
    }

    private static func titolo(_ testo: String) -> String {
        let pulito = testo
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if pulito.count <= 46 { return pulito.isEmpty ? "Chat" : pulito }
        return String(pulito.prefix(46)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Versione del formato di `storico.jsonl`. Non e' decorativa: quando un campo
    /// di `Entry` cambia, la riga vecchia non decodifica e prima veniva buttata via
    /// in silenzio (`try?` dentro `compactMap`) — le chat sparivano dalla lista senza
    /// un errore. E' gia' successo aggiungendo `session`.
    static let schemaVersion = 1

    func record(role: String, text: String, source: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let e = Entry(ts: Date(), role: role, text: text, source: source, session: sessioneAttuale)
        lock.lock()
        defer { lock.unlock() }
        // Prima si legge il disco, poi si scrive in cache: se no il primo messaggio
        // della giornata "carica" il cache da solo e la lista chat parte da zero.
        _ = allLocked()
        cache.append(e)
        // La scrittura sta DENTRO il lock: prima era fuori, quindi due turni
        // contemporanei potevano intrecciare le righe sullo stesso FileHandle.
        guard let data = try? encoder.encode(e), let line = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            do { try (line + "\n").write(to: file, atomically: true, encoding: .utf8) }
            catch { NSLog("\(Marca.nome) store: non ho scritto lo storico: %@", error.localizedDescription) }
        }
    }

    func entries() -> [Entry] { all() }

    func reload() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        return allLocked()
    }

    private func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return allLocked()
    }

    /// Da chiamare tenendo il lock: carica lo storico.jsonl la prima volta.
    private func allLocked() -> [Entry] {
        if loaded { return cache }
        loaded = true
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { cache = []; return cache }
        var illeggibili = 0
        cache = raw.split(separator: "\n").compactMap {
            guard let d = String($0).data(using: .utf8) else { illeggibili += 1; return nil }
            do { return try decoder.decode(Entry.self, from: d) }
            catch { illeggibili += 1; return nil }
        }
        // Una riga che non decodifica non si butta via in silenzio: si dice quante
        // sono, cosi' un cambio di formato si vede invece di far sparire le chat.
        if illeggibili > 0 {
            NSLog("\(Marca.nome) store: %d righe di storico non leggibili (formato v%d)",
                  illeggibili, Self.schemaVersion)
        }
        return cache
    }

    /// Ricerca per parole chiave, ritorna i pezzi piu pertinenti degli ultimi tempi.
    func search(_ query: String, limit: Int = 8) -> [Entry] {
        let words = query.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .filter { $0.count > 2 }
        let entries = all()
        guard !words.isEmpty else { return Array(entries.suffix(limit)) }

        let scored: [(Entry, Int)] = entries.map { e in
            let hay = e.text.lowercased()
            let hits = words.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
            let recent = e.ts.timeIntervalSinceNow > -86_400 * 14 ? 1 : 0
            return (e, hits * 3 + recent)
        }
        return scored.filter { $0.1 > 0 }
            .sorted { ($0.1, $0.0.ts) > ($1.1, $1.0.ts) }
            .prefix(limit)
            .map(\.0)
    }

    func count() -> Int { all().count }
}
