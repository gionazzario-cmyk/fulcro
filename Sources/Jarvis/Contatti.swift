import Foundation
import Contacts

/// L'Anagrafica del Mac: tutti i contatti dell'utente, letti e scritti col framework
/// di Apple (non col SQLite: su macOS 26 i numeri sono spalmati su quattro archivi
/// separati in `~/Library/Application Support/AddressBook/Sources/<uuid>/`, e uno
/// solo ne ha 323 - leggerli a mano vuol dire perne metà).
///
/// Serve a due cose concrete:
/// - dire «nonna ha scritto…» invece di «+39351…», perche' il database di Messaggi
///   contiene solo numeri;
/// - scrivere lui un contatto nuovo a voce («salva il numero del meccanico»).
///
/// La prima volta che si usa, macOS chiede il permesso «Contatti»: e' un clic suo,
/// e il permesso resta. I dati non escono mai dal Mac (vedi CervelloPortatile).
enum Anagrafica {
    private static var negozio = CNContactStore()
    private static var cache: [(nome: String, numeri: [String])] = []
    private static var cacheFatta = Date.distantPast

    /// Stato del permesso, letto senza farlo chiedere.
    static var permesso: Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        default: return false
        }
    }

    static func descrizionePermesso() -> String {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return "permesso Contatti: dato (accesso completo)"
        case .limited: return "permesso Contatti: limitato (solo alcuni contatti)"
        case .denied: return "permesso Contatti: NEGATO in Impostazioni → Privacy e sicurezza → Contatti"
        case .restricted: return "permesso Contatti: bloccato da un profilo del Mac"
        default: return "permesso Contatti: non ancora chiesto"
        }
    }

    /// Chiede il permesso una volta sola (e' l'unico caso in cui serve un suo clic).
    static func chiediPermesso() async -> Bool {
        if permesso { return true }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            CNContactStore().requestAccess(for: .contacts) { ok, _ in c.resume(returning: ok) }
        }
    }

    /// Una stringa pulita: solo cifre e `+`, cosi' il confronto coi numeri di Messaggi regge.
    static func normalizza(_ numero: String) -> String {
        String(numero.filter { "+0123456789".contains($0) })
    }

    /// True se i due numeri sono lo stesso numero (ignora +39 iniziale e spazi).
    static func stessoNumero(_ a: String, _ b: String) -> Bool {
        let x = normalizza(a), y = normalizza(b)
        guard x.count >= 8, y.count >= 8 else { return false }
        if x == y { return true }
        // "+393331234567" e "00393331234567" e "3331234567": stessa cosa
        let sx = x.hasPrefix("+") ? String(x.dropFirst()) : x
        let sy = y.hasPrefix("+") ? String(y.dropFirst()) : y
        return sx == sy || sx.hasSuffix(sy) || sy.hasSuffix(sx)
    }

    private static let chiaviNecessarie: [CNKeyDescriptor] = [
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor
    ]

    /// Legge tutti i contatti (con un cache di 5 minuti: l'Anagrafica non cambia ogni secondo).
    static func tutti(forza: Bool = false) -> [(nome: String, numeri: [String])] {
        if !forza, Date().timeIntervalSince(cacheFatta) < 300, !cache.isEmpty { return cache }
        guard permesso else { return cache }
        var fuori: [(String, [String])] = []
        let richiesta = CNContactFetchRequest(keysToFetch: chiaviNecessarie)
        do {
            try negozio.enumerateContacts(with: richiesta) { c, _ in
                let nome = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let visualizzato = nome.isEmpty ? (c.organizationName.isEmpty ? c.nickname : c.organizationName)
                                                : (c.organizationName.isEmpty ? nome : "\(nome) · \(c.organizationName)")
                let numeri = c.phoneNumbers.map { normalizza($0.value.stringValue) }.filter { $0.count >= 6 }
                if !visualizzato.isEmpty { fuori.append((visualizzato, numeri)) }
            }
        } catch {
            return cache
        }
        cache = fuori
        cacheFatta = Date()
        return fuori
    }

    /// Nome del contatto che ha questo numero, se c'e'.
    static func nomePer(_ numero: String) -> String? {
        let cerca = normalizza(numero)
        guard cerca.count >= 8 else { return nil }
        return tutti().first { contatto in
            contatto.numeri.contains { stessoNumero($0, cerca) }
        }?.nome
    }

    /// Numero di un contatto cercato per nome (la prima corrispondenza).
    static func numeroPer(_ nome: String) -> (nome: String, numero: String)? {
        let chiave = Memory.senzaAccenti(nome)
        guard !chiave.isEmpty else { return nil }
        for c in tutti() {
            let k = Memory.senzaAccenti(c.nome)
            if k == chiave || k.contains(chiave) || chiave.contains(k) {
                if let n = c.numeri.first { return (c.nome, n) }
            }
        }
        return nil
    }

    /// Contatti che contengono la parola data (nome, cognome, azienda o numero).
    static func cerca(_ testo: String, massimo: Int = 12) -> [String] {
        let chiave = Memory.senzaAccenti(testo)
        let pulito = normalizza(testo)
        return tutti().filter {
            Memory.senzaAccenti($0.nome).contains(chiave) || (!pulito.isEmpty && $0.numeri.contains { stessoNumero($0, pulito) })
        }.prefix(massimo).map { c in
            "\(c.nome) → \(c.numeri.joined(separator: ", "))"
        }
    }

    /// Crea un contatto nuovo (o aggiunge il numero a uno che esiste gia' col stesso nome).
    static func salva(nome: String, numero: String) async -> String {
        guard !nome.trimmingCharacters(in: .whitespaces).isEmpty else { return "Dimmi il nome del contatto." }
        let n = normalizza(numero)
        guard n.count >= 8 else { return "Il numero «\(numero)» non sembra un numero." }
        if !(await chiediPermesso()) {
            return "Senza il permesso Contatti non posso scrivere: Impostazioni → Privacy e sicurezza → Contatti → \(Marca.nome)."
        }
        // se il nome esiste gia', il numero lo attacca a quello (niente doppioni)
        if let esistente = numeroPer(nome), stessoNumero(esistente.numero, n) {
            return "\(esistente.nome) aveva già questo numero."
        }
        let nuovo = CNMutableContact()
        let pezzi = nome.split(separator: " ", maxSplits: 1).map(String.init)
        if pezzi.count >= 2 {
            nuovo.givenName = pezzi[0]
            nuovo.familyName = pezzi[1]
        } else {
            // un nome solo (es. "Meccanico") va nel nome proprio: la ricerca lo trova lo stesso
            nuovo.givenName = pezzi.first ?? nome
        }
        nuovo.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                            value: CNPhoneNumber(stringValue: numero.trimmingCharacters(in: .whitespaces)))]
        let richiesta = CNSaveRequest()
        richiesta.add(nuovo, toContainerWithIdentifier: nil)
        do {
            try CNContactStore().execute(richiesta)
            cacheFatta = .distantPast
            return "Contatto salvato: \(nome) · \(n)"
        } catch {
            return "L'Anagrafica non ha accettato il salvataggio: \(error.localizedDescription)"
        }
    }
}

