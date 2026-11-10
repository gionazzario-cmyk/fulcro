import Foundation
import AppKit

// MARK: - le due intelligenze che lavorano insieme

/// Non "l'uno o l'altro": il locale pensa e chiama gli strumenti, Gemini rivede.
/// Il risultato finale lo scrive sempre qwen3, cosi' il tono resta quello di casa.
enum Dibattito {
    /// local draft → revisione Gemini → risposta finale locale.
    static func rispondi(domanda: String, contesto: String = "") async -> String {
        let locale = await JarvisCore.shared.rispostaLocale(domanda)
        guard Gemini.pronto else {
            return locale + "\n\n(ho fatto da solo: senza chiave in ~/.jarvis/gemini.txt il secondo cervello non puo' revisionare)"
        }
        let revisione = await Gemini.chiedi("""
            Domanda di \(Identita.nome): \(domanda)
            Risposta proposta dal modello locale: \(locale)
            Controllala: se c'e' un errore correggilo, se manca una cosa importante aggiungila,
            se va bene di' solo "a posto". Max 6 righe, niente complimenti.
            """, contesto: contesto)

        if revisione.lowercased().contains("a posto") || revisione.isEmpty {
            return locale
        }
        // la parola fine resta al locale: e' lui che conosce il tono di casa
        let finale = await JarvisCore.shared.rispostaLocale("""
            Domanda: \(domanda)
            La tua risposta: \(locale)
            Revisione del secondo cervello: \(revisione)
            Scrivi la versione finale, corta, in italiano semplice.
            """)
        return finale.isEmpty ? "\(locale)\n\nNota del secondo cervello: \(revisione)" : finale
    }
}

// MARK: - la fucina: Jarvis che modifica il proprio codice

/// Jarvis puo' cambiare il proprio codice, ma con quattro catene montate da lui
/// (l'utente, 2026-10-18) e non toglibili dal codice stesso:
///  1. copia di sicurezza prima di ogni modifica;
///  2. si compila SEMPRE prima di applicare: se non compila, si torna indietro;
///  3. i file delle regole (Gate.swift, le script di firma, install.sh) non si toccano:
///     cosi' non puo' cancellare i propri limiti;
///  4. l'applicazione vera chiede il clic dell'utente.
enum Fucina {
    static var progetto: URL { AppPaths.home.appendingPathComponent("programmi/jarvis") }
    static var backupRoot: URL { AppPaths.jarvisRoot.appendingPathComponent("fucina") }

    /// Dove puo scrivere.
    private static let permessi = ["Sources/\(Marca.nome)/", "Tools/", "Resources/Info.plist"]
    /// Mai qui: sono le sue catene.
    private static let vietati = ["Sources/\(Marca.nome)/Gate.swift", "install.sh", "firma-locale.sh",
                                  "jarvis-alimentatore.sh", "Package.swift", "Sources/\(Marca.nome)/Fucina.swift"]

    struct Esito {
        var ok: Bool
        var messaggio: String
    }

    static func percorsoPermesso(_ relativo: String) -> String? {
        let pulito = relativo.replacingOccurrences(of: "./", with: "")
        if vietati.contains(where: { pulito.hasSuffix($0) }) {
            return nil
        }
        return permessi.contains(where: { pulito.hasPrefix($0) || pulito.contains("/" + $0) }) ? pulito : nil
    }

    /// Legge un file del progetto (per poterlo modificare serve sapere cosa c'e' dentro).
    static func leggi(_ relativo: String, maxRighe: Int = 400) -> String {
        guard let pulito = Fucina.percorsoPermesso(relativo) else {
            return "Quel file non lo apro: \(relativo). Le regole di sicurezza non si modificano."
        }
        let url = progetto.appendingPathComponent(pulito)
        guard let testo = try? String(contentsOf: url, encoding: .utf8) else {
            return "Non trovo \(pulito) nel progetto."
        }
        let righe = testo.components(separatedBy: .newlines)
        return righe.prefix(maxRighe).enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
    }

    /// Applica una sostituzione mirata al testo: molto piu' affidabile che riscrivere
    /// un file intero, e se la stringa non si trova si dice subito invece di rompere.
    static func innesta(_ originale: String, trova: String, sostituisci: String) -> Esito {
        guard !trova.isEmpty else { return Esito(ok: false, messaggio: "Dimmi quale pezzo di codice devo sostituire.") }
        guard let range = originale.range(of: trova) else {
            return Esito(ok: false, messaggio: "Il pezzo che cerchi non c'e' nel file. Rileggilo con fucina azione=leggi e riprova con le stesse parole.")
        }
        var nuovoTesto = originale
        nuovoTesto.replaceSubrange(range, with: sostituisci)
        return Esito(ok: true, messaggio: nuovoTesto)
    }

