import Foundation

struct ToolCall {
    let id: String
    let name: String
    var arguments: String
}

struct ChatTurn {
    var role: String
    var content: String
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var name: String?
}

enum BrainError: LocalizedError {
    case noModel
    case http(Int, String)
    case cannotEncode

    var errorDescription: String? {
        switch self {
        case .noModel: return "Ollama non ha nessun modello pronto: avvia Ollama e scarica qwen3:8b."
        case .http(let code, let body): return "Ollama ha risposto \(code): \(body.prefix(180))"
        case .cannotEncode: return "Non riesco a costruire la richiesta per il modello."
        }
    }
}

/// Client locale per Ollama (http://127.0.0.1:11434). Nessun dato esce dal Mac.
final class Brain {
    static let shared = Brain()

    private let base = URL(string: "http://127.0.0.1:11434")!
    private let preferred = ["qwen3:8b", "qwen3:14b", "qwen3:4b", "qwen2.5:7b-instruct",
                             "llama3.1:8b", "qwen3:0.6b", "deepseek-r1"]
    private(set) var cachedModel: String?

    /// Quanto il modello resta in RAM dopo l'ultima richiesta. Ogni messaggio
    /// rinnova il conto: se non parli per 30 secondi Ollama lo scarica da solo e
    /// il Mac smette di scaldare. Non e' un timer nostro: lo gestisce Ollama,
    /// quindi vale anche se Jarvis viene chiuso mentre aspetta.
    static let riposo = "30s"

    /// Quante volte il modello locale e' stato interpellato: i test a batteria
    /// verificano con questo che il cervello era davvero sul cloud.
    static var richieste = 0

    private init() {}

    func models() async -> [String] {
        guard let data = try? await get("/api/tags"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }
    }

