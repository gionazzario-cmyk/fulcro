import Foundation

/// Le "cose" dell'utente: etichette → valori (link, numeri, indirizzi, nomi di file).
/// Il caso suo, detto alla lettera: «mi mandi il link di quell'affare e lui manda il
/// link di quell'affare». Per farlo servono due cose: dove il link sta di casa, e il
/// permesso di rimandarlo (che nei limiti dei messaggi altrimenti e' bloccato).
///
/// File: `~/.jarvis/cose.txt`, una riga per cosa nel formato `etichetta = valore`.
enum Cose {
    static var file: URL { AppPaths.jarvisRoot.appendingPathComponent("cose.txt") }

    private static var cache: [(etichetta: String, valore: String)] = []
    private static var cacheLetto = Date.distantPast

    static func tutte(forza: Bool = false) -> [(etichetta: String, valore: String)] {
        if !forza, Date().timeIntervalSince(cacheLetto) < 60, !cache.isEmpty { return cache }
        let testo = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        var fuori: [(String, String)] = []
        for riga in testo.split(separator: "\n") {
            let r = riga.trimmingCharacters(in: .whitespaces)
            if r.isEmpty || r.hasPrefix("#") { continue }
            guard let i = r.range(of: "=") else { continue }
            let etichetta = String(r[..<i.lowerBound]).trimmingCharacters(in: .whitespaces)
            let valore = String(r[i.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !etichetta.isEmpty && !valore.isEmpty { fuori.append((etichetta, valore)) }
        }
        cache = fuori
        cacheLetto = Date()
        return fuori
    }

    static func scrivi(_ lista: [(etichetta: String, valore: String)]) -> String? {
        let corpo = "# Le cose di \(Identita.nome): etichetta = valore (link, numeri, indirizzi).\n"
            + "# \(Marca.nome) la legge e la scrive con lo strumento `cose`; puoi aggiustarla a mano.\n"
            + lista.map { "\($0.etichetta) = \($0.valore)" }.joined(separator: "\n") + "\n"
        do { try corpo.write(to: file, atomically: true, encoding: .utf8); cacheLetto = .distantPast; return nil }
        catch { return "Non sono riuscito a scrivere \(file.path): \(error.localizedDescription)" }
    }

    /// Trova per etichetta (e, se non trova, per parole chiave dentro il valore).
    static func trova(_ etichetta: String) -> (etichetta: String, valore: String)? {
        let chiave = Memory.senzaAccenti(etichetta)
        guard !chiave.isEmpty else { return nil }
        let tutte = self.tutte()
        if let esatta = tutte.first(where: { Memory.senzaAccenti($0.etichetta) == chiave }) { return esatta }
        if let parziale = tutte.first(where: {
            let e = Memory.senzaAccenti($0.etichetta)
            return e.contains(chiave) || chiave.contains(e)
        }) { return parziale }
        return tutte.first(where: { Memory.senzaAccenti($0.valore).contains(chiave) })
    }

    /// Salva (o aggiorna) una cosa. Le etichette si confrontano senza accenti.
    static func salva(etichetta: String, valore: String) -> String {
        let e = etichetta.trimmingCharacters(in: .whitespaces)
        let v = valore.trimmingCharacters(in: .whitespaces)
        guard e.count >= 2, !v.isEmpty else { return "Dimmi etichetta e valore da ricordare." }
        var lista = tutte(forza: true)
        let chiave = Memory.senzaAccenti(e)
        if let i = lista.firstIndex(where: { Memory.senzaAccenti($0.etichetta) == chiave }) {
            if lista[i].valore == v { return "\u{00ab}\(e)\u{00bb} era gi\u{00e0} salvato con questo valore." }
            lista[i] = (e, v)
            if let errore = scrivi(lista) { return errore }
            return "Aggiornato \u{00ab}\(e)\u{00bb}: \(v)"
        }
        lista.append((e, v))
        if let errore = scrivi(lista) { return errore }
        return "Ricordato: \u{00ab}\(e)\u{00bb} = \(v)"
    }

    /// True se il testo contiene un link che l'utente ha salvato lui (o che ha appena
    /// dato): in quel caso il limite "niente link non dati da te" non si applica.
    static func linkConosciuto(_ testo: String) -> Bool {
        let bassa = testo.lowercased()
        for cosa in tutte() where cosa.valore.lowercased().hasPrefix("http") {
            if bassa.contains(cosa.valore) { return true }
        }
        return false
    }

    /// Cattura i link che arrivano nelle chat, cosi' «mandami il link di quell'affare»
    /// ha qualcosa da mandare. Niente duplicati: se l'URL c'e' gia', non si tocca.
    @discardableResult
    static func autoCattura(_ testo: String, da: String) -> Int {
        var esistenti = Set(tutte(forza: true).map { $0.valore })
        var aggiunte: [(String, String)] = []
        for url in urlNelTesto(testo) where !esistenti.contains(url) {
            let host = url.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .components(separatedBy: "/").first ?? "link"
            let chi = da.isEmpty ? "chat" : da
            aggiunte.append(("link di \(chi) su \(host)", url))
            esistenti.insert(url)
        }
        guard !aggiunte.isEmpty else { return 0 }
        var lista = tutte(forza: true)
        lista.append(contentsOf: aggiunte)
        _ = scrivi(lista)
        return aggiunte.count
    }

    /// Le URL che compaiono in un testo (per catturare il link che qualcuno ha mandato).
    static func urlNelTesto(_ testo: String) -> [String] {
        let pattern = #"https?://[^\s<>"']+"#
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let intervallo = NSRange(testo.startIndex..<testo.endIndex, in: testo)
        return rx.matches(in: testo, range: intervallo).compactMap { Range($0.range, in: testo).map { String(testo[$0]) } }
    }
}

extension Tools {
    /// `cose`: l'archivio di link/numeri/indirizzi dell'utente.
    static func coseSkill(_ args: [String: Any]) -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "salva":
            return Cose.salva(etichetta: a("etichetta"), valore: a("valore"))
        case "ritrova":
            guard let trovata = Cose.trova(a("etichetta")) else {
                return "Non ho niente di salvato con \u{00ab}\(a("etichetta"))\u{00bb}. Le etichette che conosco: "
                    + Cose.tutte().map { $0.etichetta }.prefix(20).joined(separator: ", ")
            }
            return "\(trovata.etichetta) = \(trovata.valore)"
        case "lista":
            let tutte = Cose.tutte()
            guard !tutte.isEmpty else { return "L'archivio delle cose e' vuoto: dimmi \u{00ab}salva il link di X \u{2026}\u{00bb}." }
            return tutte.map { "\($0.etichetta) = \($0.valore)" }.joined(separator: "\n")
        case "togli":
            var lista = Cose.tutte(forza: true)
            let chiave = Memory.senzaAccenti(a("etichetta"))
            let prima = lista.count
            lista.removeAll { Memory.senzaAccenti($0.etichetta) == chiave }
            if lista.count == prima { return "Nessuna cosa con quell'etichetta." }
            return Cose.scrivi(lista) ?? "Tolta \u{00ab}\(a("etichetta"))\u{00bb}."
        default:
            return "Azioni: salva (etichetta+valore), ritrova (etichetta), lista, togli (etichetta)."
        }
    }
}
