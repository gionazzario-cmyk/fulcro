import Foundation
import AppKit

/// Messaggi, mail e WhatsApp.
///
/// Cosa si puo fare davvero su questo Mac (verificato il 2026-10-18):
/// - iMessage: si leggono dal database `~/Library/Messages/chat.db`, che pero' macOS
///   apre solo con "Accesso completo al disco".
/// - Mail: Mail.app ha il dizionario AppleScript, quindi lettura e invio funzionano
///   appenall'utente configura l'account li' (la password la digita lui, non passa da qui).
/// - WhatsApp: l'app non ha nessun dizionario di comandi e il testo delle notifiche non
///   finisce nel log di sistema (Apple lo nasconde). Quindi: si apre la chat con il link
///   `whatsapp://`, si scrive, e per leggere cosa c'e' scritto si guarda lo schermo.
enum Messaggi {
    static var dbPath: String { NSHomeDirectory() + "/Library/Messages/chat.db" }

    /// Nome -> numero, scritto dall'utente in `~/.jarvis/contatti.txt`
    /// (una riga per contatto: `il contatto di prova = +39 351 7467807`).
    /// Serve a due cose vere: leggere i messaggi per nome invece che per numero,
    /// e scrivere nella chat usando il numero, che il chip si chiude sempre.
    static var fileContatti: URL { AppPaths.jarvisRoot.appendingPathComponent("contatti.txt") }

    static func contatti() -> [(nome: String, numero: String)] {
        let testo = ((try? String(contentsOf: fileContatti, encoding: .utf8)) ?? "")
        var fuori: [(String, String)] = []
        for riga in testo.split(separator: "\n") {
            let r = riga.trimmingCharacters(in: .whitespaces)
            if r.isEmpty || r.hasPrefix("#") { continue }
            for sep in ["=", ":", " - "] {
                guard let i = r.range(of: sep) else { continue }
                let nome = String(r[..<i.lowerBound]).trimmingCharacters(in: .whitespaces)
                let numero = String(r[i.upperBound...]).filter { "+0123456789".contains($0) }
                if !nome.isEmpty && numero.count >= 8 { fuori.append((nome, numero)) }
                break
            }
        }
        return fuori
    }

    /// Se il destinatario e' un nome conosciuto, restituisce il suo numero.
    static func numeroDi(_ nome: String) -> String? {
        let cerca = Memory.senzaAccenti(nome.lowercased())
        for c in contatti() {
            let chiave = Memory.senzaAccenti(c.nome.lowercased())
            if chiave == cerca || cerca.contains(chiave) || chiave.contains(cerca) { return c.numero }
        }
        return nil
    }

    /// Numero -> nome, per dire "nonna ha scritto" e non "+39351…".
    /// Prima la lista sua in ~/.jarvis/contatti.txt (vale anche se il permesso
    /// Contatti non c'e'), poi l'Anagrafica del Mac.
    static func nomeDi(_ numero: String) -> String? {
        let pulito = numero.filter { "+0123456789".contains($0) }
        guard pulito.count >= 8 else { return nil }
        if let locale = contatti().first(where: { $0.numero.filter { "+0123456789".contains($0) } == pulito })?.nome {
            return locale
        }
        return Anagrafica.nomePer(pulito)
    }

    /// Secondi dal 1970 partendo dal contatore di Apple (nan dal 2001-01-01).
    private static let epocaApple: TimeInterval = 973_353_600

    /// NON fidarsi delle colonne `date`: sul chat.db di questo Mac un messaggio scritto
    /// alle 18:03 di oggi risulta del 23 agosto (ROWID 5304, verificato il 2026-10-19).
    /// Quindi "e' nuovo?" e "e' partito?" si rispondono con l'ordine di scrittura, che
    /// e' monotono per definizione, e non con l'orologio.
    static func ultimoId() -> Int {
        guard let righe = query("SELECT max(ROWID) FROM message;"), let primo = righe.first?.first,
              let n = Int(primo) else { return 0 }
        return n
    }

    static func dataApple(_ nano: Double) -> Date {
        Date(timeIntervalSince1970: nano / 1_000_000_000 + epocaApple)
    }

