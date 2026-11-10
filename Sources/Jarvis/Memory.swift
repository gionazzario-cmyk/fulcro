import Foundation

/// Gestisce la memoria persistente di Jarvis (profilo utente e orario scolastico).
/// I dati restano su disco in ~/.jarvis/ anche dopo il riavvio.
enum Memory {
    static var profilePath: URL {
        AppPaths.jarvisRoot.appendingPathComponent("profilo.md")
    }

    static var schedulePath: URL {
        AppPaths.jarvisRoot.appendingPathComponent("orario.md")
    }

    /// Legge il profilo persistente dell'utente.
    static func readProfile() -> String {
        if !FileManager.default.fileExists(atPath: profilePath.path) {
            // Nasce VUOTO: chi installa Jarvis non eredita la memoria di nessuno,
            // la costruisce da sé (a voce, o scrivendo qui a mano).
            let initial = """
            # Profilo
            - (nessuna informazione ancora: Jarvis scrive qui quello che impara)
            """
            try? initial.write(to: profilePath, atomically: true, encoding: .utf8)
            return initial
        }
        return (try? String(contentsOf: profilePath, encoding: .utf8)) ?? ""
    }

    /// Aggiunge un fatto o preferenza in memoria persistente.
    static func appendFact(_ fact: String) -> String {
        var clean = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Nessun fatto fornito." }
        // Il profilo viene letto a OGNI domanda: una riga da 400 parole (ci e' finita
        // il 2026-10-19 con la prova di stress) rallenta Jarvis per sempre.
        if clean.count > 220 { clean = String(clean.prefix(220)) }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        let parole = clean.components(separatedBy: " ").filter { !$0.isEmpty }
        if parole.count >= 6 {
            let distinte = Set(parole.map { Memory.senzaAccenti($0) }).count
            if distinte <= 3 {
                return "Non l'ho salvato: sembra una ripetizione senza senso."
            }
        }
        // una congiunzione finale non e' parte del fatto: "... http://x/ e" -> "... http://x/"
        if let ultima = parole.last {
            let coda = [" e", " ed", " poi", " a", " di", " che", " il"]
            if let taglio = coda.first(where: { clean.lowercased().hasSuffix($0) }) {
                clean = String(clean.dropLast(taglio.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let current = readProfile()
        // Il profilo finisce nel prompt a ogni domanda: se cresce senza freno,
        // Jarvis rallenta e basta. Niente duplicati, e si tiene solo il piu' recente.
        let righe = current.components(separatedBy: .newlines)
        if righe.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "- \(clean)" }) {
            return "Era gia' scritto nel profilo: «\(clean)»"
        }
        let corpo = righe.filter { !$0.hasPrefix("- ") }
        var punti = righe.filter { $0.hasPrefix("- ") }
        punti.append("- \(clean)")
        let maxPunti = 30
        let scarto = punti.count > maxPunti ? punti.count - maxPunti : 0
        let tenuti = Array(punti.dropFirst(scarto))
        let nuovo = (corpo + tenuti).joined(separator: "\n")
        do { try nuovo.write(to: profilePath, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a salvare: \(error.localizedDescription)" }
        return scarto > 0 ? "Ho memorizzato: «\(clean)» (e ho scaricato \(scarto) vecchie)"
                          : "Ho memorizzato: «\(clean)»"
    }

    /// Butta via le righe di prova che sono ripetizioni senza senso: restano nel
    /// profilo a ogni suite se non si puliscono, e il profilo si legge sempre.
    @discardableResult
    static func pulisciSpazzatura() -> Int {
        let current = readProfile()
        var tenute: [String] = [], tolte = 0
        for r in current.components(separatedBy: .newlines) {
            let parole = r.components(separatedBy: " ").filter { !$0.isEmpty }
            if parole.count >= 6 && Set(parole.map { senzaAccenti($0) }).count <= 3 { tolte += 1; continue }
            tenute.append(r)
        }
        if tolte > 0 { try? tenute.joined(separator: "\n").write(to: profilePath, atomically: true, encoding: .utf8) }
        return tolte
    }

    /// Toglie una riga di prova dal profilo.
    static func rimuovi(_ fatto: String) {
        let current = readProfile()
        let tenuto = current.components(separatedBy: .newlines)
            .filter { !$0.contains(fatto) }
            .joined(separator: "\n")
        try? tenuto.write(to: profilePath, atomically: true, encoding: .utf8)
    }

    /// Legge l'orario delle materie per un giorno specifico (o domani di default).
    static func readSchedule(day: String = "") -> String {
        guard FileManager.default.fileExists(atPath: schedulePath.path),
              let content = try? String(contentsOf: schedulePath, encoding: .utf8) else {
            return "Orario non trovato in ~/.jarvis/orario.md. Digli di crearlo se serve."
        }

        let targetDay: String
        if !day.trimmingCharacters(in: .whitespaces).isEmpty {
            targetDay = day.lowercased().trimmingCharacters(in: .whitespaces)
        } else {
            let cal = Calendar.current
            let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "EEEE"
            targetDay = f.string(from: tomorrow).lowercased()
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "lunedi" nel file e "lunedì" dal Mac: senza questo confronto l'orario non si legge
            if Self.senzaAccenti(trimmed).hasPrefix(Self.senzaAccenti(targetDay) + ":") {
                let parts = trimmed.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    let materie = parts[1].trimmingCharacters(in: .whitespaces)
                    return "Materie di \(targetDay): \(materie)"
                }
            }
        }
        return "Nessuna materia registrata per \(targetDay) in ~/.jarvis/orario.md.\nContenuto completo:\n\(content)"
    }

    /// Toglie gli accenti: serve per confrontare i giorni scritti a mano.
    static func senzaAccenti(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