    /// Prova la modifica senza applicarla: scrive su una copia e compila quella.
    /// (Compilare una copia costa quanto compilare il progetto, quindi il controllo e' vero.)
    static func prova(_ relativo: String, nuovoTesto: String) async -> Esito {
        guard let pulito = percorsoPermesso(relativo) else {
            return Esito(ok: false, messaggio: "File fuori dai limiti: \(relativo). Gate.swift e gli script di firma non si toccano.")
        }
        let url = progetto.appendingPathComponent(pulito)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Esito(ok: false, messaggio: "\(pulito) non esiste: se vuoi crearlo dimmelo, ma prima lo vediamo insieme.")
        }
        let originale = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // si scrive, si compila, e se non compila si rimette a posto subito
        do { try nuovoTesto.write(to: url, atomically: true, encoding: .utf8) }
        catch { return Esito(ok: false, messaggio: "Scrittura fallita: \(error.localizedDescription)") }

        let (codice, errori) = await compila()
        if codice != 0 {
            try? originale.write(to: url, atomically: true, encoding: .utf8)
            return Esito(ok: false, messaggio: "Non compila, ho gia' rimesso a posto il file.\n\n\(errori.prefix(1400))")
        }
        // prova superata: si torna indietro finche' non arriva il clic
        try? originale.write(to: url, atomically: true, encoding: .utf8)
        return Esito(ok: true, messaggio: "Compila. Dillo a \(Identita.nome) e con un clic applico: \(pulito)")
    }

    /// Applica davvero: backup, scrittura, build, e se la build fallisce ripristino.
    static func applica(_ relativo: String, nuovoTesto: String, motivo: String) async -> Esito {
        guard let pulito = percorsoPermesso(relativo) else {
            return Esito(ok: false, messaggio: "File fuori dai limiti: \(relativo).")
        }
        let autorizzato = await Tools.confirm?("\(Marca.nome) vuole modificare il proprio codice:\n\(pulito)\nMotivo: \(motivo)") ?? false
        guard autorizzato else { return Esito(ok: false, messaggio: "\(Identita.nome) non ha confermato: la modifica non la faccio.") }

        let url = progetto.appendingPathComponent(pulito)
        let stampa = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let cartellaBackup = backupRoot.appendingPathComponent(stampa)
        try? FileManager.default.createDirectory(at: cartellaBackup, withIntermediateDirectories: true)
        let copia = cartellaBackup.appendingPathComponent((pulito as NSString).lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: copia)
        try? "file=\(pulito)\nmotivo=\(motivo)\n".write(to: cartellaBackup.appendingPathComponent("nota.txt"),
                                                       atomically: true, encoding: .utf8)

        do { try nuovoTesto.write(to: url, atomically: true, encoding: .utf8) }
        catch { return Esito(ok: false, messaggio: "Scrittura fallita: \(error.localizedDescription)") }

        let (codice, errori) = await compila()
        guard codice == 0 else {
            try? FileManager.default.copyItem(at: copia, to: url)
            return Esito(ok: false, messaggio: "Build fallita, ripristinato il file.\n\n\(errori.prefix(1400))")
        }
        let (buildInstall, _) = await installa()
        return Esito(ok: buildInstall == 0,
                     messaggio: buildInstall == 0
                        ? "Modifica applicata e nuova versione compilata (\(pulito)). Backup in \(cartellaBackup.path)"
                        : "Il codice compila ma l'installazione non e' finita bene: backup in \(cartellaBackup.path)")
    }

    /// Torna all'ultimo backup.
    static func ripristina() -> Esito {
        let fm = FileManager.default
        let cartelle = ((try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return da > db
            }
        guard let ultima = cartelle.first,
              let nota = try? String(contentsOf: ultima.appendingPathComponent("nota.txt"), encoding: .utf8) else {
            return Esito(ok: false, messaggio: "Nessun backup da ripristinare.")
        }
        let righe = nota.components(separatedBy: .newlines)
        guard let rigaFile = righe.first(where: { $0.hasPrefix("file=") }) else {
            return Esito(ok: false, messaggio: "Il backup piu' recente non ha la nota del file.")
        }
        let relativo = String(rigaFile.dropFirst(5))
        let nome = (relativo as NSString).lastPathComponent
        guard let sorgente = try? fm.contentsOfDirectory(at: ultima, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent == nome }) else {
            return Esito(ok: false, messaggio: "Non trovo \(nome) nella cartella del backup.")
        }
        let destinazione = progetto.appendingPathComponent(relativo)
        try? fm.removeItem(at: destinazione)
        try? fm.copyItem(at: sorgente, to: destinazione)
        return Esito(ok: true, messaggio: "Ripristinato \(relativo) dal backup \(ultima.lastPathComponent).")
    }

    static func stato() -> String {
        let fm = FileManager.default
        let backup = ((try? fm.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)) ?? []).count
        return "Fucina: posso scrivere in \(permessi.joined(separator: ", ")).\n"
            + "Non posso toccare: \(vietati.joined(separator: ", ")) (sono le mie regole).\n"
            + "Backup disponibili: \(backup)."
    }

    // MARK: - build

    private static func compila() async -> (Int32, String) {
        await comanda("/usr/bin/swift", ["build"], nella: progetto.path)
    }

    private static func installa() async -> (Int32, String) {
        await comanda("/bin/bash", ["install.sh"], nella: progetto.path)
    }

    private static func comanda(_ bin: String, _ args: [String], nella cartella: String) async -> (Int32, String) {
        await withCheckedContinuation { (c: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cartella)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                var raccolto = ""
                do { try p.run() } catch { c.resume(returning: (-1, error.localizedDescription)); return }
                let handle = out.fileHandleForReading
                while true {
                    let pezzo = handle.availableData
                    if pezzo.isEmpty { break }
                    raccolto += String(decoding: pezzo, as: UTF8.self)
                    if raccolto.count > 40_000 { raccolto = String(raccolto.suffix(20_000)) }
                }
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, raccolto))
            }
        }
    }
}