    /// Estrae il testo di un messaggio: nelle versioni recenti sta nel BLOB
    /// `attributedBody` (plist gzipato), non nella colonna TEXT.
    static func testoDi(_ hex: String, _ plain: String) -> String {
        if !plain.isEmpty { return plain }
        guard let data = Data(hexa: hex), !data.isEmpty else { return "" }
        let sciolto: Data
        if data.count > 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            sciolto = gunzip(data) ?? data
        } else {
            sciolto = data
        }
        if let plist = try? PropertyListSerialization.propertyList(from: sciolto, format: nil),
           let dizionario = plist as? [String: Any],
           let oggetti = dizionario["$objects"] as? [Any] {
            let candidati = oggetti.compactMap { $0 as? String }
                .filter { $0.count >= 2 && !$0.hasPrefix("NS") && !$0.contains("$") && !$0.hasPrefix("_") }
            if let migliore = candidati.max(by: { $0.count < $1.count }) { return migliore }
        }
        // ultima spiaggia: la stringa stampabile piu' lunga dentro il blob
        var corrente = ""
        var migliore = ""
        for byte in sciolto {
            if byte >= 32 && byte < 127 {
                corrente.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                if corrente.count > migliore.count { migliore = corrente }
                corrente = ""
            }
        }
        return corrente.count > migliore.count ? corrente : migliore
    }

    private static func gunzip(_ data: Data) -> Data? {
        let gz = AppPaths.tmp.appendingPathComponent("msg-\(UUID().uuidString).gz")
        defer { try? FileManager.default.removeItem(at: gz) }
        do { try data.write(to: gz) } catch { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", gz.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let letto = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return letto.isEmpty ? nil : letto
    }

    /// Perche' l'ultima lettura e' fallita. Senza questo Jarvis dava la colpa al
    /// permesso anche quando il permesso c'era e l'errore era un altro (colonna
    /// inesistente, join sbagliato): due bug veri trovati il 2026-10-19.
    static var ultimoErrore = ""

    /// Interroga il database in sola lettura. Ritorna nil se non si puo' leggere.
    static func query(_ sql: String) -> [[String]]? {
        ultimoErrore = ""
        // isReadableFile mente: i permessi POSIX del file sono aperti a tutti, quindi
        // dice "leggibile" anche quando il blocco e' TCC. Qui si prova davvero ad aprirlo.
        if (try? FileHandle(forReadingFrom: URL(fileURLWithPath: dbPath))) == nil {
            ultimoErrore = "permesso"
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-separator", "\u{1}", dbPath, sql]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            ultimoErrore = "sqlite3 non parte: \(error.localizedDescription)"
            return nil
        }
        let outo = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            ultimoErrore = String(outo.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }
        return outo.components(separatedBy: .newlines).filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\u{1}") }
    }


    /// Ultimi messaggi ricevuti (e mandati) con mittente e orario.
    static func ultimi(limit: Int = 10, soloRicevuti: Bool = false) -> String {
        guard let righe = query("""
            SELECT m.is_from_me, m.is_read, m.date,
                   COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id, 'ignoto'),
                   COALESCE(m.text, ''), COALESCE(hex(m.attributedBody), '')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            \(soloRicevuti ? "WHERE m.is_from_me = 0" : "")
            ORDER BY m.ROWID DESC LIMIT \(max(1, min(limit, 30)));
            """) else {
            if ultimoErrore == "permesso" {
                return "Non riesco ad aprire il database dei messaggi: \(Identita.nome) deve dare a \(Marca.nome) "
                    + "«Accesso completo al disco» in Impostazioni di Sistema → Privacy e sicurezza → "
                    + "Accesso completo al disco, e poi riavviarmi."
            }
            return "Il database dei messaggi si apre ma la lettura e' fallita: \(ultimoErrore.prefix(160))"
        }
        guard !righe.isEmpty else { return "Il database dei messaggi e' vuoto o non leggibile." }
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE HH:mm"
        var out: [String] = []
        for r in righe where r.count >= 6 {
            let daMe = r[0] == "1"
            let nonLetto = r[1] == "0" && !daMe
            let quando = Double(r[2]).map { dataApple($0) } ?? Date()
            let corpo = testoDi(r[5], r[4])
            let mittente = nomeDi(r[3]).map { "\(r[3]) · \($0)" } ?? r[3]
            var riga = "\(f.string(from: quando)) · \(daMe ? "a " : "")\(mittente): \(corpo.prefix(220))"
            if nonLetto { riga += "  [NON LETTO]" }
            out.append(riga)
        }
        return out.joined(separator: "\n")
    }

    /// Solo i messaggi nuovi che non ho ancora annunciato.
    static func daAnnunciare(dopoId: Int) -> [(id: Int, chi: String, testo: String)] {
        guard let righe = query("""
            SELECT m.ROWID, COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id, 'ignoto'),
                   COALESCE(m.text, ''), COALESCE(hex(m.attributedBody), '')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.is_from_me = 0 AND m.ROWID > \(dopoId)
            ORDER BY m.ROWID ASC LIMIT 6;
            """) else { return [] }
        return righe.compactMap { r in
            guard r.count >= 4, let id = Int(r[0]) else { return nil }
            return (id, r[1], Self.pulisci(testoDi(r[3], r[2])))
        }
    }

    /// Togli le parti che non hanno senso dette ad alta voce.
    static func pulisci(_ t: String) -> String {
        var s = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if s.count > 260 { s = String(s.prefix(260)) + "..." }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spedisce davvero: apre il numero in Messaggi e scrive coi tasti.
    /// L'AppleScript `send` non funziona su questo Mac (Messaggi restituisce -1728
    /// quando gli enumeri gli account), quindi si passa dalla tastiera: serve
    /// Accessibilita', che e' anche quella che serve per WhatsApp e per l'invio automatico.
    /// Spedisce davvero, senza passare dai link `sms:`.
    ///
    /// Il bug che ha visto l'utente: la pulizia del corpo usava Cmd+A, e quando il
    /// cursore stava sul campo "A:" cancellava proprio il destinatario. Qui la
    /// sequenza e' quella umana: Cmd+N (nuovo messaggio), numero, Invio per chiudere
    /// il chip del destinatario, e solo allora il corpo e' a fuoco e si scrive.
    static func inviaConTastiera(a: String, testo: String, invio: Bool) async -> String {
        // Il cancello sta QUI dentro, non solo nello strumento: `conversazione` chiama
        // questa funzione saltando il skill, e una prova di invio non deve poter partire
        // verso qualcuno che non siall'utente o il contatto di prova (regola del 2026-10-20).
        if invio, let fermato = GuardiaMessaggio.testFuoriDaiPermessi(testo, destinatario: a) {
            return fermato
        }
        // "mandami" = il numero dell'utente, sempre. Il 2026-10-20 il modello aveva letto
        // la stessa frase come "rispondi all'ultimo mittente" e stava scrivendo a sua
        // nonna una prova che lui aveva chiesto per se'.
        let a = GuardiaMessaggio.destinatarioVero(per: a, chiesto: Agent.richiestaCorrente)
        // Gli spazi si tolgono solo dai numeri (+39 333 1234567): un nome di contatto
        // senza spazi ("nanapestifera") Messaggi non lo trova e il chip non si chiude.
        let eUnNumero = a.allSatisfy { "+0123456789 ()-.".contains($0) }
        let nomeUmano = a.trimmingCharacters(in: .whitespacesAndNewlines)
        // coi nomi il chip a volte non si chiude (Messaggi cerca il contatto, non la
        // cronologia): se il numero e' in ~/.jarvis/contatti.txt si usa quello.
        let destinatario = eUnNumero ? a.replacingOccurrences(of: " ", with: "")
                                     : (numeroDi(nomeUmano) ?? Anagrafica.numeroPer(nomeUmano)?.numero ?? nomeUmano)
        guard !destinatario.isEmpty, !testo.isEmpty else { return "Servono destinatario e testo." }
        guard Capacita.accessibilita else {
            return "Per scrivere e premere Invio serve Accessibilita': permessi azione=chiedi_accessibilita e poi riavviami."
        }
        let idPrima = ultimoId()
        NSWorkspace.shared.open(URL(string: "messages://")!)
        // Il titolo della finestra e' l'unica prova che la chat aperta e' quella giusta:
        // l'albero dell'interfaccia di Messaggi su macOS 26 non e' leggibile, i nomi delle
        // finestre si'. Finche' il chip non si chiude il titolo resta "Messaggi": li' si
        // riprova con Invio, e se non cambia mai si ferma senza scrivere niente.
        // l'utente deve ritrovarsi lo schermo com'era: si segna chi aveva davanti prima
        // di toccare il primo piano, e se Messaggi non era aperta si nasconde di nuovo
        // appena finito (regola data il 2026-10-20).
        let schermoPrima = Silenzio.frontale()
        let messaggiEraAperta = Silenzio.eraGiaAperta("com.apple.MobileSMS")
        let script = """
        on run argv
            set destinatario to item 1 of argv
            set corpo to item 2 of argv
            set premi to item 3 of argv
            set nomeVisibile to item 4 of argv
            set tipoDestinatario to item 5 of argv
            -- gli appunti dell'utente non sono miei: si salvano e si rimettono a posto.
            -- Prima lo script li sovrascriveva tre volte e li lasciava cosi'.
            set appuntiPrima to ""
            try
                set appuntiPrima to (the clipboard as text)
            end try
            -- se un'altra app tiene il focus i tasti finirebbero li': meglio fermarsi
            -- che scrivere dentro chissa' dove. Ma arrendersi al primo colpo era un bug
            -- vero: se chi usa il Mac sta scrivendo altrove, Messages deve potersi riprendere
            -- la finestra, quindi si riprova l'attivazione alcune volte.
            set appDavanti to ""
            repeat 6 times
                tell application "Messages" to activate
                delay 0.7
                tell application "System Events"
                    tell process "Messages" to set frontmost to true
                    delay 0.6
                    set appDavanti to name of first process whose frontmost is true
                end tell
                if appDavanti is "Messages" then exit repeat
                -- se c'e' un'altra app davanti, la si mette in background: e' il modo
                -- che funziona davvero quando il terminale o l'IDE se ne riapprofittano
                tell application "System Events"
                    try
                        set visible of process appDavanti to false
                    end try
                end tell
                delay 0.6
            end repeat
            if appDavanti is not "Messages" then
                my ripristina(appuntiPrima)
                return "FOCUS:" & appDavanti
            end if
            set cerca to my eliminaSpazi(destinatario)
            set cercaNome to my eliminaSpazi(item 4 of argv)
            -- 1) se la chat di questa persona e' gia' aperta la rialzo: Cmd+N con una
            --    finestra gia' davanti apriva la chat sbagliata (visto il 2026-10-19)
            set chatOk to false
            -- i titoli si leggono dentro il tell, ma si CONFRONTANO fuori: dentro
            -- "tell process" anche un handler con `my` viene mandato a System Events
            -- e risponde -1708 (errore visto il 2026-10-19)
            set titoli to {}
            tell application "System Events" to tell process "Messages"
                try
                    set titoli to name of every window
                end try
            end tell
            repeat with t in titoli
                set tt to (t as text)
                if tt is not "" and tt is not "Messaggi" then
                    if (my chatTitolGiusto(tt, cerca, cercaNome, tipoDestinatario)) then
                        -- "set frontmost of window" non e' supportato (-10006):
                        -- si alza con AXRaise e poi si ricontrolla il titolo
                        tell application "System Events" to tell process "Messages"
                            try
                                perform action "AXRaise" of window tt
                            end try
                        end tell
                        set chatOk to true
                        exit repeat
                    end if
                end if
            end repeat
            if chatOk then
                set t1 to ""
                try
                    tell application "System Events" to tell process "Messages" to set t1 to name of front window
                end try
                if not (my chatTitolGiusto(t1, cerca, cercaNome, tipoDestinatario)) then set chatOk to false
            end if
            if not chatOk then
                tell application "System Events"
                    tell process "Messages"
                        keystroke "n" using command down
                        delay 1.4
                        keystroke destinatario
                        delay 2.2
                    end tell
                end tell
                -- 2) Invio chiude il chip: finche' il titolo non diventa la persona
                --    giusta riprovo, perche' "Messaggi" vuol dire chip ancora aperto
                set titolo to ""
                repeat 4 times
                    tell application "System Events" to tell process "Messages" to key code 36
                    delay 1.5
                    set titolo to ""
                    try
                        tell application "System Events" to tell process "Messages" to set titolo to name of front window
                    end try
                    if (my chatTitolGiusto(titolo, cerca, cercaNome, tipoDestinatario)) then
                        set chatOk to true
                        exit repeat
                    end if
                end repeat
            end if
            if not chatOk then
                set t2 to ""
                try
                    tell application "System Events" to tell process "Messages" to set t2 to name of front window
                end try
                if t2 is "" then
                    my ripristina(appuntiPrima)
                    return "SENZATITOLO"
                end if
                my ripristina(appuntiPrima)
                return "CHAT:" & t2
            end if
            -- 3) il cursore deve essere nel corpo: si verifica incollando un sondaggio
            --    e rileggendolo. Finche' non torna, niente Cmd+A: fuori dal corpo
            --    vorrebbe dire selezionare le conversazioni e cancellarle.
            set sonda to "JARVIS-SONDAGGIO"
            set aFuoco to false
            set corpoLetto to ""
            repeat 3 times
                set the clipboard to sonda
                tell application "System Events"
                    tell process "Messages"
                        key code 48
                        delay 0.5
                        keystroke "v" using command down
                        delay 0.5
                        keystroke "a" using command down
                        keystroke "c" using command down
                        delay 0.4
                    end tell
                end tell
                set corpoLetto to ""
                try
                    set corpoLetto to (the clipboard as text)
                end try
                if corpoLetto contains sonda then
                    set aFuoco to true
                    exit repeat
                end if
            end repeat
            if not aFuoco then
                my ripristina(appuntiPrima)
                return "FOCOCORPO"
            end if
            -- 4) la bozza dell'utente non si tocca: se nel campo c'era altro mi fermo,
            --    pero' adesso il focus e' provato e il mio sondaggio lo pulisco
            -- il Tab pu' finire dentro il campo come carattere: si confronta senza
            -- spazi bianchi, altrimenti una casella vuota sembra una bozza
            set corpoSenzaBianchi to my togliBianchi(corpoLetto)
            if corpoSenzaBianchi is not sonda then
                -- Qui c'era Cmd+A + cancella: cancellava DAVVERO la bozza, mentre il
                -- messaggio all'utente diceva "non ci ho scritto sopra". Ora si annulla
                -- solo l'incolla del sondaggio, e la bozza resta com'era.
                tell application "System Events"
                    tell process "Messages"
                        keystroke "z" using command down
                        delay 0.3
                    end tell
                end tell
                my ripristina(appuntiPrima)
                set coda to corpoSenzaBianchi
                if (count of coda) > 40 then set coda to (text 1 thru 40 of coda)
                return "BOZZA:" & coda
            end if
            -- il corpo non si digita, si incolla: accenti, emoji e apostrofi restano
            -- identici a quello che ho scritto io, e poi lo si puo' rileggere
            tell application "System Events"
                tell process "Messages"
                    keystroke "a" using command down
                    key code 51
                    delay 0.3
                end tell
            end tell
            set the clipboard to corpo
            tell application "System Events"
                tell process "Messages"
                    keystroke "v" using command down
                    delay 0.7
                    keystroke "a" using command down
                    keystroke "c" using command down
                    delay 0.5
                end tell
            end tell
            set letto to ""
            try
                set letto to (the clipboard as text)
            end try
            if letto is not corpo then
                my ripristina(appuntiPrima)
                return "FUORIPOSTO"
            end if
            if premi is not "invia" then
                my ripristina(appuntiPrima)
                return "SCRITTO"
            end if
            tell application "System Events"
                tell process "Messages"
                    key code 36
                end tell
            end tell
            delay 1.8
            set the clipboard to "JARVIS-CAMPO-VUOTO"
            tell application "System Events"
                tell process "Messages"
                    keystroke "a" using command down
                    keystroke "c" using command down
                end tell
            end tell
            delay 0.6
            set dopo to ""
            try
                set dopo to (the clipboard as text)
            end try
            my ripristina(appuntiPrima)
            if dopo is corpo then return "SCRITTO-DENTRO"
            return "SCRITTO-PARTITO"
        end run

        -- Con un NUMERO Messages apre la chat di quel numero e nel titolo ci mette il
        -- nome del contatto ("Mario Rossi"), non le cifre: quindi per i numeri
        -- conta che il chip si sia chiuso (titolo diverso da "Messaggi"), per i nomi
        -- che il titolo li contenga davvero.
        on chatTitolGiusto(titolo, cerca, cercaNome, tipo)
            if titolo is "" or titolo is "Messaggi" then return false
            set t to my eliminaSpazi(titolo)
            if tipo is "numero" then
                if (count of t) > 1 then return true
                return false
            end if
            if t contains cerca then return true
            if cercaNome is not "" and t contains cercaNome then return true
            return false
        end chatTitolGiusto

        on ripristina(appunti)
            try
                set the clipboard to appunti
            end try
        end ripristina

        -- toglie spazi, tab e a capo da entrambi i lati
        on togliBianchi(x)
            set fuori to x as text
            repeat while (count of fuori) > 0 and ((item 1 of fuori is " ") or (item 1 of fuori is tab) or (item 1 of fuori is return) or (item 1 of fuori is linefeed))
                set fuori to (text 2 thru -1 of fuori)
            end repeat
            repeat while (count of fuori) > 0 and ((item -1 of fuori is " ") or (item -1 of fuori is tab) or (item -1 of fuori is return) or (item -1 of fuori is linefeed))
                set fuori to (text 1 thru -2 of fuori)
            end repeat
            return fuori
        end togliBianchi

        on eliminaSpazi(s)
            set AppleScript's text item delimiters to " "
            set parti to text items of s
            set AppleScript's text item delimiters to ""
            set fuori to parti as text
            set AppleScript's text item delimiters to ""
            return fuori
        end eliminaSpazi
        """
        let esito = await AppleScript.run(script, argomenti: [destinatario, testo, invio ? "invia" : "",
                                                              eUnNumero ? "" : nomeUmano,
                                                              eUnNumero ? "numero" : "nome"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Qualunque sia l'esito la sua finestra torna dove stava: il "set visible ...
        // false" dentro allo script serviva a far arrivare i tasti, non a lasciargli le
        // app nascoste. Si rimette a posto anche quando il messaggio fallisce.
        Silenzio.rimettiAPosto(davanti: schermoPrima,
                               nascondi: messaggiEraAperta ? nil : "com.apple.MobileSMS")

        switch esito {
        case "SCRITTO":
            registraInvio(a: a, testo: testo, esito: "scritto, non inviato")
            return "SCRITTO MA NON INVIATO: destinatario e testo al posto giusto (l'ho riletto nel campo). Premi invio tu quando vuoi."
        case "FUORIPOSTO":
            return "NON INVIATO: il testo non e' nel campo del messaggio, quindi non ho premuto invio. Apri Messaggi e guarda dove e' finito."
        case "SENZATITOLO":
            return "NON INVIATO: Messaggi non mi fa vedere il titolo della chat, quindi non ho la certezza di dove sto scrivendo."
        case "FOCOCORPO":
            return "NON INVIATO: non sono riuscito a portare il cursore nel campo del messaggio, quindi non ho scritto niente. Apri la chat e riprova."
        case let x where x.hasPrefix("CHAT:"):
            return "NON INVIATO: la chat aperta non e' quella di \(destinatario) (il titolo dice «\(x.dropFirst(5))»). Non ho scritto niente."
        case let x where x.hasPrefix("BOZZA:"):
            return "NON INVIATO: nel campo c'era gia' una tua bozza («\(x.dropFirst(6))»). Non ci ho scritto sopra."
        case let x where x.hasPrefix("FOCUS:"):
            let davanti = x.replacingOccurrences(of: "FOCUS:", with: "")
            return "NON INVIATO: Messaggi non e' venuto fuori (\(davanti) e' davanti a lui). Non ho scritto niente da nessuna parte: chiudi quella finestra e riprova."
        case "SCRITTO-DENTRO", "SCRITTO-PARTITO":
            let risposta = await confermaInvio(a: a, testo: testo,
                                               campoSvuotato: esito == "SCRITTO-PARTITO", dopoId: idPrima)
            registraInvio(a: a, testo: testo,
                          esito: risposta.hasPrefix("NON INVIATO") ? "dubbio: non l'ho trovato" : "inviato")
            return risposta
        default:
            return "Non sono riuscito a scrivere il messaggio: \(esito.prefix(160))"
        }
    }

    /// Il registro di cosa e' partito davvero (`~/.jarvis/logs/invii.jsonl`).
    /// Serve all'utente per verificare senza fidarsi, e a noi per capire i «NON INVIATO»:
    /// prima l'unica prova era la memoria della chat.
    private static func registraInvio(a: String, testo: String, esito: String) {
        let url = AppPaths.jarvisRoot.appendingPathComponent("logs/invii.jsonl")
        let riga: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()),
                                   "a": a,
                                   "testo": String(testo.prefix(200)),
                                   "esito": esito]
        guard let dati = try? JSONSerialization.data(withJSONObject: riga, options: [.sortedKeys]),
              let linea = String(data: dati, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let maniglia = try? FileHandle(forWritingTo: url) {
            maniglia.seekToEndOfFile()
            maniglia.write((linea + "\n").data(using: .utf8)!)
            try? maniglia.close()
        } else {
            try? (linea + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// "mandato" non lo si dice per fede. L'archivio del Mac e' la prova vera; il
    /// campo che si svuota e' la riserva quando l'archivio non e' leggibile.
    private static func confermaInvio(a: String, testo: String, campoSvuotato: Bool, dopoId: Int) async -> String {
        for _ in 0..<4 {
            if inArchivio(testo, dopoId: dopoId) == true {
                return "Messaggio partito per \(a): l'ho letto nell'archivio dei messaggi."
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if let risulta = inArchivio(testo, dopoId: dopoId), !risulta {
            return "NON INVIATO: ho premuto invio ma nell'archivio il messaggio a \(a) non c'e'. Apri la chat e controlla: non voglio dirti bugie."
        }
        if campoSvuotato {
            return "INVIATO (da verificare): ho premuto invio e il campo del messaggio e' rimasto vuoto, quindi dovrebbe essere partito per \(a). "
                + "La conferma scritta nell'archivio arriva quando mi dai Accesso completo al disco (permessi azione=apri_disco)."
        }
        return "NON INVIATO: il testo e' ancora nel campo, quindi l'invio non e' partito. Apri la chat con \(a) e premi invio."
    }

    /// True se nell'archivio c'e' gia' una conversazione con questa persona.
    static func giaParlato(con destinatario: String) -> Bool {
        let chiave = destinatario.trimmingCharacters(in: .whitespaces)
        guard chiave.count >= 3 else { return false }
        let numero = chiave.filter { "+0123456789".contains($0) }.count >= 8
            ? chiave : (numeroDi(chiave) ?? Anagrafica.numeroPer(chiave)?.numero ?? "")
        let cifre = numero.filter { $0.isNumber }
        let sfondo = Memory.senzaAccenti(chiave)
        let righe = query("""
            SELECT COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id, ''), COALESCE(c.chat_identifier, '')
            FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            ORDER BY m.ROWID DESC LIMIT 500;
            """) ?? []
        for r in righe where r.count >= 2 {
            let riga = r.joined(separator: " ")
            if cifre.count >= 8, riga.filter({ $0.isNumber }).count >= 8,
               Memory.senzaAccenti(riga).contains(cifre) { return true }
            if Memory.senzaAccenti(riga).contains(sfondo) { return true }
        }
        return false
    }

    /// La conversazione con una persona (nome o numero che sia), scritta perbene:
    /// serve perche' «leggi la chat e rispondi» deve poter appoggiarsi a testo vero,
    /// non inventare la risposta.
    static func cronologiaPer(_ destinatario: String, limite: Int = 8) -> String {
        let chiave = destinatario.trimmingCharacters(in: .whitespaces)
        guard !chiave.isEmpty else { return "Dimmi di chi devo leggere la chat." }
        let numero = chiave.filter { "+0123456789".contains($0) }.count >= 8
            ? chiave : (numeroDi(chiave) ?? Anagrafica.numeroPer(chiave)?.numero ?? "")
        let sfondo = Memory.senzaAccenti(chiave)
        // filtro per CHAT (chat_identifier), non solo per mittente: prima era uscito
        // fuori il thread di un'altra persona
        let righe = query("""
            SELECT m.is_from_me, COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id, 'ignoto'),
                   COALESCE(m.text, ''), COALESCE(hex(m.attributedBody), ''), m.ROWID,
                   COALESCE(c.chat_identifier, '')
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            ORDER BY m.ROWID DESC LIMIT 260;
            """) ?? []
        var fuori: [String] = []
        for r in righe where r.count >= 6 {
            let chi = r[1]
            let identificatore = Memory.senzaAccenti(r[5])
            let combacia: Bool
            if !numero.isEmpty {
                let cifre = numero.filter { $0.isNumber }
                combacia = (!cifre.isEmpty && identificatore.contains(cifre)) || Anagrafica.stessoNumero(chi, numero)
            } else {
                combacia = Memory.senzaAccenti(chi).contains(sfondo)
            }
            guard combacia else { continue }
            let daMe = r[0] == "1"
            let testo = pulisci(testoDi(r[3], r[2]))
            guard !testo.isEmpty else { continue }
            fuori.append("\(daMe ? "tu" : chi): \(testo.prefix(240))")
            if fuori.count >= limite { break }
        }
        guard !fuori.isEmpty else { return "Non trovo messaggi con \(chiave) nell'archivio." }
        let cronologia = fuori.reversed().joined(separator: "\n")
        GuardiaMessaggio.segnalaInvito(cronologia)
        Cose.autoCattura(cronologia, da: chiave)
        return cronologia
    }

    /// Cerca il testo tra i messaggi usciti negli ultimi 5 minuti.
    /// nil = non posso leggere l'archivio (manca l'Accesso completo al disco).
    static func inArchivio(_ testo: String, dopoId: Int = 0) -> Bool? {
        guard let righe = query("""
            SELECT COALESCE(m.text, ''), COALESCE(hex(m.attributedBody), '')
            FROM message m WHERE m.is_from_me = 1 AND m.ROWID > \(dopoId)
            ORDER BY m.ROWID DESC LIMIT 20;
            """) else { return nil }
        let cerca = Self.pulisci(testo)
        guard cerca.count >= 3 else { return nil }
        let testa = String(cerca.prefix(30))
        for r in righe where r.count >= 2 {
            let letto = Self.pulisci(Self.testoDi(r[1], r[0]))
            if letto == cerca || letto.contains(testa) { return true }
        }
        return false
    }


    /// Controllo a schermo: l'albero dell'interfaccia di Messaggi non e' raggiungibile
    /// (nessuno dei sei percorsi classici esiste su macOS 26), quindi si guarda lo
    /// schermo col modello visivo, come farebbe una persona.
    static func verificaSchermo(_ domanda: String) async -> Bool {
        guard await Brain.shared.visionModel() != nil else { return true }   // senza vista: non bloccare
        let f = AppPaths.tmp.appendingPathComponent("msg-check-\(Int(Date().timeIntervalSince1970)).png")
        _ = await Shell.run("/usr/sbin/screencapture", ["-x", f.path])
        guard FileManager.default.fileExists(atPath: f.path) else { return false }
        let visto = await Brain.shared.askVision(image: f, prompt:
            "Guarda la finestra dell'app Messaggi nello schermo. Rispondi con una sola parola, SI o NO. \(domanda)")
        try? FileManager.default.removeItem(at: f)
        return visto.uppercased().contains("SI")
    }

    /// Apre una chat iMessage (o SMS) con un numero.
    static func apriChat(_ destinatario: String) -> String {
        let pulito = destinatario.replacingOccurrences(of: " ", with: "")
        guard let u = URL(string: "imessage://" + pulito) else { return "Destinatario non valido." }
        NSWorkspace.shared.open(u)
        return "Ho aperto la conversazione con \(destinatario) in Messaggi."
    }

    /// Invio con AppleScript: chiede il permesso "Controllo di Messaggi" la prima volta.
    static func inviaMessaggio(_ destinatarioBruto: String, _ testo: String) async -> String {
        let destinatario = GuardiaMessaggio.destinatarioVero(per: destinatarioBruto,
                                                             chiesto: Agent.richiestaCorrente)
        let script = """
        on run argv
            set destinatario to item 1 of argv
            set corpo to item 2 of argv
            tell application "Messages"
                set b to buddy destinatario of (service 1 whose its type is iMessage service type)
                if b is missing value then error "contatto non trovato"
                send corpo to b
            end tell
            return "inviato"
        end run
        """
        let outo = await AppleScript.run(script, argomenti: [destinatario, testo])
        if outo.contains("inviato") { return "Messaggio mandato a \(destinatario)." }
        if outo.lowercased().contains("not authorized") || outo.contains("Non autorizzat") {
            return "Il Mac non mi ha ancora lasciato comandare Messaggi: te lo chiede a schermo, digli di sì."
        }
        return "Non sono riuscito a mandarlo: \(outo.prefix(160))"
    }
}

/// Mail: la strada principale e' Microsoft Outlook (che sul Mac dell'utente ha il
/// dizionario AppleScript), con Mail.app come riserva. Account e password restano
/// nell'app: da qui passa solo lo script, mai una credenziale.
enum Mail {
    static let outlookApp = "/Applications/Microsoft Outlook.app"
    static var outlookPronto: Bool { FileManager.default.fileExists(atPath: outlookApp) }

    /// "data | mittente | oggetto" per ogni mail non letta.
    static func nonLette(limit: Int = 8) async -> String {
        if outlookPronto {
            let script = """
            on run argv
                set massimo to (item 1 of argv) as integer
                tell application "Microsoft Outlook"
                    set outo to {}
                    repeat with acc in accounts
                        try
                            repeat with m in (messages of inbox of acc whose is read is false)
                                if (count of outo) >= massimo then exit repeat
                                set chi to "?"
                                try
                                    set chi to address of email address of sender of m
                                end try
                                set end of outo to ((time received of m) as string) & " | " & chi & " | " & (subject of m)
                            end repeat
                        end try
                    end repeat
                    set text item delimiters to linefeed
                    return outo as text
                end tell
            end run
            """
            let o = await AppleScript.run(script, argomenti: ["\(max(1, min(limit, 25)))"])
            if o.lowercased().contains("error") || o.lowercased().contains("not authorized") {
                return "Outlook non mi lascia leggere: \(o.prefix(140))"
            }
            if o.isEmpty { return "Nessuna mail non letta in Outlook." }
            return o
        }
        return await nonLetteMailApp(limit: limit)
    }

    /// Quante non lette in tutto: costa poco e serve all'orecchio. -1 = non so.
    static func contoNonLette() async -> Int {
        guard outlookPronto else { return -1 }
        let script = """
        tell application "Microsoft Outlook"
            set tot to 0
            repeat with acc in accounts
                try
                    set tot to tot + (unread count of inbox of acc)
                end try
            end repeat
            return tot
        end tell
        """
        let o = await AppleScript.run(script)
        return Int(o.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Il corpo della ennesima non letta (1 = la piu' vecchia rimasta da leggere).
    /// Riassunto della posta non letta. La roba sua non sale sul cloud: il riassunto
    /// lo fa il modello locale, anche a batteria (meglio la batteria che la privacy).
    static func riassumi() async -> String {
        let elenco = await Mail.nonLette()
        let daAltraFonte = await Graph.nonLette()
        let base = (elenco.lowercased().contains("non sei collegato") || elenco.lowercased().contains("nessun account")
                    || elenco.lowercased().contains("nessuna casella")) ? daAltraFonte : elenco
        let righe = base.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let bassa = base.lowercased()
        guard !righe.isEmpty, !bassa.contains("non sei collegato"), !bassa.contains("nessuna casella"),
              !bassa.contains("non ha una casella") else {
            return "Non ho una casella da cui leggere: dimmi \u{00ab}accedi alla mail\u{00bb} e ti do il codice corto da "
                + "digitare su microsoft.com/link dal telefono. Appena e' collegato questo pulsante funziona, "
                + "e il riassunto resta sul Mac."
        }
        let corpo = String(righe.prefix(12).joined(separator: "\\n").prefix(3000))
        let prompt = [ChatTurn(role: "system",
                               content: "Sei \(Marca.nome). Riassumi la posta non letta di \(Identita.nome) in 3-4 righe: chi scrive, cosa vuole, cosa va fatto. Italiano, senza inventare nulla."),
                      ChatTurn(role: "user", content: corpo)]
        var out = ""
        if let risposta = try? await Brain.shared.stream(turns: prompt, tools: [], onDelta: { _ in }) {
            out = risposta.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.isEmpty { return "Il riassunto non e' venuto fuori, le non lette sono:\\n" + corpo }
        return out + "\\n\\n(" + String(righe.count) + " non lette)"
    }

    static func corpo(_ numero: Int) async -> String {
        if outlookPronto {
            let script = """
            on run argv
                set idx to (item 1 of argv) as integer
                tell application "Microsoft Outlook"
                    set contatore to 0
                    repeat with acc in accounts
                        try
                            repeat with m in (messages of inbox of acc whose is read is false)
                                set contatore to contatore + 1
                                if contatore = idx then
                                    return (subject of m) & linefeed & (plain text content of m)
                                end if
                            end repeat
                        end try
                    end repeat
                end tell
                return "non ci sono tante mail non lette"
            end run
            """
            let o = await AppleScript.run(script, argomenti: ["\(max(1, numero))"])
            return o.isEmpty ? "Non sono riuscito a leggere il contenuto." : String(o.prefix(3000))
        }
        return await corpoMailApp(numero)
    }

    static func scrivi(a: String, oggetto: String, testo: String, invio: Bool) async -> String {
        guard !a.isEmpty else { return "Dimmi a chi mandarla." }
        if outlookPronto {
            let script = """
            on run argv
                set destinatario to item 1 of argv
                set oggetto to item 2 of argv
                set corpo to item 3 of argv
                set modo to item 4 of argv
                tell application "Microsoft Outlook"
                    set nuovo to make new outgoing message with properties {subject:oggetto, plain text content:corpo}
                    tell nuovo to make new to recipient at recipients with properties {email address:{address:destinatario}}
                    if modo is "invia" then
                        send nuovo
                        return "inviata"
                    else
                        open nuovo
                        return "bozza aperta"
                    end if
                end tell
            end run
            """
            let o = await AppleScript.run(script, argomenti: [a, oggetto, testo, invio ? "invia" : ""])
            if o.contains("inviata") { return "Mail a \(a) spedita con Outlook." }
            if o.contains("bozza aperta") { return "Bozza pronta in Outlook: leggila e premi invio tu." }
            if o.lowercased().contains("not authorized") {
                return "Il Mac non mi ha ancora lasciato comandare Outlook: accetta la richiesta a schermo."
            }
            return "Outlook non ha mandato: \(o.prefix(150))"
        }
        return await scriviMailApp(a: a, oggetto: oggetto, testo: testo, invio: invio)
    }

    // MARK: - riserva su Mail.app (per quando avra' una casella li')

    static func nonLetteMailApp(limit: Int = 8) async -> String {
        let script = """
        tell application "Mail"
            set out to {}
            repeat with acc in accounts
                repeat with mb in mailboxes of acc
                    if name of mb is in {"Inbox", "Posta in arrivo"} then
                        repeat with m in (messages of mb whose unread is true)
                            if (count of out) < \(max(1, min(limit, 25))) then
                                set end of out to (date received of m as string) & " | " & sender of m & " | " & subject of m
                            end if
                        end repeat
                    end if
                end repeat
            end repeat
            set text item delimiters to linefeed
            return out as text
        end tell
        """
        let o = await AppleScript.run(script)
        if o.isEmpty { return "Nessuna mail non letta, e Outlook non e' disponibile." }
        if o.lowercased().contains("not authorized") { return "Devi autorizzare \(Marca.nome) a controllare Mail.app." }
        return o
    }

    static func corpoMailApp(_ numero: Int) async -> String {
        let script = """
        tell application "Mail"
            set msgs to (messages of mailbox "Inbox" of application account 1 whose unread is true)
            if \(numero) > (count of msgs) then return "non ci sono \(numero) messaggi non letti"
            set m to item \(numero) of msgs
            return (subject of m) & linefeed & (content of m)
        end tell
        """
        let o = await AppleScript.run(script)
        return o.isEmpty ? "Non sono riuscito a leggere il contenuto." : String(o.prefix(3000))
    }

    static func scriviMailApp(a: String, oggetto: String, testo: String, invio: Bool) async -> String {
        let script = """
        on run argv
            set destinatario to item 1 of argv
            set oggetto to item 2 of argv
            set corpo to item 3 of argv
            tell application "Mail"
                set m to make new outgoing message with properties {subject:oggetto, content:corpo, visible:true}
                tell m to make new to recipient at end of to recipients with properties {address:destinatario}
                if item 4 of argv is "invia" then send m
                return "pronta"
            end tell
        end run
        """
        let o = await AppleScript.run(script, argomenti: [a, oggetto, testo, invio ? "invia" : ""])
        if o.contains("pronta") {
            return invio ? "Mail a \(a) spedita." : "Mail a \(a) scritta e lasciata aperta: controllala e premi invio tu."
        }
        return "Non sono riuscito a preparare la mail: \(o.prefix(160))"
    }
}

/// Piccolo helper per lanciare AppleScript con argomenti senza mettere testo nella riga di comando.
enum AppleScript {
    static func run(_ script: String, argomenti: [String] = []) async -> String {
        let file = AppPaths.tmp.appendingPathComponent("script-\(UUID().uuidString).scpt.txt")
        do { try script.write(to: file, atomically: true, encoding: .utf8) } catch { return "script non salvabile" }
        defer { try? FileManager.default.removeItem(at: file) }
        var args = [file.path]
        args.append(contentsOf: argomenti)
        let outo = await Shell.run("/usr/bin/osascript", args, timeout: 60)
        return outo.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// WhatsApp: niente comandi disponibili, quindi link + tastiera.
enum WhatsApp {
    static func numeroPulito(_ raw: String) -> String {
        var n = raw.filter { $0.isNumber || $0 == "+" }
        if n.hasPrefix("0039") { n = "+" + n.dropFirst(2) }
        if !n.hasPrefix("+") && n.count >= 9 { n = "+39" + n }
        return n
    }

    /// Apre la chat con il testo gia' scritto. Con `invio` preme anche Invio
    /// (serve il permesso Accessibilita', altrimenti resta da premere a lui).
    static func invia(numero: String, testo: String, invio: Bool) async -> String {
        let n = numeroPulito(numero)
        let codificato = testo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let u = URL(string: "whatsapp://send?phone=\(n)&text=\(codificato)") else {
            return "Non riesco a preparare il link di WhatsApp."
        }
        NSWorkspace.shared.open(u)
        guard invio else {
            return "Ho aperto WhatsApp con il messaggio pronto per \(n): premi invio tu."
        }
        guard Capacita.accessibilita else {
            return "Ho aperto WhatsApp con il messaggio pronto, ma per premere Invio serve Accessibilita' (permessi azione=chiedi_accessibilita)."
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let script = """
        tell application "System Events"
            tell process "WhatsApp" to key code 36
        end tell
        """
        let outo = await AppleScript.run(script)
        return outo.lowercased().contains("error")
            ? "Ho scritto il messaggio ma non sono riuscito a premere Invio: \(outo.prefix(120))"
            : "Messaggio WhatsApp mandato a \(n)."
    }

    /// Per leggere WhatsApp non c'e' API: si guarda lo schermo col modello visivo.
    static func leggiSchermo(domanda: String) async -> String {
        await Tools.shared.run("leggi_schermo", ["domanda": "Nella finestra di WhatsApp: " + domanda])
    }
}

/// L'orecchio: controlla ogni tanto se sono arrivati messaggi e li legge ad alta voce.
/// iMessage si legge dal database (economico), la mail via Mail.app (pesante, ogni 5 minuti).
/// WhatsApp non ha nessun modo per accorgersi di un messaggio nuovo: li si legge solo
/// guardando lo schermo, e gliel'ho detto chiaro.
@MainActor
final class Orecchio: ObservableObject {
    static let shared = Orecchio()

    @Published var attivo = false
    @Published var ultimoTrovato = Date.distantPast

    /// Scrive nella chat quando annuncia qualcosa.
    var onArrivo: ((String) -> Void)?

    private var timer: Timer?
    private var giaVisti = Set<String>()
    private var ultimoIdVisto = 0
    private var mailPrecedenti = -1
    private var ultimoControlloMail = Date.distantPast

    static var statoFile: URL { AppPaths.jarvisRoot.appendingPathComponent("avvisi-messaggi.txt") }

    private init() {
        attivo = ((try? String(contentsOf: Self.statoFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "acceso"
    }

    func accendi() -> String {
        attivo = true
        ultimoIdVisto = Messaggi.ultimoId()
        giaVisti = []
        try? "acceso".write(to: Self.statoFile, atomically: true, encoding: .utf8)
        timer?.invalidate()
        avviaTimer()
        let disco = Capacita.discoCompleto
        return "Orecchio acceso: ti leggo i messaggi che arrivano." + (disco ? ""
            : " Pero' adesso non posso leggere iMessage perche' manca «Accesso completo al disco».")
    }

    /// Il giro dell'orecchio. La differenza con prima è che **il timer non viene
    /// messo in pausa dentro la callback**: se non deve girare, non viene proprio
    /// creato, perché svegliarsi ogni 20 secondi per dire "adesso non guardo" è
    /// esattamente il consumo che gli dà fastidio.
    private func avviaTimer() {
        let t = Timer(timeInterval: 20, repeats: true) { _ in
            Task { @MainActor in
                await Orecchio.shared.controlla()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Sospende senza scordare: resta "acceso" per lui, ma il Mac non viene svegliato.
    @MainActor func sospendi() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor func riprendi() {
        guard attivo, timer == nil else { return }
        avviaTimer()
    }

    func spegni() -> String {
        attivo = false
        timer?.invalidate()
        timer = nil
        try? "spento".write(to: Self.statoFile, atomically: true, encoding: .utf8)
        return "Orecchio spento: non ti interrompo piu' per i messaggi."
    }

    var stato: String {
        guard attivo else { return "Orecchio spento." }
        return "Orecchio acceso, ultimo controllo "
            + (ultimoTrovato == .distantPast ? "mai" : Self.ora(ultimoTrovato))
            + ". iMessage: \(Capacita.discoCompleto ? "leggibile" : "serve Accesso completo al disco")."
    }

    private static func ora(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    func controlla() async {
        guard attivo else { return }
        ultimoTrovato = Date()

        if ultimoIdVisto == 0 { ultimoIdVisto = Messaggi.ultimoId() }
        for nuovo in Messaggi.daAnnunciare(dopoId: ultimoIdVisto) {
            let chiave = nuovo.chi + "|" + Messaggi.pulisci(nuovo.testo)
            guard !giaVisti.contains(chiave) else { ultimoIdVisto = max(ultimoIdVisto, nuovo.id); continue }
            giaVisti.insert(chiave)
            ultimoIdVisto = max(ultimoIdVisto, nuovo.id)
            let testo = Messaggi.pulisci(nuovo.testo)
            let chi = Messaggi.nomeDi(nuovo.chi) ?? nuovo.chi
            let riga = "Messaggio da \(chi): \(testo)"
            onArrivo?(riga)
            // detto a voce: il nome, non il numero (+39351… ad alta voce e' illeggibile)
            JarvisCore.shared.dillo("Messaggio da \(chi). \(testo)")
        }

        // la mail costa uno script: la guardio ogni 5 minuti, non ogni 20 secondi
        if Date().timeIntervalSince(ultimoControlloMail) > 300 {
            ultimoControlloMail = Date()
            let quante = await Mail.contoNonLette()
            guard quante >= 0 else { return }
            if mailPrecedenti >= 0 && quante > mailPrecedenti {
                let nuove = quante - mailPrecedenti
                let elenco = await Mail.nonLette(limit: nuove)
                onArrivo?("Sono arrivate \(nuove) mail nuove.\n\(elenco.prefix(600))")
                JarvisCore.shared.dillo("Sono arrivate \(nuove) mail nuove.")
            }
            mailPrecedenti = quante
        }
    }
}

// MARK: - gambe per il modello

extension Tools {
    static func messaggiSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        let quanti = Int(a("numero").filter { $0.isNumber }) ?? 10
        switch a("azione") {
        case "ultimi":
            GuardiaMessaggio.haLettoChat = true
            let out = Messaggi.ultimi(limit: quanti)
            GuardiaMessaggio.segnalaInvito(out)
            Cose.autoCattura(out, da: "")
            return out
        case "non_letti":
            GuardiaMessaggio.haLettoChat = true
            let tutto = Messaggi.ultimi(limit: max(quanti, 15))
            GuardiaMessaggio.segnalaInvito(tutto)
            let nonLetti = tutto.components(separatedBy: .newlines).filter { $0.contains("[NON LETTO]") }
            return nonLetti.isEmpty ? "Nessun messaggio da leggere: sono tutti visti." : nonLetti.joined(separator: "\n")
        case "apri":
            guard !a("a").isEmpty else { return "Dimmi a chi aprire la chat." }
            return Messaggi.apriChat(a("a"))
        case "invia":
            guard !a("a").isEmpty, !a("testo").isEmpty else { return "Servono destinatario e testo." }
            if let oltre = LimitiMessaggio.verifica(a("testo"), destinatario: a("a")) {
                return oltre
            }
            // testo non dettato dall'utente = roba sua: non parte senza il suo clic
            // con uno che l'utente conosce gia' parte da solo: la card bloccava tutto
            if !LimitiMessaggio.dettatoDallUtente(a("testo"), richiesta: Agent.richiestaCorrente),
               !LimitiMessaggio.conosciuto(a("a")) {
                let ok = await Tools.confirm?("Messaggio a \(a("a")): \(a("testo"))") ?? false
                if !ok { return "NON INVIATO: \(Identita.nome) non ha confermato questo testo." }
            }
            if let bloccato = GuardiaMessaggio.blocca(a("testo"), destinatario: a("a"),
                                                      richiesta: Agent.richiestaCorrente) {
                // "leggi e rispondi" non puo' fallire due volte: qui dentro c'e' gia' la
                // conversazione vera, cosi' il prossimo giro risponde al contenuto reale
                let appoggio = Messaggi.cronologiaPer(a("a"), limite: 6)
                GuardiaMessaggio.haLettoChat = true
                return bloccato + "\n\nCRONOLOGIA CON «" + a("a") + "» (ultima in basso):\n" + appoggio
            }
            if let fermato = GuardiaMessaggio.testFuoriDaiPermessi(a("testo"), destinatario: a("a")) {
                return fermato
            }
            // prima l'AppleScript; su questo Mac di solito fallisce (-1728),
            // e allora tocca alla tastiera, che invece funziona
            let provato = await Messaggi.inviaMessaggio(a("a"), a("testo"))
            if provato.contains("mandato") { return provato }
            return await Messaggi.inviaConTastiera(a: a("a"), testo: a("testo"), invio: true)
        default:
            return "Azioni: ultimi, non_letti, apri, invia."
        }
    }

    static func mailSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "accedi":
            return await Graph.richiediCodice()
        case "login_fatto":
            return await Graph.completaAccesso()
        case "stato_login":
            return Graph.stato()
        case "non_lette":
            let locale = await Mail.nonLette()
            // Outlook sul Mac non ha casella: se non ha dato niente, prova con Microsoft
            if Mail.outlookPronto == false || locale.lowercased().contains("nessuna mail non letta")
                || locale.lowercased().contains("non ha mandato") || locale.lowercased().contains("outlook non") {
                let daGraph = await Graph.nonLette()
                if !daGraph.lowercased().contains("non sei collegato") { return daGraph }
            }
            return locale
        case "corpo":
            let n = max(1, Int(a("quale").filter { $0.isNumber }) ?? 1)
            return await Graph.corpo(n)
        case "riassumi":
            return await Mail.riassumi()
        case "scrivi":
            if let oltre = LimitiMessaggio.verifica(a("testo"), destinatario: a("a")) { return oltre }
            if a("invia") == "si", !LimitiMessaggio.dettatoDallUtente(a("testo"), richiesta: Agent.richiestaCorrente) {
                let ok = await Tools.confirm?("Mail a \(a("a")): \(a("oggetto")) — \(a("testo"))") ?? false
                if !ok { return "NON INVIATO: \(Identita.nome) non ha confermato questa mail." }
            }
            if let bloccato = GuardiaMessaggio.blocca(a("testo"), destinatario: a("a"),
                                                      richiesta: Agent.richiestaCorrente) {
                return bloccato
            }
            let scritto = await Mail.scrivi(a: a("a"), oggetto: a("oggetto"), testo: a("testo"),
                                            invio: a("invia") == "si")
            if scritto.lowercased().contains("outlook non ha mandato") || scritto.lowercased().contains("non ha ancora") {
                return await Graph.scrivi(a: a("a"), oggetto: a("oggetto"), testo: a("testo"),
                                          invio: a("invia") == "si")
            }
            return scritto
        default:
            return "Azioni: non_lette, corpo, scrivi, accedi, login_fatto, stato_login."
        }
    }

    static func whatsappSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "apri":
            return await WhatsApp.invia(numero: a("numero"), testo: a("testo"), invio: false)
        case "manda":
            guard !a("testo").isEmpty else { return "Dimmi cosa scrivere." }
            return await WhatsApp.invia(numero: a("numero"), testo: a("testo"), invio: true)
        case "leggi":
            return await WhatsApp.leggiSchermo(domanda: a("domanda").isEmpty
                                               ? "qual e l'ultimo messaggio ricevuto e cosa dice"
                                               : a("domanda"))
        default:
            return "Azioni: apri, manda, leggi."
        }
    }

    static func orecchioSkill(_ args: [String: Any]) async -> String {
        let azione = (args["azione"] as? String) ?? "stato"
        switch azione {
        case "accendi": return await MainActor.run { Orecchio.shared.accendi() }
        case "spegni": return await MainActor.run { Orecchio.shared.spegni() }
        default: return await MainActor.run { Orecchio.shared.stato }
        }
    }

    static func permessiSkill(_ azione: String) -> String {
        switch azione {
        case "apri_disco": return Capacita.apriPannello("disco")
        case "apri_accessibilita": return Capacita.apriPannello("accessibilita")
        case "chiedi_accessibilita":
            Capacita.chiediAccessibilita()
            return "Ho fatto comparire la richiesta: metti la spunta su \(Marca.nome) in Accessibilita' e poi riavviarmi."
        default: return Capacita.statoPermessi()
        }
    }
}

extension Data {
    /// Decodifica l'hex che restituisce `sqlite3 hex(...)`: niente API private.
    init?(hexa raw: String) {
        let hex = raw.lowercased().filter { $0.isNumber || ("abcdef".contains($0)) }
        guard !hex.isEmpty, hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var indice = hex.startIndex
        while indice < hex.endIndex {
            let prossimo = hex.index(indice, offsetBy: 2)
            guard let b = UInt8(hex[indice..<prossimo], radix: 16) else { return nil }
            bytes.append(b)
            indice = prossimo
        }
        self.init(bytes)
    }
}
