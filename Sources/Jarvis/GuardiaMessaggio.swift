import Foundation

/// Il blocco che non c'era: il 2026-10-19 Jarvis ha mandato a una chat vera il testo
/// «leggi la chat e rispondimi», cioe' L'ORDINE che gli aveva dato l'utente, non un
/// messaggio scritto per la persona. Un messaggio sbagliato parte davvero e non si
/// puo' ritirare, quindi qui si ferma prima.
///
/// Regola: un messaggio deve essere una cosa che la persona legge e capisce, non una
/// frase di servizio rivolta a Jarvis.
enum GuardiaMessaggio {

    /// Parole che sono ordini dati all'assistente, non testo per un destinatario.
    private static let verbiDiServizio = [
        "leggi", "rispondi", "rispondimi", "rispondigli", "risponditele", "scrivi", "scrivere",
        "manda", "mandare", "mandagli", "di'", "dì", "dire", "dimmi", "spiega", "spiegare",
        "controlla", "guarda", "apri", "chiudi", "vai", "stampa", "salva", "ricordati",
        "ricorda", "accendi", "spegni", "presentati", "sintetizza", "traduci", "cerca"
    ]

    /// Richieste che non sono mai contenuto di un messaggio, da qualunque parte arrivino.
    private static let frasiDiServizio = [
        "e rispondigli", "e rispondimi", "e mandalo", "poi mandalo", "e invialo",
        "la chat", "i messaggi", "il messaggio", "con nana", "con nonna", "con dux", "a nana", "a nonna"
    ]

    private static func pulito(_ t: String) -> [String] {
        t.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .components(separatedBy: CharacterSet(charactersIn: " .,!?;:\"'()…-"))
            .filter { !$0.isEmpty }
    }

    /// Da qui in poi sono istruzioni per il modello: l'Agent le taglia prima di rispondere.
    static let perIlModello = "\n(ISTRUZIONI PER TE: "

    /// Il numero del padrone di casa, letto da `~/.jarvis/numero.txt`.
    /// Prima era scritto dentro il programma: un'app che la gente scarica non puo'
    /// girare con il numero di uno, e su un altro Mac "mandami un messaggio" avrebbe
    /// scritto all'utente invece che a chi lo sta usando davvero.
    static let numeroDiCasa: String = leggiRiga("numero.txt")

    /// I destinatari ammessi per le prove di invio: il padrone di casa + quello che
    /// c'e' in `~/.jarvis/prove.txt`, uno per riga. Regola data dall'utente il
    /// 2026-10-20: un testo di prova parte davvero e la gente lo legge.
    static let numeriPerLeProve: [String] = {
        var lista = numeroDiCasa.isEmpty ? [] : [numeroDiCasa]
        lista += leggiRighe("prove.txt")
        return lista
    }()

    private static func leggiRiga(_ file: String) -> String {
        leggiRighe(file).first ?? ""
    }