    /// Sceglie il primo modello utile tra quelli che hai gia scaricato.
    /// ~/.jarvis/modello.txt dice a Jarvis quale cervello usare: cosi' il passaggio
    /// dall'8b al 30b (o il ritorno indietro) e' un file, non una ricompilazione.
    static var modelloSalvato: String? {
        let letto = ((try? String(contentsOf: AppPaths.jarvisRoot.appendingPathComponent("modello.txt"), encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return letto.isEmpty ? nil : letto
    }

    /// Forzatura temporanea, usata dal confronto tra modelli.
    static var modelloForzato: String?

    func resolveModel() async -> String? {
        if let cachedModel { return cachedModel }
        let available = await models()
        guard !available.isEmpty else { return nil }
        // prima la forzatura del test, poi il file di scelta, poi le preferenze di default
        for preferito in [Brain.modelloForzato, Brain.modelloSalvato] {
            if let wanted = preferito,
               available.contains(where: { $0 == wanted || $0.hasPrefix(wanted) }) {
                cachedModel = available.first { $0 == wanted || $0.hasPrefix(wanted) }
                return cachedModel
            }
        }
        let chosen = preferred.first { want in
            available.contains { $0 == want || $0.hasPrefix(want) }
        } ?? available.first { !$0.contains("embedding") }
        cachedModel = chosen
        return chosen
    }

    func isAlive() async -> Bool {
        (try? await get("/api/version")) != nil
    }

    /// Chiede a Ollama di caricare il modello ADESSO, senza aspettare la prima
    /// domanda: lo chiama il microfono appena inizi a parlare, cosi la frase e'
    /// gia' pronta quando finisci. Non si chiama piu' all'avvio dell'app.
    func warmUp() async {
        guard let model = await resolveModel() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            // non "30s": mentre parli puo' passare piu' di mezzo minuto, e se il
            // modello si scaricasse a meta' dettatura la risposta ripartirebbe da
            // freddo. Due minuti coprono anche una frase lunga; a richiesta vera
            // arrivata, e' la chat a rimettere il conto a 30 s (Brain.riposo).
            "model": model, "prompt": "", "keep_alive": "2m"
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    private let visionPreferred = ["qwen2.5vl:7b", "llama3.2-vision:11b", "minicpm-v", "moondream"]

    func visionModel() async -> String? {
        let available = await models()
        return visionPreferred.first { want in available.contains { $0 == want || $0.hasPrefix(want) } }
    }

    /// Un giro secco con un modello visivo: immagine dentro, testo fuori.
    func askVision(image: URL, prompt: String) async -> String {
        guard let model = await visionModel(), let raw = try? Data(contentsOf: image) else { return "" }
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 200
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": Brain.riposo,
            "options": ["temperature": 0.2, "num_ctx": 4096],
            "messages": [["role": "user", "content": prompt, "images": [raw.base64EncodedString()]]]
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        req.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any] else { return "" }
        return (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// I token che qwen3 usa per il ragionamento interno (la barra e' U+FF5C, non la
    /// normale "|": per questo qui si costruiscono, cosi' il codice resta leggibile).
    static let barraLarga = String(UnicodeScalar(0xFF5C)!)
    static let pensieroAperto = barraLarga + "think|"
    static let pensieroChiuso = barraLarga + "|think|"

    /// Toglie il ragionamento interno di qwen3 dal testo che si fa vedere: il modello
    /// apre il blocco di pensiero anche quando gli hai messo think:false, e quel pezzo
    /// finiva in chat (l'utente se l'e' visto uscire il 2026-10-19 sera).
    /// Con `aprendo` si taglia anche un blocco aperto a meta': a meta' frase non si sa
    /// se e' pensiero o risposta, e il pensiero non deve comparire comunque.
    static func pulisciPensiero(_ testo: String, aprendo: Bool = true) -> String {
        var fuori = testo
        while true {
            guard let inizio = fuori.range(of: pensieroAperto) ?? fuori.range(of: pensieroChiuso) else { break }
            let dopo = String(fuori[inizio.upperBound...])
            if let fine = dopo.range(of: pensieroAperto) ?? dopo.range(of: pensieroChiuso)
                ?? dopo.range(of: "/think>") ?? dopo.range(of: "<|im_") {
                fuori = String(fuori[..<inizio.lowerBound]) + String(dopo[fine.upperBound...])
            } else if aprendo {
                // blocco ancora aperto: da qui in poi e' ragionamento, non risposta
                fuori = String(fuori[..<inizio.lowerBound])
                break
            } else {
                fuori = String(fuori[..<inizio.lowerBound]) + dopo
                break
            }
        }
        // pezzetti sporchi che restano (chiusura senza apertura, tag spezzati a meta',
        // e i marcatore ChatML che qwen3 a volte sputa fuori)
        for resto in [pensieroAperto, pensieroChiuso, "/think>", "",
                      barraLarga + "|im_start|", barraLarga + "|im_end|"] {
            fuori = fuori.replacingOccurrences(of: resto, with: "")
        }
        return fuori.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chat con tool calling. Il testo arriva pezzo per pezzo su onDelta.
    func stream(turns: [ChatTurn], tools: [[String: Any]], onDelta: @escaping (String) -> Void)
        async throws -> (text: String, calls: [ToolCall])
    {
        Brain.richieste += 1
        guard let model = await resolveModel() else { throw BrainError.noModel }

        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "keep_alive": Brain.riposo,
            // top-level, non dentro options: qui dentro questa versione di Ollama lo ignora
            // e qwen3 "ragiona" per 240 token prima di rispondere (11 s invece di 0,3)
            "think": false,
            "messages": turns.map { encodeTurn($0) },
            "options": [
                "temperature": 0.2,
                "num_ctx": 8192,
                // senza questo il modello pu' entrare in ripetizione e generare
                // fino a riempire il contesto: Jarvis sembra morto per minuti
                "num_predict": 700
            ]
        ]
        if !tools.isEmpty { payload["tools"] = tools }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw BrainError.cannotEncode
        }

        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = body

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 2000 { break }
            }
            throw BrainError.http(http.statusCode, String(decoding: collected, as: UTF8.self))
        }

        var full = ""
        var mostrato = ""
        var collected: [Int: ToolCall] = [:]
        var order: [Int] = []
        // rete che si inceppa o modello che si ripete: dopo 50 secondi si risponde
        // con quello che c'e', invece di restare zitti
        let scadenza = Date().addingTimeInterval(50)

        for try await line in bytes.lines {
            if Date() > scadenza { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw BrainError.http(500, err) }
            guard let msg = obj["message"] as? [String: Any] else { continue }

            if let piece = msg["content"] as? String, !piece.isEmpty {
                full += piece
                // qwen3 apre il blocco di pensiero anche con think:false: quel testo non
                // deve arrivare nella chat, ne' adesso ne' alla fine
                let mostrabile = Brain.pulisciPensiero(full, aprendo: true)
                if mostrabile.count > mostrato.count {
                    onDelta(String(mostrabile.dropFirst(mostrato.count)))
                    mostrato = mostrabile
                }
                if full.count > 2600 { break }
            }
            if let calls = msg["tool_calls"] as? [[String: Any]] {
                for (i, raw) in calls.enumerated() {
                    let fn = raw["function"] as? [String: Any] ?? [:]
                    // Ollama manda una chiamata per chunk e l'indice VERO sta dentro function.index:
                    // leggerlo in cima al oggetto fa finire tutte le chiamate una sopra l'altra
                    let key = (fn["index"] as? Int) ?? (raw["index"] as? Int) ?? i
                    let name = fn["name"] as? String ?? ""
                    let frag = Self.argumentFragment(fn["arguments"])
                    let id = (raw["id"] as? String) ?? (fn["id"] as? String) ?? "\(name)-\(key)"
                    if let existing = collected[key] {
                        collected[key] = ToolCall(id: existing.id.isEmpty ? id : existing.id,
                                                 name: existing.name.isEmpty ? name : existing.name,
                                                 arguments: existing.arguments + frag)
                    } else {
                        order.append(key)
                        collected[key] = ToolCall(id: id, name: name, arguments: frag)
                    }
                }
            }
        }

        var calls = order.compactMap { collected[$0] }.filter { !$0.name.isEmpty }
        // La risposta che torna in su e' senza pezzo di pensiero. Ma se il filtro si
        // mangiasse tutto (il modello ha emesso SOLO il blocco di pensiero), meglio
        // riconsegnare il testo ripulito dai tag che una pagina bianca: "Non sono
        // riuscito a rispondere" per colpa del filtro e' peggio del difetto di prima.
        var testo = Self.pulisciPensiero(full)
        if testo.isEmpty && !full.isEmpty {
            testo = Self.pulisciPensiero(full, aprendo: false)
        }
        // qwen3 a volte SCRIVE la chiamata invece di emetterla: il testo diventa un
        // JSON {"name": "youtube", "arguments": {...}} e dal di fuori sembra che non
        // abbia chiamato niente (visto il 2026-10-21 con «chi sta vincendo il mondiale
        // piloti?»). Se `tool_calls` e' vuoto ma la chiamata sta li' dentro, la recupero.
        if calls.isEmpty, let ricavata = Self.chiamataNelTesto(testo) {
            calls = [ricavata]
            testo = ""
        }
        return (testo, calls)
    }

    /// Estrae una chiamata scritta a crudo nel testo: con i ``` attorno, con testo
    /// intorno, con `function` annidato o con nome e argomenti in cima. Il nome deve
    /// essere quello di uno strumento vero, altrimenti non e' una chiamata: e' una
    /// risposta, e non va toccata.
    static func chiamataNelTesto(_ testo: String) -> ToolCall? {
        let pulito = testo.replacingOccurrences(of: "```", with: " ")
        guard let inizio = pulito.firstIndex(of: "{") else { return nil }
        var profondita = 0
        var fine = pulito.endIndex
        for i in pulito[inizio...].indices {
            if pulito[i] == "{" { profondita += 1 }
            else if pulito[i] == "}" {
                profondita -= 1
                if profondita == 0 { fine = pulito.index(after: i); break }
            }
        }
        let frammento = String(pulito[inizio..<fine])
        guard let data = frammento.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let annidato = obj["function"] as? [String: Any]
        let nome = (annidato?["name"] as? String) ?? (obj["name"] as? String) ?? ""
        guard !nome.isEmpty else { return nil }
        let nomi = Tools.shared.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        guard nomi.contains(nome) else { return nil }
        let grezzi = annidato?["arguments"] ?? obj["arguments"]
        var argomenti = "{}"
        if let t = grezzi as? String, !t.isEmpty { argomenti = t }
        else if let d = grezzi as? [String: Any], let dati = try? JSONSerialization.data(withJSONObject: d),
                let t = String(data: dati, encoding: .utf8) { argomenti = t }
        return ToolCall(id: "ricavata-\(nome)", name: nome, arguments: argomenti)
    }

    private static func argumentFragment(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let d = raw as? [String: Any], let s = try? JSONSerialization.data(withJSONObject: d),
           let str = String(data: s, encoding: .utf8) { return str }
        return ""
    }

    private func encodeTurn(_ t: ChatTurn) -> [String: Any] {
        var dict: [String: Any] = ["role": t.role]
        if !t.content.isEmpty { dict["content"] = t.content }
        if let id = t.toolCallId { dict["tool_call_id"] = id }
        if let name = t.name { dict["name"] = name }
        if let calls = t.toolCalls, !calls.isEmpty {
            dict["tool_calls"] = calls.map { call in
                ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": parseArgs(call.arguments)]]
            }
        }
        return dict
    }

    private func parseArgs(_ s: String) -> [String: Any] {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func get(_ path: String) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent(path))
        return data
    }
}
