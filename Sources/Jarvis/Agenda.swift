import Foundation
import EventKit

/// L'agenda vera dell'utente: Calendario + promemoria di macOS, letti con EventKit.
/// Serve perche' alla domanda "ti va di uscire domenica alle 4?" Jarvis non deve
/// rispondere a caso: deve guardare se e' libero e dire quello.
///
/// Il permesso si chiede una volta sola (con `NSCalendarsFullAccessUsageDescription`
/// nell'Info.plist); senza, `agenda` lo dice e non inventa niente.
enum Agenda {
    private static var negozio = EKEventStore()
    private static var cache: [(titolo: String, inizio: Date, fine: Date)] = []
    private static var cacheFatta = Date.distantPast

    static var permesso: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
                || EKEventStore.authorizationStatus(for: .event) == .authorized
        }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    static func descrizionePermesso() -> String {
        if permesso { return "permesso Calendario: dato" }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted: return "permesso Calendario: NEGATO (Impostazioni → Privacy e sicurezza → Calendario)"
        case .fullAccess, .authorized: return "permesso Calendario: dato"
        default: return "permesso Calendario: non ancora chiesto"
        }
    }

    @discardableResult
    static func chiediPermesso() async -> Bool {
        if permesso { return true }
        let concesso = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            if #available(macOS 14.0, *) {
                EKEventStore().requestFullAccessToEvents { ok, _ in c.resume(returning: ok) }
            } else {
                EKEventStore().requestAccess(to: .event) { ok, _ in c.resume(returning: ok) }
            }
        }
        permessoNegato = !concesso
        return concesso
    }

    /// Vero quando l'ultima lettura NON ha potuto guardare il calendario. Serve a
    /// non rispondere «LIBERO» quando in realta' non abbiamo visto niente: era
    /// l'unico permesso che degradava mentendo (gli altri dicono che manca).
    private(set) static var permessoNegato = false

    static let senzaPermesso = "Non posso guardare il calendario: il permesso e' negato "
        + "(Impostazioni di Sistema ▸ Privacy e sicurezza ▸ Calendari). "
        + "Non ti dico che sei libero, perche' non lo so."

    /// Impegni da `da` a `a` (letti una volta ogni 3 minuti: il calendario non cambia
    /// ogni secondo e ogni lettura e' costosa).
    static func impegni(da: Date = Date(), a: Date) async -> [(titolo: String, inizio: Date, fine: Date)] {
        if Date().timeIntervalSince(cacheFatta) < 180, !cache.isEmpty { return cache }
        guard await chiediPermesso() else { return [] }
        let negozio = EKEventStore()
        let cal = negozio.calendars(for: .event)
        guard !cal.isEmpty else { return [] }
        var fuori: [(titolo: String, inizio: Date, fine: Date)] = []
        for e in negozio.events(matching: negozio.predicateForEvents(withStart: da, end: a, calendars: cal)) {
            fuori.append((e.title.isEmpty ? "impegno senza titolo" : e.title, e.startDate, e.endDate))
        }
        cache = fuori.sorted(by: { (a: (titolo: String, inizio: Date, fine: Date),
                                     b: (titolo: String, inizio: Date, fine: Date)) in
            a.inizio < b.inizio })
        cacheFatta = Date()
        return cache
    }

    /// "sono libero sabato alle 16?" → risposta vera, con l'impegno che disturba.
    static func libero(giorno: Date) async -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM"
        let fine = Calendar.current.date(byAdding: .day, value: 1, to: giorno) ?? giorno
        let lista = await impegni(da: giorno, a: fine)
        if permessoNegato { return senzaPermesso }
        let delGiorno = lista.filter { Calendar.current.isDate($0.inizio, inSameDayAs: giorno) }
        let fmtOra = DateFormatter()
        fmtOra.locale = Locale(identifier: "it_IT")
        fmtOra.dateFormat = "HH:mm"
        if delGiorno.isEmpty {
            return "LIBERO il \(f.string(from: giorno)): niente in calendario."
        }
        return "OCCUPATO il \(f.string(from: giorno)): "
            + delGiorno.map { "\(fmtOra.string(from: $0.inizio))–\(fmtOra.string(from: $0.fine)) \($0.titolo)" }
                .joined(separator: "; ")
    }


    /// "martedi alle 16", "domani pomeriggio", "stasera alle 8", "20/10 18:30":
    /// le date gliele dice a voce, quindi servono le forme parlate, non gli ISO.
    static func dataItaliana(_ testo: String, di: Calendar = Calendar.current, adesso: Date = Date()) -> Date? {
        let t = Memory.senzaAccenti(testo)
        guard !t.isEmpty else { return nil }
        var giorno = di.startOfDay(for: adesso)
        let settimana: [String: Int] = ["lunedi": 2, "martedi": 3, "mercoledi": 4, "giovedi": 5,
                                        "venerdi": 6, "sabato": 7, "domenica": 1]
        var spostato = false
        for (nome, weekday) in settimana where t.contains(nome) {
            for i in 0...7 {
                if let d = di.date(byAdding: .day, value: i, to: adesso), di.component(.weekday, from: d) == weekday {
                    giorno = di.startOfDay(for: d); spostato = true; break
                }
            }
            break
        }
        if !spostato {
            if t.contains("dopodomani") { giorno = di.startOfDay(for: di.date(byAdding: .day, value: 2, to: adesso) ?? adesso) }
            else if t.contains("domani") { giorno = di.startOfDay(for: di.date(byAdding: .day, value: 1, to: adesso) ?? adesso) }
            else {
                let cifre = t.components(separatedBy: CharacterSet(charactersIn: "/ -")).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if cifre.count >= 2 {
                    var c = DateComponents(); c.day = cifre[0]; c.month = cifre[1]; c.year = di.component(.year, from: adesso)
                    if let d = di.date(from: c) { giorno = di.startOfDay(for: d) }
                }
            }
        }
        // mattina 9, pomeriggio 15, sera 20: se dice l'ora, vince quella
        var ora = 9, minuto = 0, oraDetta = false
        if t.contains("pomeriggio") { ora = 15 }
        if t.contains("sera") { ora = 20 }
        if t.contains("mattina") { ora = 9 }
        if t.contains("mezzogiorno") { ora = 12 }
        if let i = t.range(of: "alle") {
            let dopo = String(t[i.upperBound...])
            // "alle 16", "alle 16:30", "alle 4 e mezza": prime due cifre utili
            let numeri = dopo.components(separatedBy: CharacterSet(charactersIn: " :.e"))
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let h = numeri.first, (1...24).contains(h) {
                ora = h; oraDetta = true
                if numeri.count > 1, (0...59).contains(numeri[1]) { minuto = numeri[1] }
            }
        }
        // "alle 8" detta di sera = 20, non le 8 del mattino
        if oraDetta, ora <= 11, t.contains("sera") { ora += 12 }
        var c = di.dateComponents([.year, .month, .day], from: giorno)
        c.hour = min(23, max(0, ora)); c.minute = min(59, max(0, minuto))
        return di.date(from: c)
    }

    /// Cancella un impegno dal titolo (o che lo contiene). Serve per non lasciare in
    /// giro le prove: senza, ogni test di Jarvis restava sul suo calendario.
    static func togli(cosa: String) async -> String {
        guard cosa.trimmingCharacters(in: .whitespaces).count >= 3 else { return "Dimmi quale impegno tolgo." }
        guard await chiediPermesso() else { return "Senza il permesso Calendario non posso toccare niente." }
        let negozio = EKEventStore()
        let da = Calendar.current.startOfDay(for: Date().addingTimeInterval(-86_400))
        let al = Date().addingTimeInterval(86_400 * 120)
        let cal = negozio.calendars(for: .event)
        let chiave = Memory.senzaAccenti(cosa)
        var trovati = 0
        for e in negozio.events(matching: negozio.predicateForEvents(withStart: da, end: al, calendars: cal))
        where Memory.senzaAccenti(e.title).contains(chiave) {
            do { try negozio.remove(e, span: .thisEvent, commit: true); trovati += 1 } catch { return "Il calendario ha rifiutato: \(error.localizedDescription)" }
        }
        cacheFatta = .distantPast
        return trovati == 0 ? "Nessun impegno con «\(cosa)» nei prossimi mesi." : "Tolti \(trovati) impegno/i dal calendario."
    }

    /// Crea un impegno sul calendario dell'utente.
    static func aggiungi(cosa: String, quando: String, minuti: Int = 60) async -> String {
        guard cosa.trimmingCharacters(in: .whitespaces).count >= 3 else { return "Dimmi cosa devo segnare." }
        guard await chiediPermesso() else { return "Senza il permesso Calendario non posso scrivere: " + descrizionePermesso() }
        guard let inizio = dataItaliana(quando.isEmpty ? "domani" : quando) else {
            return "Non ho capito «" + quando + "»: dimmi un giorno (martedi, domani, 20/10) e se puoi l'ora («alle 16»)."
        }
        let negozio = EKEventStore()
        guard let cal = negozio.calendars(for: .event).first else {
            return "Il Mac non ha nessun calendario dove scrivere (Impostazioni → Calendario)."
        }
        let evento = EKEvent(eventStore: negozio)
        evento.title = cosa
        evento.startDate = inizio
        evento.endDate = Calendar.current.date(byAdding: .minute, value: max(15, minuti), to: inizio) ?? inizio
        evento.calendar = cal
        do {
            try negozio.save(evento, span: .thisEvent, commit: true)
            let f = DateFormatter(); f.locale = Locale(identifier: "it_IT"); f.dateFormat = "EEEE d MMMM 'alle' HH:mm"
            cacheFatta = .distantPast
            return "Segnato in calendario: " + cosa + " — " + f.string(from: inizio) + " (" + cal.title + ")."
        } catch {
            return "Il calendario ha rifiutato il salvataggio: " + error.localizedDescription
        }
    }

    /// Righe lette per bene, per il prompt e per lo strumento.
    static func elenco(_ lista: [(titolo: String, inizio: Date, fine: Date)]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE d MMM HH:mm"
        return lista.prefix(20).map { "\(f.string(from: $0.inizio)) → \($0.titolo)" }.joined(separator: "\n")
    }
}

