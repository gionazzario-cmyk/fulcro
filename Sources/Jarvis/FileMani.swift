import Foundation

/// Le mani sui file: leggere, scrivere, e provare a eseguire quello che ha scritto.
///
/// Il buco che ha fatto arrabbiare l'utente: gli si e' chiesto di "scrivere un
/// programma e eseguirlo", e lui non aveva nessuno strumento per farlo — ha chiamato
/// `fucina` (che serve solo a modificare il codice di Jarvis) tre volte a vuoto.
///
/// Regole (le stesse del cancello della shell, decise da lui il 2026-10-17):
/// - mai toccare l'archivio di Matteo, `.ssh`, il portachiavi, i permessi TCC, /System,
///   /usr, /bin, /etc;
/// - dentro le sue cartelle di lavoro si scrive subito, e la versione vecchia finisce
///   in backup prima di venire sovrascritta;
/// - fuori da quelle cartelle serve il suo clic.
enum FileMani {
    /// Cartelle dove si scrive senza chiedere niente.
    static let zoneScritturaDiretta = [
        AppPaths.jarvisRoot.path,
        (NSHomeDirectory() as NSString).appendingPathComponent("programmi"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents"),
        (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
        (NSHomeDirectory() as NSString).appendingPathComponent("salute-pi")
    ]

    /// File che non si leggono ad alta voce, nemmeno se chiesto. Non e' prudenza
    /// eccessiva: il testo che legge finisce nella risposta, e con il cervello sul
    /// cloud la risposta (e la storia) passa da Google. `leggi_file` senza questo
    /// filtro poteva restituire `~/.jarvis/gemini.txt`, cioe' la chiave API.
    static let daNonLeggere = ["gemini.txt", "bambu.conf", "bambu-cert.txt", "webpin",
                               "codice-app.txt", "numero.txt", "contatti.txt",
                               "/.ssh", "keychain", "id_rsa", ".env"]

    /// Pezzi di percorso che non si toccano mai, nemmeno con il clic.
    static let zoneVietate = ["matteo", "/.ssh", "/Library/Keychains", "com.apple.TCC",
                              "/System", "/usr/", "/bin/", "/sbin/", "/private/etc", "/Library/Application Support/Apple"]

    static func espandi(_ percorso: String) -> String {
        let t = percorso.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("~/") { return NSHomeDirectory() + String(t.dropFirst(1)) }
        if t == "~" { return NSHomeDirectory() }
        return t
    }

    enum Verdetto { case ok, chiediClic, vietato(String) }

    static func giudica(percorso: String) -> Verdetto {
        let p = percorso.lowercased()
        for vietata in zoneVietate where p.contains(vietata) {
            return .vietato("Quel percorso e' fuori dalla portata di \(Marca.nome) (\(vietata)): sudo, portachiavi, \n"
                + "la cartella di Matteo e i permessi di sistema non si toccano.")
        }
        if zoneScritturaDiretta.contains(where: { percorso.hasPrefix($0) }) { return .ok }
        // in casa ma fuori dalle zone di lavoro: un clic, poi si fa
        if percorso.hasPrefix(NSHomeDirectory()) { return .chiediClic }
        return .vietato("Fuori dalla tua cartella utente non scrivo.")
    }

    /// Scrive il file (con backup di quello vecchio) e, se chiesto, lo esegue.
    static func scrivi(percorso: String, contenuto: String, eseguire: Bool) async -> String {
        let assoluto = espandi(percorso)
        guard !assoluto.isEmpty, !contenuto.isEmpty else { return "Dimmi percorso e contenuto del file." }
        switch giudica(percorso: assoluto) {
        case .vietato(let perche):
            return perche
        case .chiediClic:
            let ok = await Tools.confirm?("Scrivere in \(assoluto)?") ?? false
            if !ok { return "\(Identita.nome) ha detto di no: non ho scritto niente." }
        case .ok:
            // Eseguire non e' scrivere. Il contenuto puo' arrivare da una pagina web
            // letta un attimo prima: senza questo clic, un testo di terzi diventa
            // codice eseguito sul Mac, che e' la definizione di prompt injection.
            if eseguire {
                let ok = await Tools.confirm?("Scrivere ed eseguire \(assoluto)?") ?? false
                if !ok { return "\(Identita.nome) ha detto di no: non ho scritto ne' eseguito niente." }
            }
        }
        let url = URL(fileURLWithPath: assoluto)
        let fm = FileManager.default
        var rigaBackup = ""
        if fm.fileExists(atPath: assoluto) {
            let cartella = AppPaths.jarvisRoot.appendingPathComponent("backup-file")
            try? fm.createDirectory(at: cartella, withIntermediateDirectories: true)
            let nome = "\(url.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.isEmpty ? "txt" : url.pathExtension)"
            do {
                try fm.copyItem(at: url, to: cartella.appendingPathComponent(nome))
                rigaBackup = " (la versione vecchia e' in \(nome))"
            } catch {
                return "Non sono riuscito a mettere in sicurezza il file esistente: \(error.localizedDescription)"
            }
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contenuto.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return "Scrittura fallita: \(error.localizedDescription)"
        }
        guard eseguire else {
            return "Scritto \(assoluto) (\(contenuto.count) caratteri)\(rigaBackup). Dimmi \u{00ab}eseguilo\u{00bb} se vuoi che lo faccia girare."
        }
        let esito = await esegui(url: url, contenuto: contenuto)
        return "Scritto \(assoluto)\(rigaBackup)\n" + esito
    }

    /// Esegue con l'interprete giusto in base all'estensione.
    static func esegui(url: URL, contenuto: String) async -> String {
        let est = url.pathExtension.lowercased()
        let bin: String, extra: [String]
        switch est {
        case "swift": (bin, extra) = ("/usr/bin/swift", [])
        case "py": (bin, extra) = ("/usr/bin/python3", [])
        case "sh", "zsh": (bin, extra) = ("/bin/zsh", [])
        case "js", "mjs": (bin, extra) = ("/usr/local/bin/node", [])
        default:
            // un file senza estensione non si puo' eseguire: lo si dice, non si inventa
            return "\u{00ab}\(est.isEmpty ? "senza estensione" : est)\u{00bb} non e' un formato che so eseguire. Gli unici che eseguo sono swift, py, sh, js."
        }
        if !FileManager.default.fileExists(atPath: bin) {
            return "Non trovo \(bin): senza interprete non posso eseguire."
        }
        // .sh/.zsh hanno bisogno del permesso di esecuzione
        if est == "sh" || est == "zsh" {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let out = await Shell.run(bin, extra + [url.path], timeout: 45)
        let pulito = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if pulito.isEmpty { return "Eseguito: nessun output (codice 0 se non vedi errori)." }
        return "Output reale:\n" + String(pulito.prefix(1600))
    }

    static func leggi(percorso: String, maxRighe: Int = 200) -> String {
        let assoluto = espandi(percorso)
        if let vietata = daNonLeggere.first(where: { assoluto.lowercased().contains($0) }) {
            return "\(assoluto) contiene una chiave o un dato personale (\(vietata)): non lo leggo ad alta voce. "
                + "Aprilo tu, o dimmi un altro file."
        }
        guard FileManager.default.fileExists(atPath: assoluto) else {
            return "Non esiste \(assoluto)."
        }
        guard let testo = try? String(contentsOfFile: assoluto, encoding: .utf8) else {
            return "\(assoluto) non e' un file di testo."
        }
        let righe = testo.components(separatedBy: "\n")
        let prese = righe.prefix(max(1, min(maxRighe, 800)))
        let troncato = righe.count > prese.count ? "\n…(\(righe.count - prese.count) righe in piu')" : ""
        return prese.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n") + troncato
    }
}

extension Tools {
    static func scriviFileSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        return await FileMani.scrivi(percorso: a("percorso"), contenuto: a("contenuto"),
                                     eseguire: a("esegui") == "si")
    }

    static func leggiFileSkill(_ args: [String: Any]) -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        return FileMani.leggi(percorso: a("percorso"), maxRighe: Int(a("righe")) ?? 200)
    }
}
