import Foundation

/// Gli appunti dell'utente: la parte piu' utile e meno costosa di tutto Jarvis, perche'
/// lui copia gia' tutto il giorno. Copia, dice «spiegamelo», e non deve incollare niente.
///
/// Due regole che vengono prima della comodita':
///
/// - **di default gli appunti non escono dal Mac.** Il testo copiato e' roba sua, e la
///   sua regola e' che contenuto di messaggi/mail/screenshot non va nel cloud: quello che
///   ha negli appunti sta nella stessa categoria. In nuvola ci va **solo** se lui lo
///   chiede con `nuvola=si`, e nemmeno allora se sembra una credenziale.
/// - **se sembra un segreto non lo cito e non lo spedisco.** Niente finestre, niente
///   "ho nascosto la tua password" scritto in chiaro nella chat: si dice che e' stato
///   trattenuto, senza ripetere il contenuto.
enum Appunti {
    /// Testo copiato adesso. `pbpaste` non serve nessun permesso: legge solo gli appunti.
    static func leggi(limite: Int = 4000) async -> String {
        let outo = await Shell.run("/usr/bin/pbpaste", [], timeout: 6)
        return String(outo.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limite))
    }

    /// Parole che fanno pensare a una credenziale, non a un esercizio di fisica.
    static func sembraUnSegreto(_ testo: String) -> Bool {
        let basso = testo.lowercased()
        let indizi = ["password", "pin ", "codice fiscale", "carta di credito", "iban",
                      "token", "api key", "secret key", "private key", "-----begin", "cvv"]
        if indizi.contains(where: { basso.contains($0) }) { return true }
        // una riga lunga senza spazi che sembra un token/base64
        let riga = basso.components(separatedBy: .newlines).first ?? ""
        return riga.count > 24 && riga.split(separator: " ").count == 1
            && riga.allSatisfy { $0.isLetter || $0.isNumber || "+/_-=".contains($0) }
    }

    /// Puzza di percorso di casa: non va scritto in chat ne' mandato fuori.
    static func mascheraPercorsi(_ testo: String) -> String {
        testo.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// La testa del testo, per riconoscere gli appunti nelle prove senza leggere i suoi.
    static func assaggio(_ testo: String) -> String {
        let una = testo.components(separatedBy: .newlines).first ?? ""
        return String(una.prefix(48))
    }
}

extension Tools {
    @MainActor static func appuntiSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in ((args[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        // prima si controlla CHE cosa vuole, poi si legge la clipboard: con gli appunti
        // vuoti e un'azione inventata deve uscire l'elenco delle azioni, non "gli
        // appunti sono vuoti" (preso in suite il 2026-10-20)
        let conosciute = ["leggi", "spiega", "", "traduci", "correggi", "compito"]
        let azione = a("azione").lowercased()
        guard conosciute.contains(azione) else {
            return "Azioni: leggi, spiega, traduci, correggi, compito (tutte prendono il testo dagli appunti; nuvola=si solo se glielo dici)."
        }
        let grezzo = await Appunti.leggi()
        guard !grezzo.isEmpty else { return "Gli appunti sono vuoti: copiami qualcosa (Cmd+C) e riprova." }
        Suggerimenti.segnaAppunti(grezzo)
        let segreto = Appunti.sembraUnSegreto(grezzo)
        let testo = Appunti.mascheraPercorsi(grezzo)
        let assaggio = Appunti.assaggio(testo)

        // Un appuntamento che sembra una credenziale non si tocca con nessuna azione:
        // neppure "correggi" o "traduci", che infatti il 2026-10-20 hanno rimandato la
        // sua password del WiFi scritta per esteso nella chat. E il rifiuto non cita
        // nemmeno un pezzo: la prima riga di un segreto E' il segreto.
        if segreto {
            return "Negli appunti c'e' una cosa che sembra una credenziale (password, codice, carta): "
                + "non la leggo, non la correggo, non la spiego e non la mando da nessuna parte, "
                + "nemmeno al modello locale. Se vuoi che lavori su altro, copiami quel altro."
        }

        // la nuvola: solo se lui la chiede, e mai con una credenziale dentro
        let vuoleNuvola = a("nuvola") == "si"
        func chiedi(_ istruzione: String) async -> String {
            if vuoleNuvola && !segreto && Gemini.pronto {
                return await Gemini.chiedi(istruzione + "\n\nTESTO:\n" + testo)
            }
            return await JarvisCore.shared.rispostaLocale(istruzione + "\n\nTESTO:\n" + testo)
        }

        switch azione {
        case "leggi":
            return "Negli appunti hai: «\(assaggio)」 — \(testo.count) caratteri."

        case "spiega", "":
            let risposta = await chiedi("Spiega a \(Identita.nome) in italiano semplice e corto, max 6 righe. Non ripetere il testo, spiegalo.")
            return risposta.isEmpty ? "Né il locale né il cloud hanno risposto: riprova o dimmi «spiegami \(assaggio)」." : risposta

        case "traduci":
            let risposta = await chiedi("Traduci in italiano, tenendo il senso e niente commenti:")
            return risposta.isEmpty ? "La traduzione non e' arrivata." : risposta

        case "correggi":
            let risposta = await chiedi("Correggi errori di battitura e di grammatica, senza cambiare il tono. Scrivi solo il testo corretto:")
            return risposta.isEmpty ? "La correzione non e' arrivata." : risposta

        case "compito":
            // prima una passata corta per capire materia e scadenza, poi la scrive
            // con la funzione vera: il formato di compiti.md non si inventa.
            let estratto = await chiedi("""
                Dal testo estrai SOLO tre campi, una riga ciascuno, senza altre parole:
                MATERIA: <una parola, o "compiti">
                SCADENZA: <data tipo 2026-10-25, o "domani", o ""> 
                COSA: <cosa deve fare, una riga>
                """)
            func campo(_ nome: String) -> String {
                for riga in estratto.components(separatedBy: .newlines) {
                    if riga.uppercased().hasPrefix(nome) {
                        return String(riga.dropFirst(nome.count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
                    }
                }
                return ""
            }
            let cosa = campo("COSA:")
            guard !cosa.isEmpty else {
                return "Non sono riuscito a capire cosa devi fare da questi appunti (\(assaggio)…): dimmelo a voce e lo segno."
            }
            return Compiti.aggiungi(materia: campo("MATERIA:"), cosa: cosa,
                                    scadenza: campo("SCADENZA:"), pagina: "")
        default:
            return "Azioni: leggi, spiega, traduci, correggi, compito (tutte prendono il testo dagli appunti; nuvola=si solo se glielo dici)."
        }
    }
}