extension Tools {
    /// `agenda`: cosa c'e' scritto nel calendario dell'utente, e se e' libero.
    static func agendaSkill(_ args: [String: Any]) async -> String {
        let azione = (args["azione"] as? String) ?? "prossimi"
        enum Weekday: Int { case monday = 2, tuesday = 3, wednesday = 4, thursday = 5, friday = 6, saturday = 7, sunday = 1 }
        let cal = Calendar.current
        let oggi = Date()
        func giorno(_ testo: String) -> Date {
            let t = Memory.senzaAccenti(testo)
            if t.contains("domani") { return cal.date(byAdding: .day, value: 1, to: oggi) ?? oggi }
            if t.contains("dopodomani") { return cal.date(byAdding: .day, value: 2, to: oggi) ?? oggi }
            if t.contains("luned") { return prossimo(.monday) ?? oggi }
            if t.contains("marted") { return prossimo(.tuesday) ?? oggi }
            if t.contains("mercoled") { return prossimo(.wednesday) ?? oggi }
            if t.contains("gioved") { return prossimo(.thursday) ?? oggi }
            if t.contains("venerd") { return prossimo(.friday) ?? oggi }
            if t.contains("sabato") { return prossimo(.saturday) ?? oggi }
            if t.contains("domenica") { return prossimo(.sunday) ?? oggi }
            return oggi
        }
        func prossimo(_ giorno: Weekday) -> Date? {
            let cal = Calendar.current
            let target = giorno.rawValue
            for i in 1...7 {
                if let d = cal.date(byAdding: .day, value: i, to: Date()), cal.component(.weekday, from: d) == target {
                    return cal.startOfDay(for: d)
                }
            }
            return nil
        }
        switch azione {
        case "stato":
            // se non e' mai stato chiesto, conviene chiederlo adesso: la finestra esce
            // mentre l'utente e' al Mac, non dopo quando non c'e'
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                await Agenda.chiediPermesso()
            }
            return Agenda.descrizionePermesso()
        case "oggi":
            let lista = await Agenda.impegni(da: cal.startOfDay(for: oggi),
                                             a: cal.date(byAdding: .day, value: 1, to: oggi) ?? oggi)
            if Agenda.permessoNegato { return Agenda.senzaPermesso }
            return lista.isEmpty ? "Oggi niente in calendario." : Agenda.elenco(lista)
        case "domani", "giorno":
            let g = giorno((args["quando"] as? String) ?? "domani")
            let lista = await Agenda.impegni(da: cal.startOfDay(for: g),
                                             a: cal.date(byAdding: .day, value: 1, to: g) ?? g)
            if Agenda.permessoNegato { return Agenda.senzaPermesso }
            return lista.isEmpty ? "Niente in calendario." : Agenda.elenco(lista)
        case "libero":
            return await Agenda.libero(giorno: cal.startOfDay(for: giorno((args["quando"] as? String) ?? "")))
        case "aggiungi":
            return await Agenda.aggiungi(cosa: (args["cosa"] as? String) ?? "",
                                         quando: (args["quando"] as? String) ?? "",
                                         minuti: Int(((args["minuti"] as? String) ?? "").filter { $0.isNumber }) ?? 60)
        case "togli":
            return await Agenda.togli(cosa: (args["cosa"] as? String) ?? "")
        case "prossimi":
            let lista = await Agenda.impegni(da: oggi, a: cal.date(byAdding: .day, value: 10, to: oggi) ?? oggi)
            if Agenda.permessoNegato { return Agenda.senzaPermesso }
            return lista.isEmpty ? "Nessun impegno nei prossimi 10 giorni." : Agenda.elenco(lista)
        default:
            return "Azioni: stato, oggi, domani, giorno (con quando), libero (con quando), prossimi."
        }
    }
}
