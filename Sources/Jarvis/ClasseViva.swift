import Foundation
import AppKit

/// Compiti letti da ClasseViva senza toccare nessuna credenziale.
///
/// La pagina resta quella gia' aperta nel browser dell'utente (dove e' gia' loggato):
/// Jarvis apre l'indirizzo salvato, aspetta che carichi, fa uno screenshot e lo fa
/// leggere al modello visivo in locale. Niente password, niente cookie, niente
/// accesso ai dati di Chrome (che macOS protegge comunque).
///
/// L'indirizzo si salva una volta sola: `compiti_da_classeviva ricorda_pagina`
/// lo legge dalla barra degli indirizzi dello schermo.
enum ClasseViva {
    static var urlFile: URL { AppPaths.jarvisRoot.appendingPathComponent("classeviva.txt") }

    /// L'indirizzo pubblico del registro: se l'utente non ha salvato il suo si parte
    /// da qui, perche' "dammi l'indirizzo" come risposta era la cosa che lo infastidiva.
    static let indirizzoDiDefault = "https://www.classeviva.it"

    static var pagina: String {
        let salvato = ((try? String(contentsOf: urlFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return salvato.isEmpty ? indirizzoDiDefault : salvato
    }

    static func salvaPagina(_ raw: String) -> String {
        var u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.hasPrefix("http://") || u.hasPrefix("https://") else {
            return "Non mi sembra un indirizzo web: deve iniziare con https://"
        }
        // l'indirizzo letto dallo schermo a volte porta pezzi di interfaccia appiccicati
        if let taglio = u.firstIndex(where: { $0 == " " || $0 == "\n" }) { u = String(u[..<taglio]) }
        do { try u.write(to: urlFile, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a salvare l'indirizzo: \(error.localizedDescription)" }
        return "Pagina dei compiti salvata in ~/.jarvis/classeviva.txt: \(u)"
    }

    /// Legge l'URL dalla barra degli indirizzi: serve per non farglielo copiare a mano.
    static func urlDalloSchermo() async -> String {
        guard await Brain.shared.visionModel() != nil else {
            return "Per leggere l'indirizzo dallo schermo serve un modello visivo (qwen2.5vl)."
        }
        let f = AppPaths.tmp.appendingPathComponent("cv-url-\(Int(Date().timeIntervalSince1970)).png")
        _ = await Shell.run("/usr/sbin/screencapture", ["-x", f.path])
        guard FileManager.default.fileExists(atPath: f.path) else {
            return "Non riesco a guardare lo schermo: dai il permesso di Registrazione schermo a \(Marca.nome)."
        }
        let visto = await Brain.shared.askVision(image: f, prompt: """
            Guarda la barra degli indirizzi del browser in alto nella schermata.
            Scrivi SOLO l'indirizzo web completo che si vede, senza spiegazioni.
            Se non c'e' nessun browser con la barra degli indirizzi visibile, scrivi NONE.
            """)
        try? FileManager.default.removeItem(at: f)
        let trovato = visto.split(whereSeparator: { " \n\t\"".contains($0) })
            .first(where: { $0.lowercased().hasPrefix("http") }).map(String.init) ?? ""
        guard !trovato.isEmpty else {
            return "Nella schermata non ho visto una barra degli indirizzi: apri la pagina dei compiti e riprova."
        }
        return salvaPagina(trovato)
    }

    /// Apre la pagina salvata (o quella data), aspetta il caricamento e legge i compiti.
    static func leggiCompiti(url raw: String) async -> String {
        let indirizzo = raw.isEmpty ? pagina : raw
        guard indirizzo.hasPrefix("http") else {
            return "L'indirizzo di ClasseViva non e' valido: \(indirizzo.prefix(60))."
        }
        if !raw.isEmpty { _ = salvaPagina(raw) }
        guard let u = URL(string: indirizzo) else { return "L'indirizzo salvato non e' valido: \(indirizzo)" }
        _ = u
        // il browser e' gia' loggato: si apre la pagina e si aspetta che carichi.
        // Lo schermo dell'utente va pero' restituito appena preso lo screenshot (regola
        // data il 2026-10-20): la pagina deve vedersi il tempo di scattarla, non restare
        // lui bloccato dietro a Chrome mentre il modello ci ragiona sopra 30 secondi.
        let schermoPrima = Silenzio.frontale()
        _ = await Shell.run("/usr/bin/open", [indirizzo])
        try? await Task.sleep(nanoseconds: 7_000_000_000)

        guard await Brain.shared.visionModel() != nil else {
            return "Ho aperto la pagina, ma per leggerla serve il modello visivo qwen2.5vl."
        }
        let f = AppPaths.tmp.appendingPathComponent("cv-compiti-\(Int(Date().timeIntervalSince1970)).png")
        _ = await Shell.run("/usr/sbin/screencapture", ["-x", f.path])
        Silenzio.rimettiAPosto(davanti: schermoPrima)
        guard FileManager.default.fileExists(atPath: f.path) else {
            return "Lo screenshot non e' partito: senza Registrazione schermo non posso leggere ClasseViva."
        }
        let visto = await Brain.shared.askVision(image: f, prompt: """
            Nello schermo c'e' il registro elettronico ClasseViva con l'elenco dei compiti assegnati.
            Scrivi SOLO i compiti, uno per riga, cosi':
            AAAA-MM-GG · materia · cosa deve fare
            Se la data e' tipo "21/10" scrivila come 2026-10-21. Se non c'e' data usa 0000-00-00.
            Massimo 12 righe. Se nella pagina non ci sono compiti, scrivi solo NONE.
            Non aggiungere commenti.
            """)
        try? FileManager.default.removeItem(at: f)
        return incassa(visto)
    }

    /// Converte quello che dice il modello visivo in righe di ~/.jarvis/compiti.md
    static func incassa(_ visto: String) -> String {
        let pulito = visto
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "|", with: "·")
        var aggiunti = 0
        var saltate: [String] = []
        for riga in pulito.components(separatedBy: .newlines) {
            let t = riga.trimmingCharacters(in: .whitespaces)
            guard t.count > 6, !t.uppercased().hasPrefix("NONE") else { continue }
            let parti = t.components(separatedBy: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parti.count >= 3 else {
                if !parti.isEmpty { saltate.append(t) }
                continue
            }
            let scadenza = parti[0].hasPrefix("0000") ? "" : parti[0]
            let esito = Compiti.aggiungi(materia: parti[1], cosa: parti[2...].joined(separator: " · "),
                                         scadenza: scadenza, pagina: pagina)
            if esito.contains("Aggiunto") { aggiunti += 1 }
        }
        guard aggiunti > 0 else {
            let dettaglio = visto.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Non ho riconosciuto compiti nella pagina. Quello che si vedeva: \(dettaglio.prefix(320))"
        }
        var risposta = "Ho letto \(aggiunti) compiti da ClasseViva e li ho messi in ~/.jarvis/compiti.md."
        if !saltate.isEmpty { risposta += " \(saltate.count) righe erano scritte male e le ho lasciate stare." }
        return risposta + "\n" + Compiti.lista()
    }
}

extension Tools {
    /// `compiti_da_classeviva`: legge i compiti dalla pagina gia' loggata nel browser.
    static func classevivaSkill(_ args: [String: Any]) async -> String {
        let azione = (args["azione"] as? String) ?? "leggi"
        let url = (args["url"] as? String) ?? ""
        switch azione {
        case "leggi":
            return await ClasseViva.leggiCompiti(url: url)
        case "ricorda_pagina":
            return url.isEmpty ? await ClasseViva.urlDalloSchermo() : ClasseViva.salvaPagina(url)
        case "stato":
            let p = ClasseViva.pagina
            return p.isEmpty
                ? "Pagina di ClasseViva non ancora salvata. Aprila nel browser e dimmi «ricorda la pagina dei compiti»."
                : "La pagina dei compiti e' \(p). Dì «leggi i compiti da classeviva» per aggiornare la lista."
        default:
            return "Azioni: leggi, ricorda_pagina, stato."
        }
    }
}