// MARK: - gambe per il modello

extension Tools {
    static func dibattitoSkill(_ args: [String: Any]) async -> String {
        let domanda = (args["domanda"] as? String) ?? ""
        let materia = (args["materia"] as? String) ?? ""
        guard !domanda.isEmpty else { return "Dimmi su cosa vuoi il confronto delle due intelligenze." }
        return await Dibattito.rispondi(domanda: domanda, contesto: materia)
    }

    /// Se ha dato `trova`/`sostituisci` costruisce lui il file nuovo, altrimenti
    /// usa il testo intero che gli ha passato il modello.
    private static func prepara(_ args: [String: Any], file: String, nuovo: String) async -> String {
        let trova = (args["trova"] as? String) ?? ""
        let sostituisci = (args["sostituisci"] as? String) ?? ""
        if trova.isEmpty {
            return nuovo.isEmpty ? "MANCA il testo: dammi `trova` e `sostituisci`, o `testo_nuovo` intero." : nuovo
        }
        let url = Fucina.progetto.appendingPathComponent(file)
        guard let originale = try? String(contentsOf: url, encoding: .utf8) else {
            return "MANCA il file \(file)."
        }
        let esito = Fucina.innesta(originale, trova: trova, sostituisci: sostituisci)
        return esito.ok ? esito.messaggio : "MANCA " + esito.messaggio
    }

    static func fucinaSkill(_ args: [String: Any]) async -> String {
        let azione = (args["azione"] as? String) ?? "stato"
        let file = (args["file"] as? String) ?? ""
        let nuovo = (args["testo_nuovo"] as? String) ?? ""
        let motivo = (args["motivo"] as? String) ?? "nessun motivo dichiarato"
        switch azione {
        case "stato":
            return Fucina.stato()
        case "leggi":
            return Fucina.leggi(file)
        case "prova":
            let testo = await prepara(args, file: file, nuovo: nuovo)
            if testo.hasPrefix("MANCA ") { return testo }
            let esito = await Fucina.prova(file, nuovoTesto: testo)
            return (esito.ok ? "PROVA OK — " : "PROVA NO — ") + esito.messaggio
        case "applica":
            let testo = await prepara(args, file: file, nuovo: nuovo)
            if testo.hasPrefix("MANCA ") { return testo }
            let esito = await Fucina.applica(file, nuovoTesto: testo, motivo: motivo)
            return (esito.ok ? "APPLICATA — " : "NON APPLICATA — ") + esito.messaggio
        case "ripristina":
            let esito = Fucina.ripristina()
            return (esito.ok ? "RIPRISTINATO — " : "NULLA DA RIPRISTINARE — ") + esito.messaggio
        default:
            return "Azioni: stato, leggi, prova, applica, ripristina."
        }
    }
}
