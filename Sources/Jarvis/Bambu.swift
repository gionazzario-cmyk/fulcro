import Foundation

/// La stampante 3D dell'utente: Bambu A1 mini in rete.
///
/// Parla con `Tools/bambu_bridge.py` (MQTT su TLS, porta 8883). Il codice di accesso
/// sta in `~/.jarvis/bambu.conf`, scritto da lui: non passa mai dalla riga di comando
/// e non va mai in chat. Se il file non e' compilato, questo lo dice e basta.
enum Bambu {
    /// L'ultima cosa che la stampante ha detto, in casa: i suggerimenti a schermo la
    /// leggono senza chiamare il MQTT ogni trenta secondi.
    static nonisolated(unsafe) private(set) var ultimoStato = ""

    static var conf: URL { AppPaths.jarvisRoot.appendingPathComponent("bambu.conf") }

    static func pythonDisponibile() -> String? {
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func ponte() -> String? {
        let candidati = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools/bambu_bridge.py").path,
            Fucina.progetto.appendingPathComponent("Tools/bambu_bridge.py").path
        ]
        return candidati.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Cosa manca nel file di configurazione (senza mai mostrare il codice).
    static func statoConfigurazione() -> String {
        guard let testo = try? String(contentsOf: conf, encoding: .utf8) else {
            return "Il file ~/.jarvis/bambu.conf non c'e': aprilo con `open -e -t ~/.jarvis/bambu.conf` dal Terminale."
        }
        func valore(_ chiave: String) -> String {
            let riga = testo.components(separatedBy: .newlines).first {
                $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(chiave)
            } ?? ""
            return riga.components(separatedBy: "=").dropFirst().joined(separator: "=")
                .trimmingCharacters(in: .whitespaces)
        }
        var guai: [String] = []
        for chiave in ["ip", "codice", "seriale"] where valore(chiave).isEmpty {
            guai.append("manca \(chiave)")
        }
        let codice = valore("codice"), seriale = valore("seriale")
        if !codice.isEmpty {
            if !seriale.isEmpty && codice == seriale {
                guai.append("nella riga `codice =` hai ricopiato la seriale: il codice di accesso sono 8 cifre")
            } else if !codice.allSatisfy({ $0.isLetter || $0.isNumber }) || codice.count != 8 {
                guai.append("`codice =` sono \(codice.count) caratteri, il codice di accesso sono 8 "
                    + "(quello lungo e' la chiave API di Bambu Studio, non serve qui)")
            }
        }
        if seriale.isEmpty {
            guai.append("`seriale =` e' vuota: e' il numero SN, 15 caratteri, etichetta dietro la stampante "
                + "o in Bambu Studio -> Devices -> dettaglio")
        }
        if !ipValido(valore("ip")) && !valore("ip").isEmpty {
            guai.append("l'ip non sembra un indirizzo (\(valore("ip")))")
        }
        guard guai.isEmpty else {
            return "NON COLLEGATO: " + guai.joined(separator: "; ")
                + ". Dove si prende: etichetta grigia dietro la A1 mini (vicino al QR e alla "
                + "password del WiFi), oppure Bambu Handy -> stampante -> ingranaggio -> Access code. "
                + "Si sistema con: open -e -t ~/.jarvis/bambu.conf"
        }
        return "Configurazione completa (ip, codice, seriale)."
    }

    /// "192.168.1.47" e basta: se lui ci mette il nome del Mac o uno spazio, meglio dirlo subito.
    static func ipValido(_ s: String) -> Bool {
        s.split(separator: ".").count == 4 && s.split(separator: ".").allSatisfy { $0.allSatisfy { c in c.isNumber } }
    }

    /// Chiama il ponte. `lungo` = sorveglianza, quindi con tempo grande.
    static func esegui(_ modalita: String, minuti: Int = 1) async -> String {
        guard let py = pythonDisponibile(), let ponte = ponte() else {
            return "Non trovo il ponte Python della Bambu (Tools/bambu_bridge.py)."
        }
        let testoConf = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
        if !testoConf.contains("codice") { return statoConfigurazione() }
        let stato = statoConfigurazione()
        if !stato.hasPrefix("Configurazione completa") { return stato }

        var args = [ponte, modalita]
        if modalita == "watch" { args += ["--minuti", String(min(minuti, 240))] }
        // `cerca` batte la rete 192.168.1.x: il router di casa cambia indirizzo alla
        // stampante, e quel giro dura ~2 s in piu' di una connessione secca.
        let limite: TimeInterval = modalita == "watch" ? TimeInterval(minuti * 60 + 45)
            : (modalita == "cerca" ? 70 : 45)
        let outo = await Shell.run(py, args, timeout: limite)
        let pulito = outo.trimmingCharacters(in: .whitespacesAndNewlines)
        if pulito.isEmpty { return "La stampante non ha risposto (spenta, o non e' sulla stessa rete)." }
        if ["stato", "cerca", "watch"].contains(modalita) { Bambu.ultimoStato = pulito }
        return pulito
    }

    /// Sorveglianza in background: avvisa a voce quando la stampa finisce.
    static func sorveglia(minuti: Int) -> String {
        Task.detached(priority: .utility) {
            let outo = await Bambu.esegui("watch", minuti: minuti)
            await MainActor.run {
                let righe = outo.components(separatedBy: .newlines)
                let fine = righe.first { $0.hasPrefix("FINE:") } ?? ""
                let stato = fine.replacingOccurrences(of: "FINE:", with: "")
                if outo.contains("NESSUNA STAMPA IN CORSO") {
                    // gliel'ha chiesto lui: "guarda la stampa" merita una risposta, anche
                    // quando la risposta e' "non c'e' niente da guardare"
                    JarvisCore.shared.dillo("Non c'e' nessuna stampa in corso: la A1 mini e' fredda")
                    JarvisCore.shared.notaSenzaVoce("Sorveglianza stampa: " + outo.prefix(300))
                } else if stato.isEmpty {
                    JarvisCore.shared.notaSenzaVoce("Sorveglianza stampa: " + outo.prefix(300))
                } else {
                    JarvisCore.shared.dillo("La stampa e' " + stato)
                    JarvisCore.shared.notaSenzaVoce("Stampa finita: " + outo.prefix(300))
                }
            }
        }
        return "Guardo la stampante per \(minuti) minuti: ti aviso quando finisce o se sbaglia."
    }
}

extension Tools {
    @MainActor static func bambuSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "stato":
            return await Bambu.esegui("stato")
        case "cerca":
            return await Bambu.esegui("cerca")
        case "test":
            return await Bambu.esegui("test")
        case "watch":
            let m = Int(a("minuti").filter { $0.isNumber }) ?? 90
            return Bambu.sorveglia(minuti: m)
        case "config":
            return Bambu.statoConfigurazione()
        default:
            return "Azioni: stato, cerca (se l'ip e' cambiato), test, watch (con minuti=), config."
        }
    }
}
