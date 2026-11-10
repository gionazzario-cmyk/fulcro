import AppKit
import Foundation

/// Lo schermo dell'utente non e' di Jarvis.
///
/// La regola che l'utente ha dato il 2026-10-20: «quando usa un'app e io no, l'app non
/// mi si apra sullo schermo». Qui dentro c'e' il modo di rispettarla:
///
/// - **aprire senza venire avanti**: `open -g` non porta l'app in primo piano, e con
///   `-j` (solo quando la app non era gia' aperta) parte senza affacciare le finestre;
/// - **rimettere a posto quello che si e' spostato**: prima di toccare il primo piano si
///   segna chi c'era davanti, e alla fine quell'app torna davanti e le si ridanno le
///   finestre che erano state nascoste. Il percorso dei tasti di Messaggi e' l'unico
///   punto in cui Jarvis DEVE essere in primo piano (altrimenti i tasti finiscono da
///   un'altra parte, che e' peggio), e infatti era quello che nascondeva le sue app e le
///   lasciava nascoste: adesso le restituisce.
///
/// Le azioni che lui chiede per vederle davvero (`app azione=davanti`, `apri` quando
/// dice "aprimi X") restano esplicite: la regola e' "quando Jarvis usa una cosa e io non
/// la sto usando", non "non mostrarmi mai niente".
enum Silenzio {
    /// Chi ha lo schermo adesso. `nil` se non si riesce a sapere: in quel caso non si
    /// tocca niente, perche' "rimettere a posto" alla cieca e' peggio di non farlo.
    static func frontale() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    /// Vero se la app era gia' tra i processi: se c'era, la si lascia dove sta; se non
    /// c'era, e' Jarvis che l'ha fatta comparire e quindi e' Jarvis che la nasconde.
    static func eraGiaAperta(_ bundleId: String) -> Bool {
        let id = bundleId.lowercased()
        return NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").lowercased() == id
        }
    }

    /// Gli argomenti di `open` per non rubare lo schermo. Funzione pura: e' la parte
    /// che si puo' provare davvero senza lanciare niente.
    static func argomentiApri(_ percorso: String, eraGiaAperta: Bool) -> [String] {
        eraGiaAperta ? ["-g", percorso] : ["-gj", percorso]
    }

    /// Il "torna al tuo posto": ri-mostra e ri-attiva quello che era davanti prima che
    /// Jarvis toccasse qualcosa, e nasconde la app che Jarvis ha aperto lui se non ha
    /// finestre da mostrare. `posticipato` perche' macOS deve finire di sistemare il
    /// cambio di primo piano prima che gli si dica il contrario.
    static func rimettiAPosto(davanti a: NSRunningApplication?, nascondi: String? = nil) {
        if let id = nascondi?.lowercased() {
            for processo in NSWorkspace.shared.runningApplications
            where (processo.bundleIdentifier ?? "").lowercased() == id {
                processo.hide()
            }
        }
        guard let a else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            a.unhide()
            a.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Il pacchetto completo per una azione che rischia di portar via lo schermo:
    /// segna chi c'era davanti, esegue, e rimette a posto qualunque sia il risultato.
    @MainActor static func senzaToccareSchermo<A>(_ bundleDaNascondere: String? = nil,
                                                  _ corpo: () async -> A) async -> A {
        let prima = frontale()
        let esito = await corpo()
        rimettiAPosto(davanti: prima, nascondi: bundleDaNascondere)
        return esito
    }

    /// La scelta dell'utente del 2026-10-20, detta due volte: le app **non devono
    /// comparirgli sullo schermo**, lui vuole il resoconto. Quindi l'impostazione di
    /// default e' invisibile, e `app azione=schermo` la cambia quando vuole vederle.
    static var fileScelta: URL { AppPaths.jarvisRoot.appendingPathComponent("schermo.txt") }

    static func vuoleVedereLeApp() -> Bool {
        ((try? String(contentsOf: fileScelta, encoding: .utf8)) ?? "").lowercased().contains("visibile")
    }

    static func cambiaVisibilita(_ scelta: String) -> String {
        let v = scelta.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let testo = (v == "visibile" || v == "fammele" || v == "mostra") ? "visibile\n" : "invisibile\n"
        try? FileManager.default.createDirectory(at: AppPaths.jarvisRoot, withIntermediateDirectories: true)
        do {
            try testo.write(to: fileScelta, atomically: true, encoding: .utf8)
        } catch {
            return "Non sono riuscito a scrivere ~/.jarvis/schermo.txt: \(error.localizedDescription)"
        }
        return testo.trimmingCharacters(in: .newlines) == "visibile"
            ? "Ok: da adesso le app che apro te le mostro."
            : "Ok: da adesso le app le apro in background e ti do solo il resoconto."
    }

    /// Apre senza affacciare niente sullo schermo, e lo dice con il resoconto.
    /// Il `hide()` dopo l'apertura non e' ridondante: `-j` nasconde la app *alla partenza*,
    /// ma alcune finestre si riaffacciano appena il processo e' pronto.
    @MainActor static func apriSenzaMostrare(percorso: String, id: String, nome: String) async -> String {
        let eraAperta = eraGiaAperta(id)
        registra(nil, id: id, nome: nome, motivo: .richiesta, eraAperta: eraAperta)
        let outo = await Shell.run("/usr/bin/open", argomentiApri(percorso, eraGiaAperta: eraAperta), timeout: 20)
        guard outo.isEmpty else { return outo }
        if !vuoleVedereLeApp() {
            for _ in 0..<12 {
                if let p = NSWorkspace.shared.runningApplications.first(where: {
                    ($0.bundleIdentifier ?? "").lowercased() == id.lowercased()
                }) {
                    p.hide()
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let comEra = eraAperta ? "si'" : "no"
        return vuoleVedereLeApp()
            ? "Aperta \(nome) (era gia' aperta: \(comEra))."
            : "\(nome) e' pronta in background: sullo schermo non ti e' comparsa niente. "
                + "Se la vuoi vedere dimmi «metti \(nome) davanti»."
    }

    /// Come si dice all'utente cosa e' successo, senza fargli credere che la app sia
    /// sparita nel nulla: se non era aperta, ora c'e' ma non si vede.
    static func loSchermoRestaTuo(_ nome: String, eraGiaAperta: Bool) -> String {
        eraGiaAperta
            ? "Risveglio \(nome) senza portartela davanti: lo schermo resta il tuo."
            : "Aperta \(nome) in background: non ti compare sullo schermo. "
                + "Se la vuoi vedere di' «metti \(nome) davanti»."
    }
}

extension Silenzio {
    /// Spezza un comando in parole, tenendo insieme quelle tra virgolette.
    static func parole(_ comando: String) -> [String] {
        var fuori: [String] = [], corrente = "", virgolette: Character? = nil
        for c in comando {
            if let v = virgolette {
                if c == v { virgolette = nil } else { corrente.append(c) }
            } else if c == "\"" || c == "'" {
                virgolette = c
            } else if c == " " || c == "\t" {
                if !corrente.isEmpty { fuori.append(corrente); corrente = "" }
            } else {
                corrente.append(c)
            }
        }
        if !corrente.isEmpty { fuori.append(corrente) }
        return fuori
    }

    /// Fa partire la app **senza affacciarla** prima di uno script, perche' AppleScript
    /// la apre lui se non c'e' — e in quel caso la finestra si vede per un attimo prima
    /// che qualcuno la rimandi dietro. Con `-gj` arriva gia' nascosta, e lo script la
    /// trova pronta. Se la app era gia' aperta non si tocca niente: `-j` su una app viva
    /// non fa nulla di utile, e il nascondere dopo basta.
    @MainActor static func lanciaNascosto(_ bundleId: String) async {
        guard !vuoleVedereLeApp(), !eraGiaAperta(bundleId) else { return }
        _ = await Shell.run("/usr/bin/open", ["-g", "-j", "-b", bundleId], timeout: 20)
    }

    /// Il SECONDO buco, aperto la sera del 2026-10-22 da solo: da quando i verbi della
    /// `.sdef` stanno nel prompt, la via che il modello prende per pilotare una app e'
    /// `esegui_comando` con `osascript -e 'tell application "X" to ...'`, e AppleScript
    /// **porta avanti l'app** quando la deve avviare. Non e' un `open`, quindi la rete qui
    /// sopra non la vedeva. nil = non e' uno script che nomina una app: si esegue com'e'.
    static func interpretabileOsascript(_ comando: String, in lista: [SchedaApp]? = nil) -> (id: String, nome: String)? {
        let parti = parole(comando)
        guard parti.count >= 2, ["osascript", "/usr/bin/osascript"].contains(parti[0]) else { return nil }
        // lo script arriva dopo `-e` (o `-f file`): si cerca `tell application "Nome"`
        let testo = parti.enumerated()
            .filter { !$1.hasPrefix("-") && $0 > 0 }
            .map(\.1).joined(separator: " ")
        guard let r = try? NSRegularExpression(pattern: "tell\\s+application\\s+\"([^\"]+)\""),
              let m = r.firstMatch(in: testo, range: NSRange(testo.startIndex..., in: testo)),
              let rango = Range(m.range(at: 1), in: testo) else { return nil }
        let detto = String(testo[rango])
        let inventario = lista ?? InventarioApp.caricato() ?? []
        guard let app = inventario.first(where: {
            $0.id.lowercased() == detto.lowercased()
                || $0.nome.lowercased() == detto.lowercased()
                || senzaSpazi(InventarioApp.nomeCartella($0)) == senzaSpazi(detto)
        }) else { return nil }
        return (app.id, app.nome)
    }

    /// Il buco vero della regola: il modello puo' sempre scrivere `open -a Keka` con
    /// `esegui_comando` e bypassare `apri_app`. Quindi il rispetto dello schermo non puo'
    /// stare nel prompt: deve stare nell'esecuzione. Questa funzione dice come rifare
    /// quell'`open` senza affacciare niente; nil = non e' un open di app, si esegue com'e'.
    static func interpretabileOpen(_ comando: String) -> (argomenti: [String], id: String, nome: String)? {
        let parti = parole(comando)
        guard parti.count >= 2, ["open", "/usr/bin/open"].contains(parti[0]) else { return nil }
        let resto = Array(parti.dropFirst())
        if resto.contains(where: { $0.contains("://") || $0.hasPrefix("http") }) { return nil }
        // bersaglio: un percorso .app, o il nome dopo -a / -b
        var bersaglio = ""
        var eBundleId = false
        var i = 0
        while i < resto.count {
            let p = resto[i]
            if p == "-a" || p == "-b" {
                guard i + 1 < resto.count else { return nil }
                bersaglio = resto[i + 1]; eBundleId = (p == "-b"); i += 2; continue
            }
            if p.lowercased().hasSuffix(".app") { bersaglio = p; i += 1; continue }
            i += 1
        }
        guard !bersaglio.isEmpty else { return nil }
        let inventario = InventarioApp.caricato() ?? []
        guard let app = inventario.first(where: {
            eBundleId ? $0.id.lowercased() == bersaglio.lowercased()
                      : $0.percorso.lowercased() == bersaglio.lowercased()
                        || senzaSpazi(InventarioApp.nomeCartella($0)) == senzaSpazi(bersaglio)
        }) else { return nil }
        let eraAperta = eraGiaAperta(app.id)
        var nuovi = eraAperta ? ["-g"] : ["-g", "-j"]
        // le `-a`/`-b` le rimetto io sotto, con il nome vero: ricopiarle qui dentro
        // produceva `open -a -a Keka` e `open` leggeva "Keka" come un FILE relativo
        // (errore visto dal vivo il 2026-10-20: "The file .../jarvis/Keka does not exist")
        for flag in resto where flag.hasPrefix("-") && !["-g", "-j", "-a", "-b", "-e", "-F"].contains(flag) {
            nuovi.append(flag)
        }
        nuovi += eBundleId ? ["-b", app.id] : ["-a", app.nome]
        return (nuovi, app.id, app.nome)
    }

    private static func senzaSpazi(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Esegue `open` nel modo che non ti compare davanti.
    @MainActor static func eseguiOpen(argomenti: [String], id: String, nome: String) async -> String {
        // Questa e' aperta "per mezzo": Jarvis la usava per un lavoro, non per fargliela
        // vedere. Finito il giro si chiude da sola (regola sua del 2026-10-20, sera).
        registra(nil, id: id, nome: nome, motivo: .mezzo, eraAperta: eraGiaAperta(id))
        let outo = await Shell.run("/usr/bin/open", argomenti, timeout: 20)
        guard outo.isEmpty else { return outo }
        if !vuoleVedereLeApp() {
            // Il processo compare dopo, e alcune app si affacciano di nuovo subito dopo
            // l'hide (Keka l'ha fatto: finestra di benvenuto). Quindi si aspetta che
            // esista e si nasconde PIU' volte, non una sola.
            var trovata = false
            for _ in 0..<10 {
                if let p = NSWorkspace.shared.runningApplications.first(where: {
                    ($0.bundleIdentifier ?? "").lowercased() == id.lowercased() }) {
                    trovata = true
                    p.hide()
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    p.hide()
                } else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            if !trovata { return "Non ho visto il processo di \(nome) comparire: non posso garantirti che non si sia affacciata." }
        }
        return "\(nome) aperta in background (regola tua: niente sullo schermo). "
            + "Se la vuoi vedere dimmi «metti \(nome) davanti»."
    }
}

// MARK: - registro: le app aperte da Jarvis, da richiudere alla fine
extension Silenzio {
    /// Perche' una app e' stata aperta. `mezzo` = serviva a Jarvis per fare un lavoro
    /// che l'utente gli aveva chiesto in altri termini: questa, finito il lavoro, si
    /// chiude da sola. `richiesta` = lui ha detto "apri X": quella resta aperta, perche'
    /// chiuderla subito sarebbe peggio che aprirla.
    enum Motivo: String, Codable {
        case mezzo, richiesta
    }

    struct Apertura: Codable {
        var id: String
        var nome: String
        var motivo: Motivo
        var quando: Date
        var eraAperta: Bool
    }

    static var registroFile: URL { AppPaths.jarvisRoot.appendingPathComponent("app-aperte.json") }

    static func leggiRegistro() -> [Apertura] {
        guard let d = try? Data(contentsOf: registroFile) else { return [] }
        return (try? JSONDecoder().decode([Apertura].self, from: d)) ?? []
    }

    static func scriviRegistro(_ liste: [Apertura]) {
        try? FileManager.default.createDirectory(at: AppPaths.jarvisRoot, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(liste) { try? d.write(to: registroFile) }
    }

    static func registra(_ s: SchedaApp?, id: String, nome: String, motivo: Motivo, eraAperta: Bool) {
        var liste = leggiRegistro().filter { Date().timeIntervalSince($0.quando) < 3 * 3600 }
        liste.removeAll { $0.id.lowercased() == id.lowercased() }
        liste.append(Apertura(id: id, nome: nome, motivo: motivo, quando: Date(), eraAperta: eraAperta))
        _ = s
        scriviRegistro(liste)
    }

    /// La decisione pura, cosi' e' provabile senza aprire niente:
    /// si chiude solo cio' che Jarvis ha messo li' lui, per un lavoro suo, e che
    /// l'utente non ha preso in mano nel frattempo.
    static func deveChiudere(_ a: Apertura, davanti aDavanti: String?, adesso: Date = Date()) -> Bool {
        if a.motivo != .mezzo || a.eraAperta { return false }
        if adesso.timeIntervalSince(a.quando) > 20 * 60 { return false }
        if let d = aDavanti?.lowercased(), d == a.id.lowercased() { return false }
        return true
    }

    /// Richiude quello che aveva aperto Jarvis. `soloMezzo` = il giro automatico alla
    /// fine del lavoro; `false` = "chiudi tutte le app che hai aperto tu".
    @MainActor static func chiudiAperte(soloMezzo: Bool) -> String {
        let liste = leggiRegistro()
        let davanti = frontale()?.bundleIdentifier
        var rimaste: [Apertura] = []
        var chiuse: [String] = []
        var nonChiudibili: [String] = []
        for a in liste {
            let deve = soloMezzo ? deveChiudere(a, davanti: davanti)
                                 : (!a.eraAperta && davanti?.lowercased() != a.id.lowercased())
            guard deve else { rimaste.append(a); continue }
            if let p = NSWorkspace.shared.runningApplications.first(where: {
                ($0.bundleIdentifier ?? "").lowercased() == a.id.lowercased() }) {
                p.terminate()
                chiuse.append(a.nome)
            } else {
                // il processo non c'e' piu' (se l'era chiuso lui o era crashato):
                // non si conta come vittoria, ma sparisce dal registro
                nonChiudibili.append(a.nome)
            }
        }
        scriviRegistro(rimaste)
        if chiuse.isEmpty {
            return soloMezzo
                ? "Niente da chiudere: non avevo aperto io nessuna app per questo lavoro."
                : "Non ho aperto io nessuna app che sia rimasta li': "
                    + (nonChiudibili.isEmpty ? "nessuna." : "\(nonChiudibili.joined(separator: ", ")) non c'è più.")
        }
        return "Chiuse: " + chiuse.joined(separator: ", ") + "."
    }
}