    private static func leggiRighe(_ file: String) -> [String] {
        let url = AppPaths.jarvisRoot.appendingPathComponent(file)
        guard let testo = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return testo.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 }
    }

    /// Vero se il destinatario e' uno di quelli autorizzati per le prove.
    static func autorizzatoPerLeProve(_ destinatario: String) -> Bool {
        let cifre = String(destinatario.filter { $0.isNumber })
        let nomeScritto = Memory.senzaAccenti(destinatario)
        let nomeVero = Memory.senzaAccenti(Messaggi.nomeDi(destinatario) ?? destinatario)
        for permesso in numeriPerLeProve {
            if permesso.isEmpty { continue }
            let cifrePermesso = String(permesso.filter { $0.isNumber })
            if cifrePermesso.count >= 6 && cifre.contains(cifrePermesso.suffix(9)) { return true }
            let parola = permesso.split(separator: " ").first.map(String.init) ?? permesso
            if parola.count > 3 && (nomeScritto.contains(Memory.senzaAccenti(parola))
                                     || nomeVero.contains(Memory.senzaAccenti(parola))) { return true }
        }
        return false
    }

    /// "mandami / scrivimi / a me" chiede il SUO numero, non quello dell'ultimo
    /// che ha parlato.
    static func chiedePerSe(_ richiesta: String) -> Bool {
        let basso = richiesta.lowercased()
        return ["mandami", "manda a me", "mandami un", "scrivimi", "scrivi a me",
                "a me un messaggio", "manda messaggio a me", "provarlo su di me"]
            .contains(where: basso.contains)
    }

    /// Vero se `destinatario` e' il numero del padrone di casa (scritto in qualunque modo).
    static func autorizzatoComeMe(_ destinatario: String) -> Bool {
        guard !numeroDiCasa.isEmpty else { return false }
        let cifre = String(destinatario.filter { $0.isNumber })
        return cifre.hasSuffix(numeroDiCasa) || cifre.hasPrefix(numeroDiCasa)
    }

    /// L'unico posto dove un destinatario puo' essere corretto: se la frase era
    /// "mandami" e il modello ha messo un altro, si torna al numero del padrone di casa.
    /// Senza `numero.txt` non si corregge niente: "a me" resta quello che ha detto il
    /// modello, e il messaggio va a chi sta usando Jarvis, non a un estraneo.
    static func destinatarioVero(per destinatario: String, chiesto richiesta: String) -> String {
        guard !numeroDiCasa.isEmpty else { return destinatario }
        return chiedePerSe(richiesta) && !autorizzatoComeMe(destinatario) ? numeroDiCasa : destinatario
    }

    /// Un testo che si dichiara un test non deve mai raggiungere un'altra persona.
    static func testFuoriDaiPermessi(_ testo: String, destinatario: String) -> String? {
        let basso = testo.lowercased()
        let dichiaranoTest = ["test di jarvis", "questo e' un test", "questo è un test",
                              "prova di invio", "è una prova", "e' una prova", "solo una prova",
                              "test:", "prova:", " \(Marca.nome): questo"]
        guard dichiaranoTest.contains(where: { basso.contains($0) }) else { return nil }
        guard !autorizzatoPerLeProve(destinatario) else { return nil }
        let chi = numeriPerLeProve.isEmpty ? "nessuno (segna il tuo numero in ~/.jarvis/numero.txt)"
                                           : numeriPerLeProve.joined(separator: " o ")
        return "NON INVIATO: le prove di invio si fanno solo a \(chi), mai ad altri. "
            + "«\(String(testo.prefix(60)))» sembra una prova. "
            + GuardiaMessaggio.perIlModello + "se devi provare la catena di invio usa uno di quei "
            + "destinatari; se invece il messaggio e' vero, riscrivilo TU, senza parole di prova.)"
    }

    /// nil se il testo puo' partire, altrimenti il perche' no (scritto per il modello,
    /// cosi' il secondo giro fa la cosa giusta invece di riprovare a caso).
    static func blocca(_ testo: String, destinatario: String, richiesta: String) -> String? {
        let parole = pulito(testo)
        guard !parole.isEmpty else { return "NON INVIATO: il testo del messaggio e' vuoto." }

        // 1) il testo e' (quasi) la richiesta dell'utente ricopiata: non e' un messaggio.
        //    Ma attenzione: quando l'utente DETTA il testo a voce ("scrivendo esattamente:
        //    Jarvis lavoro finito") la sovrapposizione e' altissima per forza, e blocca le
        //    cose dette da lui. Quindi scatta solo se dentro il testo c'e' un ordine vero.
        let richieste = pulito(richiesta)
        let insiemeRichiesta = Set(richieste)
        let stesse = parole.filter { insiemeRichiesta.contains($0) }.count
        let dentroCEUnOrdine = verbiDiServizio.contains(where: { parole.contains($0) })
            || frasiDiServizio.contains(where: { testo.lowercased().contains($0) })
        if !richieste.isEmpty, parole.count >= 2, dentroCEUnOrdine,
           Double(stesse) / Double(parole.count) > 0.62 {
            return "NON INVIATO: stai per mandare il tuo stesso ordine, non un messaggio. "
                + GuardiaMessaggio.perIlModello + "hai ricopiato «\(String(testo.prefix(70)))» di \(Identita.nome) invece di scrivere a \(destinatario): leggi la conversazione (messaggi azione ultimi) e richiama invia con il testo vero, scritto da te.)"
        }

        // 2) il testo e' un ordine dato a Jarvis. Stretto per non fermare i messaggi
        //    veri: "guarda che non posso venire" inizia come un ordine ma e' parlato
        //    normale, quindi se ci sono parole rivolte alla persona non si blocca.
        let prima = String(parole[0])
        let personali = ["ciao", "ti", "tu", "sei", "stai", "scusa", "grazie", "prego", "nonno", "nonna",
                         "mamma", "papa", "vengo", "vado", "posso", "devo", "domani", "oggi", "amo",
                         "spero", " complimenti", "buongiorno", "buonasera", "amore", "dux", "giova"]
        let parlaAllaPersona = personali.contains { parole.contains($0.trimmingCharacters(in: .whitespaces)) }
        if verbiDiServizio.contains(prima) && parole.count <= 10 && !parlaAllaPersona {
            return "NON INVIATO: «\(String(testo.prefix(70)))» era un ordine dato a te, non una frase per \(destinatario). "
                + GuardiaMessaggio.perIlModello + "esegui prima quello che ti e' stato chiesto, poi scrivi tu il messaggio con le parole giuste.)"
        }
        if parole.count <= 8 && frasiDiServizio.contains(where: { testo.lowercased().contains($0) }) {
            return "NON INVIATO: «\(String(testo.prefix(70)))» sembra una frase di servizio. Scrivi un messaggio vero per \(destinatario)."
        }

        // 2b) un invito merita una risposta fondata: prima si guarda il calendario.
        //       Il 2026-10-19 rispondeva "si o no" a caso, e non e' accettabile.
        if invitoVisto && !agendaControllata {
            return "NON INVIATO: c'e' un invito in arrivo e non hai guardato l'agenda. "
                + GuardiaMessaggio.perIlModello + "chiama agenda azione libero con il giorno dell'invito, POI rispondi con quello che dice il calendario (se e' libero: si' + ora; se e' occupato: no e perche').)"
        }

        // 3) «leggi la chat e rispondi» vuole dire due passi in ordine: prima si legge,
        //    poi si risponde. Se la lettura non c'e' stata, il messaggio e' inventato.
        let bassa = richiesta.lowercased()
        let chiedevaDiLeggere = ["leggi", "cosa ha detto", "cosa ha scritto", "continua", "rispondi",
                                 "rispondigli", "rispondimi", "riprendi"].contains { bassa.contains($0) }
        if chiedevaDiLeggere && !haLettoChat {
            return "NON INVIATO: non hai ancora letto la chat, quindi la risposta sarebbe inventata. "
                + GuardiaMessaggio.perIlModello + "chiama messaggi azione ultimi con \(destinatario), POI rispondi a quello che ha detto davvero.)"
        }
        return nil
    }

    /// Messaggi azione ultimi/non_letti e' gia' stato chiamato in questo turno.
    static var haLettoChat = false
    /// Agenda chiamata in questo turno: obbligatoria prima di dire si/no a un invito.
    static var agendaControllata = false
    /// C'e' un invito in quello che hai letto ("ti va di uscire domenica alle 4?").
    static var invitoVisto = false

    private static let paroleInvito = ["ti va di", "vuoi uscire", "uscire", "ci vediamo", "ci vediamo",
                                       "appuntamento", "facciamo qualcosa", "vieni", "verrai", "passo a prenderti",
                                       "domenica alle", "sabato alle", "stasera alle", "alle 4", "alle 16",
                                       "alle 5", "alle 17", "alle 6", "alle 18", "alle 7", "alle 19",
                                       "alle 20", "alle 21", "ora di pranzo", "calcetto", "pizzata", "cinema",
                                       "gelato", "park", "giro in bici", "uscita"]

    /// Chiama questa funzione su quello che hai letto: se sembra un invito, da' il via
    /// alla regola "prima l'agenda, poi la risposta".
    static func segnalaInvito(_ testo: String) {
        let bassa = testo.lowercased()
        if paroleInvito.contains(where: { bassa.contains($0) }) { invitoVisto = true }
    }
}
