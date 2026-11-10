import Foundation
import AppKit

/// Il buongiorno delle 7:30.
///
/// Non e' `Giornata.punto()`: quella e' una radiografia del mondo (F1, Raspberry,
/// spazio su disco) che va bene quando la chiedi. Qui serve la cosa che guardi
/// mentre ti vesti, quindi quattro righe: compiti, scuola, impegni, meteo.
///
/// Gira anche ad app chiusa: il LaunchAgent lancia `Jarvis --briefing`, che calcola,
/// salva in `~/.jarvis/buongiorno.json` e manda una notifica. Quando riapri Jarvis,
/// il testo e' gia' nella chat — cosi' non devi ricordarti di chiederlo.
enum Buongiorno {
    struct Contenuto: Codable {
        var giorno: String      // "2026-11-02"
        var testo: String
        var visto: Bool
    }

    static var file: URL { AppPaths.jarvisRoot.appendingPathComponent("buongiorno.json") }

    static func chiaveGiorno(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Quattro righe, ognuna indipendente: se una non si puo' leggere, lo dice e
    /// le altre tre arrivano lo stesso. Scritte con i dati veri, non con le prime
    /// righe grezze degli strumenti (la prima versione stampava
    /// "Compiti: 24 compiti da fare: · 1. Tecnologia: Leggere…", illeggibile).
    @MainActor static func calcola() async -> String {
        var fuori: [String] = []

        // 1. compiti: quanti per oggi, quanti in ritardo, il primo da fare
        let aperti = Compiti.leggi(tutti: true).filter { !$0.fatto }
        let oggi = aperti.filter { (Suggerimenti.giorniDaOggi($0.scadenza) ?? 99) <= 0 }
        let ritardo = aperti.filter { (Suggerimenti.giorniDaOggi($0.scadenza) ?? 0) < 0 }
        if aperti.isEmpty {
            fuori.append("Compiti: niente in lista")
        } else if oggi.isEmpty {
            fuori.append("Compiti: nessuno per oggi · \(aperti.count) in lista")
        } else {
            var riga = "Compiti: \(oggi.count) per oggi"
            if !ritardo.isEmpty { riga += " · \(ritardo.count) in ritardo" }
            if let primo = oggi.first(where: { !$0.cosa.isEmpty }) {
                riga += "\n\(primo.materia): \(String(primo.cosa.prefix(90)))"
            }
            fuori.append(riga)
        }

        // 2. scuola: solo se l'orario dice qualcosa di vero
        let orario = await Tools.shared.run("leggi_orario", ["giorno": "oggi"])
        let rigaOrario = orario.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count > 5
                     && !$0.hasPrefix("#")
                     && !$0.lowercased().contains("nessuna materia")
                     && !$0.lowercased().contains("orario scolastico")
                     && !$0.lowercased().hasPrefix("contenuto") } ?? ""
        if !rigaOrario.isEmpty { fuori.append("Scuola: " + String(rigaOrario.prefix(160))) }

        // 3. impegni
        let inizio = Calendar.current.startOfDay(for: Date())
        let fine = Calendar.current.date(byAdding: .day, value: 1, to: inizio) ?? Date()
        let impegni = await Agenda.impegni(da: inizio, a: fine)
        if Agenda.permessoNegato {
            fuori.append("Impegni: il calendario non e' autorizzato")
        } else if impegni.isEmpty {
            fuori.append("Impegni: giornata libera")
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "HH:mm"
            fuori.append("Impegni: " + impegni.prefix(3)
                .map { "\(f.string(from: $0.inizio)) \($0.titolo)" }
                .joined(separator: " · "))
        }

        // 4. meteo: la prima frase, non tutto il bollettino
        let meteo = await Tools.shared.run("meteo", Identita.citta.map { ["citta": $0] } ?? [:])
        let primaFrase = meteo.components(separatedBy: CharacterSet(charactersIn: ".\n")).first ?? meteo
        // "Meteo a <città>: 3°C..." -> "3°C..." (l'etichetta la mettiamo noi)
        let senzaEtichetta = primaFrase.range(of: "Meteo a ").map { _ in
            primaFrase.split(separator: ":", maxSplits: 1).last.map(String.init) ?? primaFrase
        } ?? primaFrase
        let pulita = senzaEtichetta.trimmingCharacters(in: .whitespaces)
        if !pulita.isEmpty { fuori.append("Meteo: " + String(pulita.prefix(120))) }

        return fuori.joined(separator: "\n")
    }

    static func salva(_ testo: String) {
        let contenuto = Contenuto(giorno: chiaveGiorno(), testo: testo, visto: false)
        guard let dati = try? JSONEncoder().encode(contenuto) else { return }
        try? dati.write(to: file, options: .atomic)
    }

    /// Il testo di oggi, se non e' ancora stato mostrato nella chat.
    static func daMostrare() -> String? {
        guard let dati = try? Data(contentsOf: file),
              let c = try? JSONDecoder().decode(Contenuto.self, from: dati),
              c.giorno == chiaveGiorno(), !c.visto, !c.testo.isEmpty else { return nil }
        return c.testo
    }

    static func segnaVisto() {
        guard let dati = try? Data(contentsOf: file),
              var c = try? JSONDecoder().decode(Contenuto.self, from: dati) else { return }
        c.visto = true
        guard let fuori = try? JSONEncoder().encode(c) else { return }
        try? fuori.write(to: file, options: .atomic)
    }

    /// La notifica: la manda `osascript`, che funziona anche da un processo senza
    /// interfaccia (il caso del LaunchAgent). Il corpo resta corto di proposito:
    /// macOS ne mostra due righe, e il testo intero e' nella chat.
    static func notifica(_ testo: String) {
        let pezzi = testo.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { riga -> String in
                guard let i = riga.firstIndex(of: ":") else { return riga }
                return riga[riga.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let corpo = String(pezzi.prefix(2).joined(separator: " · ").prefix(180))
            .replacingOccurrences(of: "\"", with: "'")
        let script = "display notification \"\(corpo)\" with title \"\(Marca.nome) · buongiorno\" sound name \"Glass\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run(); p.waitUntilExit() } catch { NSLog("\(Marca.nome) buongiorno: notifica fallita") }
    }
}
