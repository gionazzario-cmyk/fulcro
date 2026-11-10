import Foundation

/// I limiti di cio' che Jarvis puo scrivere a nome dell'utente quando risponde da solo.
/// Non e' un consiglio nel prompt (qwen se ne frega e ci ha provato con "Ti amo anche io
/// amore" con sua nonna): e' un blocco che corre prima che il testo parta.
///
/// Regola di fondo: Jarvis puo dare informazioni pratiche e saluti neutri. Tutto quello
/// che e' affetto, opinioni, soldi, salute, o roba privata non e' roba sua.
enum LimitiMessaggio {

    /// Parole che non devono mai uscire dalla bocca di Jarvis: SOLO affetto e roba
    /// sessuale. Le parolacce invece il 2026-10-20 l'utente le ha volute libere
    /// («mettile pure, voglio che sia più umano possibile con me»), e bestemmie e
    /// turpiloquio sono state tolte da questo elenco.
    static let vietate = [
        "ti amo", "ti amo pure", "amore", "amore mio", "tesoro", "cuore", "bacio", "bacino",
        "abbraccio", "sei la migliore", "sei speciale", "mi manchi", "ti aspetto", "innamor",
        "sesso", "sborra", "nudo", "sexy",
        "voto", "elezioni", "partito", "meloni", "salvini", "berlusconi",
        "droga", "spinello", "alcol", "sigaretta", "fumo", "vaping"
    ]

    /// Cose private che non si mandano in giro.
    static let privati = [
        "iban", "password", "codice", "spid", "pin", "carta di credito", "domicilio",
        "indirizzo di casa", "referto", "medico", "ospedale", "farmaco", "terap",
        "pagella", "voto in", "debito", "soldi", "pago", "bonifico"
    ]

    /// Lunghezza massima di un messaggio autonomo: 600 perche' una risposta vera non sta
    /// in due righe (il 2026-10-20 l'utente si lamentava che rispondeva con un eco).
    static let massimoCaratteri = 600

    /// "Ti amo" da solo non è una risposta, è un eco: e siccome l'affetto non lo scrive
    /// lui, un messaggio che si chiama fuori deve essere una frase compiuta.
    /// Attenzione a non bloccare il "Ciao nonna" dettato dall'utente: qui si fermano
    /// solo i corti che sono pura ripetizione, non i saluti veri.
    static func troppoPovera(_ testo: String) -> Bool {
        let pulito = testo.trimmingCharacters(in: CharacterSet(charactersIn: " .!?…«»\""))
        let parole = pulito.components(separatedBy: " ").filter { !$0.isEmpty }
        if pulito.count >= 14 {
            let echi = ["si", "si certo", "certo", "ok", "okay", "grazie", "prega", "vabe", "dai", "ah", "si si"]
            return parole.count <= 2 && echi.contains(Memory.senzaAccenti(pulito))
        }
        // sotto i 14 caratteri: passa solo se e' una cosa dettata da lui parola per parola
        return !dettatoDallUtente(testo, richiesta: Agent.richiestaCorrente)
    }

    /// File suo: `~/.jarvis/limiti-messaggi.txt`, una parola/frase per riga (anche con `+`
    /// davanti per aggiungerne, `-` per toglierne una di default).
    static var fileLimiti: URL { AppPaths.jarvisRoot.appendingPathComponent("limiti-messaggi.txt") }

    static func extra() -> (aggiunte: [String], tolte: [String]) {
        let testo = ((try? String(contentsOf: fileLimiti, encoding: .utf8)) ?? "")
        var aggiunte: [String] = [], tolte: [String] = []
        for riga in testo.split(separator: "\n") {
            let r = riga.trimmingCharacters(in: .whitespaces)
            if r.isEmpty || r.hasPrefix("#") { continue }
            if r.hasPrefix("-") { tolte.append(String(r.dropFirst()).lowercased()) }
            else { aggiunte.append(r.replacingOccurrences(of: "+", with: "").lowercased()) }
        }
        return (aggiunte, tolte)
    }