extension Tools {
    /// `contatti`: leggere e scrivere l'Anagrafica del Mac.
    static func contattiSkill(_ args: [String: Any]) async -> String {
        let azione = (args["azione"] as? String) ?? "stato"
        let nome = (args["nome"] as? String) ?? ""
        let numero = (args["numero"] as? String) ?? ""
        // "stato" non chiede niente: cosi' si puo' vedere la verita' senza comparire
        // con una finestra di permesso. Per leggere o scrivere, invece, il permesso
        // serve e lo si chiede qui (un clic suo, la prima volta).
        let utili = ["lista", "cerca", "numero", "salva"]
        if utili.contains(azione) && !Anagrafica.permesso {
            guard await Anagrafica.chiediPermesso() else {
                return "Il permesso Contatti non c'e': " + Anagrafica.descrizionePermesso()
            }
        }
        switch azione {
        case "stato":
            let quanti = Anagrafica.tutti().count
            return "\(Anagrafica.descrizionePermesso()) · \(quanti) contatti letti"
        case "lista":
            let tutti = Anagrafica.tutti()
            guard !tutti.isEmpty else { return Anagrafica.descrizionePermesso() }
            return tutti.prefix(60).enumerated().map { "\($0.offset + 1). \($0.element.nome) → \($0.element.numeri.joined(separator: ", "))" }
                .joined(separator: "\n")
            + (tutti.count > 60 ? "\n…e altri \(tutti.count - 60): cercali per nome." : "")
        case "cerca":
            guard !nome.isEmpty else { return "Dimmi chi cercare." }
            let ris = Anagrafica.cerca(nome)
            return ris.isEmpty ? "Nessun contatto con «\(nome)»." : ris.joined(separator: "\n")
        case "numero":
            guard let trovato = Anagrafica.numeroPer(nome.isEmpty ? numero : nome) else {
                return "Non trovo «\(nome.isEmpty ? numero : nome)» nell'Anagrafica."
            }
            return "\(trovato.nome) → \(trovato.numero)"
        case "salva":
            return await Anagrafica.salva(nome: nome, numero: numero)
        default:
            return "Azioni: stato, lista, cerca, numero, salva."
        }
    }
}
