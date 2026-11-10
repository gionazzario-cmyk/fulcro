import Foundation

/// I suggerimenti a schermo: non una lista fissa di pulsanti, ma quello che ha senso
/// chiedere **adesso**, con il perche' scritto sopra.
///
/// Due scelte precise. (1) Sono deterministici: ora, compiti letti dal file, ultimo stato
/// della stampante, se gli appunti hanno roba, se il Mac e' staccato. Niente modello e
/// niente rete: un suggerimento inventato sarebbe peggio di nessun suggerimento, perche'
/// poi lui lo prova e non funziona. (2) La regola che lo ha generato resta in `perche'`
/// e si vede come `help`: se ne esce uno scemo si capisce da dove arriva, e si corregge
/// quella riga invece di tirare a sorte.
struct Suggerimento: Equatable {
    var chip: String
    var frase: String
    var icona: String
    var perche: String

    static func == (a: Suggerimento, b: Suggerimento) -> Bool { a.chip == b.chip }
}

enum Suggerimenti {
    struct Contesto {
        var ora: Int
        var giornoDiScuola: Bool
        var compitiOggi: Int
        var compitiEntro3: Int
        var stampaInCorso: Bool
        var stampaFinita: Bool
        var appuntiPieni: Bool
        var inCarica: Bool
    }

    /// La regola pura: si prova senza toccare niente, e i casi brutti si scrivono a mano.
    static func regole(_ c: Contesto) -> [Suggerimento] {
        var fuori: [Suggerimento] = []
        if c.stampaInCorso {
            fuori.append(Suggerimento(chip: "Quanto manca?", frase: "quanto manca alla fine della stampa?",
                                      icona: "printer", perche: "l'ultima lettura della A1 mini dice che stampa"))
        }
        if c.stampaFinita {
            fuori.append(Suggerimento(chip: "Piatto freddo?", frase: "com'e' finita la stampa?",
                                      icona: "cube.unstack", perche: "l'ultima lettura dice finita bene"))
        }
        if c.compitiOggi > 0 {
            fuori.append(Suggerimento(chip: "\(c.compitiOggi) compiti per oggi", frase: "che compiti ho per oggi?",
                                      icona: "book", perche: "letti da ~/.jarvis/compiti.md"))
        } else if c.compitiEntro3 > 0 {
            fuori.append(Suggerimento(chip: "Cose in arrivo", frase: "che compiti ho nei prossimi giorni?",
                                      icona: "calendar", perche: "scadenze entro tre giorni"))
        }
        if c.appuntiPieni {
            fuori.append(Suggerimento(chip: "Spiegami gli appunti", frase: "spiegami quello che ho copiato",
                                      icona: "scissors", perche: "c'e' testo negli appunti da quando hai copiato"))
        }
        // prima di uscire: vale la mattina vera (6-11), non a mezzanotte, e l'ora si
        // scrive come si legge ("sono le 00:40"), non come numero nudo
        if c.ora >= 6 && c.ora < 11 {
            fuori.append(Suggerimento(chip: "Che tempo fa", frase: "che tempo fa?",
                                      icona: "cloud.sun", perche: "sono le \(String(format: "%02d", c.ora)) e devi uscire"))
        }
        if !c.inCarica && c.ora >= 7 {
            fuori.append(Suggerimento(chip: "Cosa cambia a batteria", frase: "cosa fai di diverso a batteria?",
                                      icona: "battery.50", perche: "il Mac e' staccato: cervello Gemini, niente sorveglianza"))
        }
        if c.ora >= 19 && c.compitiOggi == 0 {
            fuori.append(Suggerimento(chip: "Facciamo il punto", frase: "facciamo il punto",
                                      icona: "sparkles", perche: "e sera e il briefing costa un secondo"))
        }
        return Array(fuori.prefix(4))
    }

    // MARK: - raccolta, con roba gia' in casa

    /// "2026-10-21" / "oggi" / "domani" / "21/10" / "21-10" -> giorni da adesso (nil se non capisce)
    static func giorniDaOggi(_ raw: String, adesso: Date = Date()) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cal = Calendar.current
        let oggi = cal.startOfDay(for: adesso)
        if t.isEmpty { return nil }
        if t == "oggi" { return 0 }
        if t == "domani" { return 1 }
        if t.hasPrefix("dopodomani") { return 2 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        for formato in ["yyyy-MM-dd", "yyyy-MM-dd HH:mm", "dd/MM", "dd/MM/yyyy", "dd-MM", "dd-MM-yyyy"] {
            f.dateFormat = formato
            if let d = f.date(from: t) {
                let giorno = f.dateFormat.contains("yyyy") ? d
                    : { var c = cal.dateComponents([.year], from: oggi); c.month = cal.component(.month, from: d)
                        c.day = cal.component(.day, from: d); return cal.date(from: c) ?? d }()
                return cal.startOfDay(for: giorno).timeIntervalSince(oggi).days
            }
        }
        return nil
    }

    /// Se oggi si va a scuola: legge ~/.jarvis/orario.md e cerca il nome del giorno,
    /// senza accenti e senza maiuscole (la stessa lezione imparata con l'orario rotto).
    static func scuolaOggi(_ adesso: Date = Date()) -> Bool {
        let testo = ((try? String(contentsOf: AppPaths.jarvisRoot.appendingPathComponent("orario.md"),
                                  encoding: .utf8)) ?? "").lowercased()
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE"
        let nome = f.string(from: adesso)
        let nudo = nome.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !testo.isEmpty, nudo.count > 2 else { return false }
        return testo.contains(nudo)
    }

    /// Quanti compiti scadono oggi (serve alla pill "scuola", senza rileggere tutto due volte)
    @MainActor static func contaOggi() -> Int {
        Compiti.leggi(tutti: true).filter { !$0.fatto && (giorniDaOggi($0.scadenza) ?? 99) <= 0 }.count
    }

    @MainActor static func oggi() -> [Suggerimento] {
        var oggi = 0, entro3 = 0
        for c in Compiti.leggi(tutti: true) where !c.fatto {
            if let g = giorniDaOggi(c.scadenza) {
                if g <= 0 { oggi += 1 } else if g <= 3 { entro3 += 1 }
            }
        }
        let cal = Calendar.current
        let f = AppPaths.jarvisRoot.appendingPathComponent("suggerimenti.txt")
        return regole(Contesto(
            ora: cal.component(.hour, from: Date()),
            giornoDiScuola: scuolaOggi(),
            compitiOggi: oggi,
            compitiEntro3: entro3,
            stampaInCorso: Bambu.ultimoStato.contains("sta stampando"),
            stampaFinita: Bambu.ultimoStato.contains("finita bene"),
            appuntiPieni: ((try? String(contentsOf: f, encoding: .utf8)) ?? "no") == "si",
            inCarica: Alimentazione.inCarica
        ))
    }

    /// L'unica cosa che si aggiorna "da fuori": lo strumento appunti scrive se la clipboard
    /// aveva roba, cosi' il suggerimento non deve leggere la clipboard ogni 30 secondi.
    static var segnalatore: URL { AppPaths.jarvisRoot.appendingPathComponent("suggerimenti.txt") }

    static func segnaAppunti(_ testo: String) {
        try? (testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "no" : "si")
            .write(to: segnalatore, atomically: true, encoding: .utf8)
    }
}

extension TimeInterval {
    /// Millisecondi -> giorni interi, per la differenza tra due mezzanotte.
    var days: Int { Int((self / 86_400).rounded(.down)) }
}