    /// nil se il messaggio puo partire, altrimenti il perche' no (con la parte di
    /// servizio separata, cosi' all'utente arriva solo la verita' in chiaro).
    static func verifica(_ testo: String, destinatario: String) -> String? {
        let pulito = testo.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "it_IT"))
        let e = extra()
        let daTogliere = Set(e.tolte)
        let vietate = (self.vietate + e.aggiunte).filter { !daTogliere.contains($0) }
        let privati = self.privati.filter { !daTogliere.contains($0) }

        if testo.trimmingCharacters(in: .whitespacesAndNewlines).count > massimoCaratteri {
            return "NON INVIATO: il messaggio e' troppo lungo (\(testo.count) caratteri, il limite è \(massimoCaratteri)). "
                + GuardiaMessaggio.perIlModello + "accorcialo a una o due frasi pratiche e riprova.)"
        }
        if troppoPovera(testo), !staRispondendo() {
            return "NON INVIATO: due parole sole non sono un messaggio, sono un eco. "
                + GuardiaMessaggio.perIlModello + "scrivi una frase compiuta nel tono di \(Identita.nome) (le parolacce possono esserci, l'affetto no: quello lo scrive lui a mano), non \u{00ab}ti amo\u{00bb} o \u{00ab}si certo\u{00bb} da solo.)"
        }
        if let trovata = vietate.first(where: { pulito.contains($0) }) {
            return "NON INVIATO: c'e' \u{00ab}\(trovata)\u{00bb}, e l'affetto lo scrive solo \(Identita.nome) di suo pugno. "
                + GuardiaMessaggio.perIlModello + "togli le parole d'amore e lascia il resto (le parolacce invece puoi metterle, a lui piacciono): digli in una riga che quella parte se la scrive lui.)"
        }
        if let trovata = privati.first(where: { pulito.contains($0) }) {
            return "NON INVIATO: \u{00ab}\(trovata)\u{00bb} sono fatti privati di \(Identita.nome) e non finiscono in un messaggio mandato da un assistente. "
                + GuardiaMessaggio.perIlModello + "non parlare di salute, soldi, codici, voti o referti.)"
        }
        if pulito.contains("http://") || pulito.contains("https://") || pulito.contains("www.") {
            // i link che l'utente ha salvato o citato lui possono partire: e' proprio
            // il caso "mandami il link di quell'affare"
            if Cose.linkConosciuto(testo) || Cose.linkConosciuto(Agent.richiestaCorrente)
                || LimitiMessaggio.dettatoDallUtente(testo, richiesta: Agent.richiestaCorrente) {
                // ok, passa
            } else {
                return "NON INVIATO: \(Marca.nome) non manda link che \(Identita.nome) non gli ha dato o salvato (\u{00ab}salva il link di X\u{00bb} lo salva nell'archivio)."
            }
        }
        // non deve fingersi l'utente: chi riceve deve sapere che e' l'assistente
        let nomeUtente = Identita.nomeBreve.lowercased()
        if nomeUtente != "tu" && (pulito.contains("sono \(nomeUtente)") || pulito.contains("qui \(nomeUtente)")) {
            return "NON INVIATO: non puoi spacciarti per \(Identita.nome). "
                + GuardiaMessaggio.perIlModello + "scrivi \u{00ab}sono \(Marca.nome), l'assistente di \(Identita.nome)\u{00bb} e di' la cosa pratica.)"
        }
        return nil
    }

    /// Una risposta dentro una chat in corso puo' essere corta: «ok ci sono», «sisi»,
    /// «domani ci sono» sono esattamente quello che si scrive. Il divieto sulle due
    /// parole resta per i messaggi inventati da zero, dove una frase secca e' un eco.
    private static func staRispondendo() -> Bool {
        let r = Agent.richiestaCorrente.lowercased()
        return r.contains("rispond") || r.contains("replica")
    }

    /// True se il testo viene dalle parole dell'utente (detto o scritto che sia): in
    /// quel caso Jarvis puo' premere invio da solo. Se il testo l'ha costruito lui,
    /// passa dal pulsante di conferma — perche' il 2026-10-19 ha mandato "Se ti comporti
    /// bene ti do la patata" a una persona vera, e non era roba sua.
    /// Con chi l'utente ha gia' parlato: la rubrica sua, l'archivio dei messaggi o la
    /// cronologia. Servirebbe da solo, ma il 2026-10-20 la card di conferma e' scaduta
    /// senza clic e il messaggio non e' partito: con uno che conosce gia' deve partire.
    static func conosciuto(_ destinatario: String) -> Bool {
        let chiave = Memory.senzaAccenti(destinatario)
        guard chiave.count >= 3 else { return false }
        if Messaggi.contatti().contains(where: { Memory.senzaAccenti($0.nome) == chiave }) { return true }
        if Anagrafica.numeroPer(destinatario) != nil { return true }
        return Messaggi.giaParlato(con: destinatario)
    }

    static func dettatoDallUtente(_ testo: String, richiesta: String) -> Bool {
        let t = Memory.senzaAccenti(testo)
        let r = Memory.senzaAccenti(richiesta)
        guard t.count >= 8, !r.isEmpty else { return false }
        let testa = String(t.prefix(28))
        if r.contains(testa) { return true }
        // "digli che stasera non posso" -> "Stasera non posso venire": valuto le parole
        let paroleT = Set(t.components(separatedBy: " ").filter { $0.count > 4 })
        let paroleR = Set(r.components(separatedBy: " ").filter { $0.count > 4 })
        guard !paroleT.isEmpty else { return false }
        return Double(paroleT.intersection(paroleR).count) / Double(paroleT.count) >= 0.6
    }

    /// Da dire al modello quando vuole rispondere e basta: il perimetro chiaro.
    static let permesso = "Puoi scrivere solo: saluti neutri, se \(Identita.nome) puo parlare o no, a che ora finisce, "
        + "i compiti che ha, il meteo, e informazioni pratiche che ti ha dato \(Identita.nome). "
        + "Mai: ti amo/amore/abbracci, opinioni, politica, soldi, salute, codici, voti, link, o parolacce."
}
