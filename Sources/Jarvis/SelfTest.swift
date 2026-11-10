import Foundation
import AppKit
import SwiftUI

/// Suite di test di Jarvis divisa in:
///   `Jarvis --test` (o `--test-rapido`): suite locale veloce (~30 secondi) senza blocchi di rete
///   `Jarvis --test-rete`: suite completa (modello in RAM, LLM chat/tool, F1, meteo, SSH, Whisper)
///   `Jarvis --test-tutto`: esegue rapido + rete
enum SelfTest {
    /// True quando Jarvis e' stato lanciato da terminale per un test o un debug:
    /// in quel mode non ha senso aprire finestre, hotkey o il server dell'iPad.
    static var modeCLICorrente: Bool {
        let args = CommandLine.arguments
        return args.contains { $0.hasPrefix("--test") }
            || args.contains { $0.hasPrefix("--prova") }
            // `--prova-frasi` non c'era: risultato, la suite scriveva nella SUA cronologia
            // vera (`Store` sceglie il file da qui) e accendeva hotkey e server iPad mentre
            // girava. I test si chiamano tutti `--prova-*`, quindi la famiglia intera.
            || args.contains("--ask") || args.contains("--shot")
            || args.contains("--voce") || args.contains("--costo")
            || args.contains("--latenza") || args.contains("--ponte") || args.contains("--ponti")
            // le due modalità che fotografano la UI non devono accendere niente: il server
            // buono e' quello dell'app gia' aperta, e la seconda istanza sulla 8732 perde
            // solo tempo (e confonde i test)
            || args.contains("--pop-up") || args.contains("--scatto-finestra")
    }

    @MainActor static func runIfRequested() {
        // il buongiorno delle 7:30: calcola, salva per la chat e manda la notifica.
        // Lo lancia il LaunchAgent, quindi deve funzionare senza interfaccia.
        if CommandLine.arguments.contains("--briefing") {
            final class Segno { var fatto = false }
            let segno = Segno()
            Task { @MainActor in
                let testo = await Buongiorno.calcola()
                Buongiorno.salva(testo)
                Buongiorno.notifica(testo)
                print(testo)
                segno.fatto = true
            }
            let fine = Date().addingTimeInterval(45)
            while !segno.fatto, Date() < fine { RunLoop.main.run(until: Date() + 0.1) }
            exit(segno.fatto ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--voce"), i + 1 < CommandLine.arguments.count {
            // La verifica di piper la fa JarvisCore all'avvio, ma nei mode da terminale
            // JarvisCore non parte: qui la avviamo noi e la aspettiamo al massimo 10 secondi.
            DispatchQueue.global(qos: .utility).async { Speaker.verificaPiper() }
            let fine = Date().addingTimeInterval(10)
            while !Speaker.piperPronto && Date() < fine {
                RunLoop.main.run(until: Date() + 0.2)
            }
            print("motore voce:", Speaker.shared.voiceName)
            Speaker.shared.say(CommandLine.arguments[(i + 1)...].joined(separator: " "))
            while Speaker.shared.isSpeaking { RunLoop.main.run(until: Date() + 0.2) }
            exit(0)
        }
        if CommandLine.arguments.contains("--costo") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                await SelfTest.misuraCosto()
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--shot"), i + 1 < CommandLine.arguments.count {
            scatto(to: CommandLine.arguments[i + 1])
            if CommandLine.arguments.contains("--finestra") {
                scattoFinestra(to: CommandLine.arguments[i + 1].replacingOccurrences(of: ".png", with: "-finestra.png"))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-gemini") {
            // Verifica la chiave senza mai stamparla: si vede solo la maschera.
            setbuf(stdout, nil)
            guard let c = Gemini.configurazione() else {
                print("CHIAVE: non trovata o troppo corta in ~/.jarvis/gemini.txt")
                exit(1)
            }
            print("CHIAVE: \(c.chiave.prefix(4))...\(c.chiave.suffix(2)) (lunghezza \(c.chiave.count)) · modello \(c.modello)")
            final class C { var fatto = false }
            let c2 = C()
            Task { @MainActor in
                let risposta = await Gemini.chiedi("Rispondi con una sola frase: chi sei?")
                print("RISPOSTA DI GEMINI: \(String(risposta.prefix(240)))")
                c2.fatto = true
            }
            while !c2.fatto { RunLoop.main.run(until: Date() + 0.5) }
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-contatti") {
            // Diagnostica nuda: come viene letto ~/.jarvis/contatti.txt e cosa torna
            // dal database. Serve perche' i nomi dei mittenti sono l'unica cosa che
            // l'utente vuole sentire, non i numeri.
            setbuf(stdout, nil)
            print("file:", Messaggi.fileContatti.path, FileManager.default.fileExists(atPath: Messaggi.fileContatti.path) ? "c'e'" : "MANCANTE")
            let lista = Messaggi.contatti()
            print("letti \(lista.count) contatti")
            for c in lista { print("  \(c.nome) -> \(c.numero)") }
            print("ultimi 5 mittenti dal database:")
            for riga in Messaggi.query("SELECT COALESCE(NULLIF(h.uncanonicalized_id, ''), h.id, 'ignoto') FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE m.is_from_me = 0 ORDER BY m.date DESC LIMIT 5;") ?? [] {
                let raw = riga.joined(separator: "|")
                print("  [\(raw)] -> nome: \(Messaggi.nomeDi(raw) ?? "nessuno")")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-guardia") {
            // Il blocco dei messaggi, testato senza mandare niente a nessuno
            setbuf(stdout, nil)
            var promossi = 0, bocciati = 0
            func caso(_ nome: String, _ testo: String, _ richiesta: String, deveBloccare: Bool) {
                GuardiaMessaggio.haLettoChat = nome.contains("dopo lettura")
                let esito = GuardiaMessaggio.blocca(testo, destinatario: "nonna", richiesta: richiesta)
                let bloccato = esito != nil
                let ok = bloccato == deveBloccare
                print("  \(ok ? "ok  " : "FAIL") \(nome) → \(bloccato ? "bloccato" : "lasciato passare")")
                if ok { promossi += 1 } else { bocciati += 1; print("        \(String((esito ?? "").prefix(120)))") }
            }
            caso("l'ordine ricopiato", "leggi la chat e rispondimi",
                 "scrivi a nonna leggi la chat e rispondigli", deveBloccare: true)
            caso("l'ordine ricopiato con ciao", "ciao, leggi la chat e rispondimi",
                 "scrivi a nonna leggi la chat e rispondigli", deveBloccare: true)
            caso("dettagliato dettato passa", "\(Marca.nome) lavoro finito, regola nuova installata",
                 "manda un messaggio al mio numero scrivendo esattamente: \(Marca.nome) lavoro finito, regola nuova installata",
                 deveBloccare: false)
            caso("risposta senza aver letto", "ciao nonna tutto bene?",
                 "leggi la chat con la nonna e rispondi", deveBloccare: true)
            caso("risposta dopo lettura", "ciao nonna tutto bene?",
                 "leggi la chat con la nonna e rispondi", deveBloccare: false)
            caso("messaggio normale", "guarda che non posso venire perche' ho la verifica",
                 "dici a nonna che non posso venire", deveBloccare: false)
            caso("messaggio normale 2", "Ciao nonna, sono \(Marca.nome): \(Identita.nome) sta studiando, ti risente dopo.",
                 "presentati a nonna", deveBloccare: false)
            func limite(_ nome: String, _ testo: String, deveBloccare: Bool) {
                let esito = LimitiMessaggio.verifica(testo, destinatario: "nonna") != nil
                let ok = esito == deveBloccare
                print("  \(ok ? "ok  " : "FAIL") \(nome) → \(esito ? "bloccato" : "lasciato passare")")
                if ok { promossi += 1 } else { bocciati += 1 }
            }
            limite("dichiarazione d'amore", "Ti amo anche io amore", deveBloccare: true)
            limite("saluto neutro", "Ciao nonna, \(Identita.nome) sta studiando, ti richiama dopo", deveBloccare: false)
            limite("troppo lungo", String(repeating: "parola ", count: 120), deveBloccare: true)
            limite("fatti privati", "Ha preso un farmaco perche' sta male", deveBloccare: true)
            limite("link non chiesto", "Guarda https://esempio.it", deveBloccare: true)
            limite("spacciarsi per \(Identita.nome)", "Ciao sono \(Identita.nome), tutto bene", deveBloccare: true)
            limite("compiti detti bene", "Ha i compiti di matematica, esercizi dal 14 al 18", deveBloccare: false)
            func invito(_ nome: String, _ letto: String, _ agendaFatta: Bool, _ risposta: String, deveBloccare: Bool) {
                GuardiaMessaggio.haLettoChat = true
                GuardiaMessaggio.invitoVisto = false
                GuardiaMessaggio.agendaControllata = agendaFatta
                GuardiaMessaggio.segnalaInvito(letto)
                let esito = GuardiaMessaggio.blocca(risposta, destinatario: "dux", richiesta: "leggi e rispondi") != nil
                let aspettavaInvito = deveBloccare || letto.contains("alle") || letto.contains("ti va")
                let ok = esito == deveBloccare && GuardiaMessaggio.invitoVisto == aspettavaInvito
                print("  \(ok ? "ok  " : "FAIL") \(nome) → invito:\(GuardiaMessaggio.invitoVisto) bloccato:\(esito)")
                if ok { promossi += 1 } else { bocciati += 1 }
            }
            invito("invito senza agenda", "Ciao, ti va di uscire domenica alle 4?", false,
                   "Certo, ci sono", deveBloccare: true)
            invito("invito con agenda gia' letta", "Ti va di uscire domenica alle 4?", true,
                   "Certo, ci sono", deveBloccare: false)
            invito("niente invito", "Hai finito i compiti?", false,
                   "Si, li ho finiti", deveBloccare: false)
            func amore(_ nome: String, _ testo: String, deveBloccare: Bool) {
                let esito = LimitiMessaggio.verifica(testo, destinatario: "qualcuno") != nil
                let ok = esito == deveBloccare
                print("  \(ok ? "ok  " : "FAIL") \(nome)")
                if ok { promossi += 1 } else { bocciati += 1 }
            }
            amore("affetto vietato", "Ti amo tanto, sei la persona piu' importante che ho", deveBloccare: true)
            amore("abbraccio vietato", "Un abbraccio forte tesoro", deveBloccare: true)
            amore("parolaccia permessa", "Porco dio, non ci credo, che gara assurda", deveBloccare: false)
            amore("due parole sole non bastano", "Si certo", deveBloccare: true)
            amore("neutro", "Ciao, \(Identita.nome) sta studiando e ti richiama dopo", deveBloccare: false)

            func pensiero(_ nome: String, _ grezzo: String, deveUscire: String) {
                let pulito = Brain.pulisciPensiero(grezzo)
                let ok = pulito == deveUscire
                print("  \(ok ? "ok  " : "FAIL") \(nome) → [\(pulito)]")
                if ok { promossi += 1 } else { bocciati += 1 }
            }
            pensiero("blocco chiuso", Brain.pensieroAperto + "penso un attimo" + Brain.pensieroChiuso + "\nRisposta vera", deveUscire: "Risposta vera")
            pensiero("blocco aperto", "Risposta" + Brain.pensieroAperto + "\npezzo di pensiero", deveUscire: "Risposta")
            pensiero("senza pensiero", "Tutto a posto", deveUscire: "Tutto a posto")
            pensiero("solo pensiero e chatml", Brain.pensieroAperto + "penso" + Brain.pensieroChiuso + Brain.barraLarga + "|im_end|", deveUscire: "")

            func dettato(_ nome: String, _ testo: String, _ richiesta: String, deveEssere: Bool) {
                let ok = LimitiMessaggio.dettatoDallUtente(testo, richiesta: richiesta) == deveEssere
                print("  \(ok ? "ok  " : "FAIL") \(nome)")
                if ok { promossi += 1 } else { bocciati += 1 }
            }
            dettato("detto a voce", "Stasera non posso venire perche' ho la verifica di scienze",
                    "digli che stasera non posso venire perche' ho la verifica di scienze", deveEssere: true)
            dettato("scritto tra virgolette", "Ciao nonna, sono \(Marca.nome): \(Identita.nome) sta studiando",
                    "scrivi a nonna \"Ciao nonna, sono \(Marca.nome): \(Identita.nome) sta studiando\"", deveEssere: true)
            dettato("inventato lui", "Se ti comporti bene ti do la patata, altrimenti no",
                    "scrivi a nonna leggi la chat e rispondigli", deveEssere: false)
            print("== \(promossi) promossi, \(bocciati) bocciati ==")
            exit(bocciati == 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--prova-batteria") {
            setbuf(stdout, nil)
            final class C { var fatto = false }
            let c = C()
            Task { @MainActor in
                await SelfTest.provaBatteria()
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.5) }
            exit(SelfTest.batteriaBocciata ? 1 : 0)
        }
        if CommandLine.arguments.contains("--prova-fucina") {
            // Collauda le catene della fucina: prova a compilare una modifica vera,
            // verifica che il file torni identico e che Gate.swift resti chiuso.
            setbuf(stdout, nil)
            final class C { var fatto = false }
            let c = C()
            Task { @MainActor in
                var promossi = 0, bocciati = 0
                func prova(_ nome: String, _ ok: Bool, _ dettaglio: String = "") {
                    print("  \(ok ? "ok  " : "FAIL") \(nome)\(dettaglio.isEmpty ? "" : " — \(dettaglio.prefix(90))")")
                    if ok { promossi += 1 } else { bocciati += 1 }
                }
                let relativo = "Sources/\(Marca.nome)/Design.swift"
                let url = Fucina.progetto.appendingPathComponent(relativo)
                let originale = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

                prova("stato della fucina", Fucina.stato().contains("Gate.swift"), String(Fucina.stato().prefix(70)))
                prova("legge un file del progetto", Fucina.leggi(relativo, maxRighe: 3).contains("import"))
                prova("Gate.swift e' chiuso", Fucina.percorsoPermesso("Sources/\(Marca.nome)/Gate.swift") == nil)
                prova("install.sh e' chiuso", Fucina.percorsoPermesso("install.sh") == nil)
                prova("fuori dal progetto e' chiuso", Fucina.percorsoPermesso("../../etc/hosts") == nil)

                let innesto = Fucina.innesta(originale, trova: "enum Design {",
                                            sostituisci: "enum Design { /* collaudo fucina */")
                prova("innesto mirato", innesto.ok)
                let sbagliato = Fucina.innesta(originale, trova: "questa stringa non esiste proprio", sostituisci: "x")
                prova("pezzo inesistente respinto", !sbagliato.ok, String(sbagliato.messaggio.prefix(60)))

                // modifica che NON compila: deve essere respinta e il file ripristinato
                let rotto = await Fucina.prova(relativo, nuovoTesto: originale + "\nquesta non e' Swift \n")
                prova("codice rotto respinto", !rotto.ok, String(rotto.messaggio.prefix(70)))
                prova("il file e' tornato com'era",
                      ((try? String(contentsOf: url, encoding: .utf8)) ?? "") == originale)

                // modifica che compila: prova deve dire OK e non lasciare tracce
                let buono = await Fucina.prova(relativo, nuovoTesto: innesto.messaggio)
                prova("modifica valida compilata", buono.ok, String(buono.messaggio.prefix(70)))
                prova("dopo la prova il file e' intatto",
                      ((try? String(contentsOf: url, encoding: .utf8)) ?? "") == originale)

                print("\n== fucina: \(promossi) ok, \(bocciati) da sistemare ==\n")
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.5) }
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-watchdog") {
            // Collauda il watchdog dei compiti davvero: finge che l'app davanti sia
            // una distrazione, soglie corte, e verifica che scatti l'avviso.
            final class C { var fatto = false; var ok = false; var catturato = ""; var statoLoop = "" }
            let c = C()
            let fileDistrazioni = Studio.distrazioniPath
            let prima = (try? String(contentsOf: fileDistrazioni, encoding: .utf8)) ?? ""
            Task { @MainActor in
                JarvisCore.shared.voiceOn = false          // niente audio in prova
                // finge che l'utente sia su Fortnite: cosi' il test non dipende da chi
                // e' davanti allo schermo in questo momento (a schermo bloccato non lo sa nessuno)
                Studio.davantiPerTest = "Fortnite"
                try? "Fortnite\n".write(to: fileDistrazioni, atomically: true, encoding: .utf8)
                Studio.sogliaForzato = 2
                Studio.ripetiForzato = 1
                Studio.shared.onNote = { riga in c.catturato = riga }
                _ = Studio.shared.accendi(pagina: "", minuti: 1)
                // si pilota il ciclo a mano: il timer di sistema in un processo da
                // terminale non e' affidabile, la logica del watchdog si'
                let fine = Date().addingTimeInterval(14)
                while c.catturato.isEmpty && Date() < fine {
                    Studio.shared.controllo()
                    RunLoop.main.run(until: Date() + 0.5)
                }
                c.statoLoop = Studio.shared.stato
                c.ok = !c.catturato.isEmpty
                _ = Studio.shared.spegni()
                Studio.sogliaForzato = nil; Studio.ripetiForzato = nil; Studio.davantiPerTest = nil
                try? prima.write(to: fileDistrazioni, atomically: true, encoding: .utf8)
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.3) }
            print(c.ok ? "  ok   watchdog: scatta davvero — \(c.catturato.prefix(90))"
                       : "  FAIL watchdog: non ha mai avvisato | \(c.statoLoop.prefix(160))")
            exit(c.ok ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--prova-frasi") {
            // le frasi si confrontano solo se il cervello e' sempre lo stesso
            CervelloPortatile.forzatoPerTest = false
            // --prova-frasi [modello] : con il nome lo forza su quel modello, cosi'
            // si possono confrontare 8b e 30b sulle stesse 25 frasi
            if CommandLine.arguments.count > i + 1, !CommandLine.arguments[i + 1].hasPrefix("--") {
                Brain.modelloForzato = CommandLine.arguments[i + 1]
                print("modello forzato:", CommandLine.arguments[i + 1])
            }
            final class C { var fatto = false }
            let c = C()
            Task { @MainActor in
                _ = await Prove.comprensione()
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.2) }
            exit(0)
        }
        if CommandLine.arguments.contains("--sensori") {
            // Cosa si puo' leggere davvero su QUESTO Mac, senza root. Prima di mettere
            // una temperatura nella finestra, la si misura qui.
            _ = Sensori.cpuPerCento()
            Thread.sleep(forTimeInterval: 1.4)
            let cpu = Sensori.cpuPerCento()
            print("CPU uso: " + (cpu.map { String(format: "%.0f%%", $0) } ?? "—"))
            if let ram = Sensori.usoRam() { print("RAM: " + ram.giga + " · " + ram.percentuali) }
            for l in Sensori.tutte() {
                print(l.nome + ": " + l.temperatura + (l.uso.map { " · uso \($0)" } ?? ""))
            }
            print("stride struct SMC: \(Sensori.strideStruct) byte (il kernel se ne aspetta 80) · " + Sensori.misure())
            for k in ["TC0D", "TC0E", "TG0D", "Tp0K", "TB0T", "#KEY"] { print(Sensori.diagnosticaSmc(k)) }
            print("Batteria: " + (Alimentazione.percentuale().map { "\($0)%" } ?? "—")
                  + " · " + (Alimentazione.inCarica ? "corrente" : "staccato"))
            exit(0)
        }
        if CommandLine.arguments.contains("--finestre") {
            // Serve per guardare la propria finestra ANCHE se una app copre tutto
            // (video a schermo intero): lo id va dato a `--vivo <png> id=<n>`.
            let opzioni = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
            if let lista = CGWindowListCopyWindowInfo(opzioni, kCGNullWindowID) as? [[String: Any]] {
                for f in lista where (f[kCGWindowOwnerName as String] as? String) == "\(Marca.nome)" {
                    let n = f[kCGWindowNumber as String] ?? "?"
                    let nome = (f[kCGWindowName as String] as? String) ?? "senza titolo"
                    let lato = (f[kCGWindowLayer as String] as? Int) ?? -1
                    print("finestra id=\(n) · \(nome) · livello \(lato)")
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--pop-up"), i + 1 < CommandLine.arguments.count {
            // Fotografa il pop-up della barra dei menu senza doverlo aprire a mano:
            // lo monta in una finestra vera, lo riprende e lo richiude.
            // Con --pieno riempie la chat e la card di conferma, cosi' si vedono anche quelle.
            let percorso = CommandLine.arguments[i + 1]
            let pieno = CommandLine.arguments.contains("--pieno")
            final class Scatto { var fatto = false }
            let s = Scatto()
            Task { @MainActor in
                let core = JarvisCore.shared
                JarvisCore.demo = CommandLine.arguments.contains("--demo")
                if pieno {
                    core.bubbles = [
                        Bubble(role: "user", text: "Quanti giga liberi ho sul disco?"),
                        Bubble(role: "note", text: "→ esegui_comando {\"comando\":\"df -h\"}"),
                        Bubble(role: "jarvis", text: "Hai 461 GB liberi sul disco principale, quindi stai tranquillo."),
                        Bubble(role: "user", text: "E la stampante?")
                    ]
                    core.pendingCommand = "brew install wget"
                }
                let pannello = NSHostingView(rootView: JarvisPanel(core: core)
                    .environmentObject(core)
                    .preferredColorScheme(.dark))
                let finestra = NSWindow(contentRect: NSRect(x: 30, y: 200, width: 420, height: 760),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
                finestra.contentView = pannello
                finestra.level = .floating
                finestra.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date() + 0.9)          // lascia finire i layout
                let id = finestra.windowNumber
                if let immagine = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                          CGWindowID(id), [.boundsIgnoreFraming, .bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: immagine)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: percorso))
                        print("pop-up salvato: \(percorso) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
                    } else {
                        print("png non prodotto")
                    }
                } else {
                    print("nulla da fotografare")
                }
                scollaFinestraDiProva(finestra)
                s.fatto = true
            }
            while !s.fatto { RunLoop.main.run(until: Date() + 0.1) }
            // `_exit` e non `exit`: lo smontaggio di AppKit + Swift concurrency scarica
            // un autorelease pool con oggetti gia' liberati (SIGSEGV in `objc_release`,
            // due .ips lasciati nel suo DiagnosticReports il 2026-10-21). Il file e' gia'
            // scritto e stdout e' senza buffer, quindi non si perde niente.
            _exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--scatto-finestra"), i + 1 < CommandLine.arguments.count {
            // La finestra grande fotografata DAL SUO PROCESSO: `--vivo id=<n>` dipende da
            // `screencapture -l`, che su questa installazione non riesce piu' a prendere la
            // finestra dell'app in esecuzione. Qui la finestra la creiamo noi, quindi
            // l'immagine del suo CGWindowID arriva senza toccare il suo desktop.
            let percorso = CommandLine.arguments[i + 1]
            setbuf(stdout, nil)
            final class Scatto { var fatto = false }
            let s = Scatto()
            let demo = CommandLine.arguments.contains("--demo")
            Task { @MainActor in
                let core = JarvisCore.shared
                JarvisCore.demo = demo          // niente chat vere nelle immagini del sito
                JarvisFinestra.barraDiProva = CommandLine.arguments.contains("--barra")
                // Il piano vero, non quello di default: la riga "passo:" dell'immagine
                // deve dire la verita' su questo Mac, non la scritta di fabbrica.
                core.piano = Risparmio.leggi()
                let vista = NSHostingView(rootView: JarvisFinestra(core: core)
                    .environmentObject(core)
                    .frame(width: 1180, height: 760)
                    .preferredColorScheme(.dark))
                let finestra = NSWindow(contentRect: NSRect(x: 40, y: 60, width: 1180, height: 760),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
                finestra.contentView = vista
                finestra.level = .floating
                finestra.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date() + 1.6)          // timer della diagnostica + layout
                core.raccogliDiagnostica()
                RunLoop.main.run(until: Date() + 1.2)
                let id = finestra.windowNumber
                if let immagine = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                          CGWindowID(id), [.boundsIgnoreFraming, .bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: immagine)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: percorso))
                        print("finestra salvata: \(percorso) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
                    } else { print("png non prodotto") }
                } else { print("nulla da fotografare") }
                scollaFinestraDiProva(finestra)
                s.fatto = true
            }
            while !s.fatto { RunLoop.main.run(until: Date() + 0.1) }
            // `_exit` e non `exit`: lo smontaggio di AppKit + Swift concurrency scarica
            // un autorelease pool con oggetti gia' liberati (SIGSEGV in `objc_release`,
            // due .ips lasciati nel suo DiagnosticReports il 2026-10-21). Il file e' gia'
            // scritto e stdout e' senza buffer, quindi non si perde niente.
            _exit(0)
        }
        if CommandLine.arguments.contains("--prova-app") {
            // Una prova per ogni app installata (nessuna aperta): vedi ProveApp.
            final class C { var fatto = false }
            let c = C()
            Task { @MainActor in
                _ = await ProveApp.tutto()
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.2) }
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-tutto") || CommandLine.arguments.contains("--prova-tutto-quieto") {
            final class C { var fatto = false }
            let c = C()
            Task { @MainActor in
                _ = await Prove.tutto()
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.2) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--prova-messaggi") {
            // Senza destinatario verifica solo che Messaggi risponda (permesso di controllo).
            // Con destinatario manda davvero un messaggio: "scrivere a chiunque" provato per bene.
            let destinatario = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
            final class C { var fatto = false; var testo = "" }
            let c = C()
            Task { @MainActor in
                if destinatario.isEmpty {
                    c.testo = await AppleScript.run("""
                    tell application "Messages"
                        set n to count of chats
                        set s to name of every service
                        return "Messaggi risponde: " & n & " chat, servizi " & (s as text)
                    end tell
                    """)
                } else {
                    // Regola dell'utente (2026-10-20): le prove di invio si fanno solo a
                    // lui o a nonna. Non e' una preferenza: un messaggio sbagliato
                    // partivo e basta, e la persona lo leggeva.
                    if !GuardiaMessaggio.autorizzatoPerLeProve(destinatario) {
                        print("MESSAGGI > NON INVIATO: le prove si fanno solo a \(Identita.nome) ("
                              + GuardiaMessaggio.numeroDiCasa + ") o a nonna. "
                              + "«\(destinatario)» non e' permesso.")
                        exit(0)
                    }
                    let senza = CommandLine.arguments.contains("senza_invio")
                    if senza {
                        // prova il solo inserimento nel campo giusto, senza premere invio
                        c.testo = await Messaggi.inviaConTastiera(a: destinatario,
                                                                  testo: "prova: questo testo deve finire nel corpo, non nel destinatario",
                                                                  invio: false)
                    } else {
                        // stessa catena dello strumento: AppleScript, poi tastiera con invio
                        let provato = await Messaggi.inviaMessaggio(destinatario, "Test di \(Marca.nome): questo te l'ho mandato io, senza che tu premessi niente.")
                        if provato.contains("mandato") {
                            c.testo = provato
                        } else {
                            c.testo = await Messaggi.inviaConTastiera(a: destinatario,
                                                                      testo: "Test di \(Marca.nome): questo te l'ho mandato io, senza che tu premessi niente.",
                                                                      invio: true)
                        }
                    }
                }
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.2) }
            print("MESSAGGI > \(c.testo)")
            exit(0)
        }
        if CommandLine.arguments.contains("--prova-mail") {
            // Stampa la risposta CRUDIA di Outlook/Mail: serve per capire perche' un invio
            // fallisce senza che il modello la riscriva a modo suo.
            let fine = Date().addingTimeInterval(10)
            while !Speaker.piperPronto && Date() < fine { RunLoop.main.run(until: Date() + 0.2) }
            let o = CommandLine.arguments.firstIndex(of: "--prova-mail")!
            let resto = Array(CommandLine.arguments[(o + 1)...])
            let a = resto.first ?? "nessuno@example.it"
            final class C { var fatto = false; var testo = "" }
            let c = C()
            Task { @MainActor in
                c.testo = await Mail.scrivi(a: a, oggetto: "prova jarvis", testo: "ciao sono \(Marca.nome), il test di \(Identita.nome)", invio: true)
                c.fatto = true
            }
            while !c.fatto { RunLoop.main.run(until: Date() + 0.2) }
            print("POSTA > \(c.testo)")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--vivo"), i + 1 < CommandLine.arguments.count {
            // Screenshot reale dello schermo: ImageRenderer non disegna ne' ScrollView
            // ne' controlli standard, quindi per vedere la lista chat serve questo.
            // Va lanciato dal bundle firmato, cosi' usa il permesso di Jarvis gia' dato.
            // Con "id=123" dopo il path si prende solo quella finestra, anche se coperta.
            let out = CommandLine.arguments[i + 1]
            let args = CommandLine.arguments[(i + 2)...]
            let finestra = args.first(where: { $0.hasPrefix("id=") }).map { String($0.dropFirst(3)) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // prova le due sintassi di -l: sulle versioni di macOS non sono uguali
            if let id = finestra {
                p.arguments = ["-o", "-l", id, out]
                try? p.run()
                p.waitUntilExit()
                if !FileManager.default.fileExists(atPath: out) {
                    let rip = Process()
                    rip.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    rip.arguments = ["-o", "-l\(id)", out]
                    try? rip.run()
                    rip.waitUntilExit()
                }
            } else {
                p.arguments = ["-x", out]
                try? p.run()
                p.waitUntilExit()
            }
            print(FileManager.default.fileExists(atPath: out) ? "schermo salvato: \(out)" : "nulla salvato: manca il permesso di registrazione schermo")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ask"), i + 1 < CommandLine.arguments.count {
            let testo = CommandLine.arguments[(i + 1)...].joined(separator: " ")
            // come nel --test: si pompa il run loop, perche' una skill puo' chiedere il filo principale
            final class Segno { var finito = false }
            let stato = Segno()
            Task { @MainActor in
                await Brain.shared.warmUp()
                let agent = Agent()
                await agent.ask(testo, source: "debug",
                                onDelta: { _ in },
                                onNote: { print("   \($0)") },
                                onFinal: { print("   RISPOSTA: \($0)") })
                stato.finito = true
            }
            while !stato.finito { RunLoop.main.run(until: Date() + 0.1) }
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--latenza") {
            // IL NUMERO CHE NESSUN JARVIS IN GIRO PUBBLICA: quanto passa tra "premo il
            // tasto" e "sta gia' dicendo la prima parola".
            //
            // NON passa dall'agent, ed e' voluto: una prova di latenza non deve poter
            // toccare niente sul Mac. Il 2026-10-22 la prima versione chiedeva all'agent
            // «dimmi tre cose che posso fare con keka», e l'agent ha eseguito davvero
            // `cose azione=togli`: ha cancellato una riga da ~/.jarvis/cose.txt. Qui il
            // modello risponde a mani vuote (`tools: []`): si misura lui, non le sue mani.
            let coda = Array(CommandLine.arguments[(i + 1)...]).filter { !$0.hasPrefix("--") }
            let domanda = coda.isEmpty ? "spiegami in tre frasi perche' il cielo e' blu" : coda.joined(separator: " ")
            setbuf(stdout, nil)
            DispatchQueue.global(qos: .utility).async { Speaker.verificaPiper() }
            let attesaVoce = Date().addingTimeInterval(10)
            while !Speaker.piperPronto && Date() < attesaVoce { RunLoop.main.run(until: Date() + 0.2) }

            final class Cronometro {
                var t0 = Date()
                var accumulato = ""
                var divisore = DivisoreDiFrasi()
                var primoToken: Date?
                var primaFrase: Date?
                var detta = ""
                var fine: Date?
                var finito = false
                var vuoto = false
            }

            func secondo(_ base: Date, _ quando: Date?) -> String {
                guard let quando else { return "  —   " }
                return String(format: "%5.2f s", quando.timeIntervalSince(base))
            }

            /// Un giro di misura. `scalda` = prima chiede a Ollama di caricare il modello
            /// in RAM (il costo della prima domanda dopo un'ora ferma, che nessuno conta).
            /// Con `--parla` la voce esce davvero: e' l'unico modo di provare la CODA da
            /// terminale (il percorso web non parla, e il pannello ha bisogno di un clic).
            let parla = CommandLine.arguments.contains("--parla")
            func cronometra(_ etichetta: String, scalda: Bool) -> Cronometro {
                let m = Cronometro()
                Task { @MainActor in
                    if scalda { await Brain.shared.warmUp() }
                    let giri = [ChatTurn(role: "system", content: JarvisCore.systemPrompt()),
                                ChatTurn(role: "user", content: domanda)]
                    m.t0 = Date()
                    let esito = try? await Brain.shared.stream(turns: giri, tools: []) { pezzo in
                        if m.primoToken == nil { m.primoToken = Date() }
                        m.accumulato += pezzo
                        let pronte = m.divisore.appenda(m.accumulato)
                        if m.primaFrase == nil, let prima = pronte.first {
                            m.primaFrase = Date()
                            m.detta = prima
                        }
                        if parla, !scalda, !pronte.isEmpty { Speaker.shared.incoda(pronte) }
                    }
                    m.fine = Date()
                    if parla, !scalda {
                        // l'ultima frase, spesso senza punto: senza questa chiusura
                        // la coda si fermerebbe a meta' risposta
                        Speaker.shared.incoda(m.divisore.chiudi())
                    }
                    if let testo = esito?.text, !testo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        m.detta = m.detta.isEmpty ? testo : m.detta
                        if m.primaFrase == nil { m.primaFrase = m.fine }
                    } else {
                        m.vuoto = true
                    }
                    m.finito = true
                }
                while !m.finito { RunLoop.main.run(until: Date() + 0.1) }
                print("  [\(etichetta)]")
                print("    primo token del modello : \(secondo(m.t0, m.primoToken))")
                print("    prima frase chiusa      : \(secondo(m.t0, m.primaFrase))   <- con la voce a flusso qui si inizia a parlare")
                print("    risposta completa       : \(secondo(m.t0, m.fine))   <- qui si parlava prima di stasera")
                if m.vuoto { print("    (il modello non ha risposto: Ollama spento o modello assente)") }
                return m
            }

            print("domanda: \(domanda)")
            _ = cronometra("modello appena caricato", scalda: true)
            let calda = cronometra("modello gia' caldo", scalda: false)

            // e quanto ci mette la voce neurale a preparare la prima frase
            final class Misura { var valore = -1.0 }
            let s = Misura()
            let sem = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                s.valore = await Speaker.tempoDiSintesi(String(calda.detta.prefix(200))) ?? -1
                sem.signal()
            }
            sem.wait()
            if s.valore > 0, let fine = calda.fine, let prima = calda.primaFrase {
                print(String(format: "    sintesi piper della prima frase : %.2f s", s.valore))
                print(String(format: "    => prima parola sentita: %.2f s  (prima del flusso sarebbe stata %.2f s)",
                             prima.timeIntervalSince(calda.t0) + s.valore,
                             fine.timeIntervalSince(calda.t0) + s.valore))
            } else {
                print("    sintesi piper: non misurabile (voce di sistema o piper assente)")
            }
            if parla {
                // se si esce mentre la coda sta ancora parlando, l'ultima frase la sente
                // a meta' e il test sembra rotto quando e' solo finito presto
                let finoA = Date().addingTimeInterval(30)
                while Speaker.shared.isSpeaking, Date() < finoA {
                    RunLoop.main.run(until: Date() + 0.2)
                }
            }
            exit(0)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--ponte"), i + 1 < CommandLine.arguments.count {
            // Cosa entra davvero nel prompt di testa quando lui nomina una app: la riga del
            // bundle e il ponte, se c'e'. Serve per perche' "Jarvis sa pilotarla" e' una
            // cosa che si deve poter leggere, non un'impressione.
            let nome = CommandLine.arguments[(i + 1)...].joined(separator: " ")
            setbuf(stdout, nil)
            let inventario = InventarioApp.caricato() ?? []
            let scelto = InventarioApp.risolvi(nome, in: inventario)
            guard let s = scelto.una else {
                print("Nell'inventario non c'e' niente che somigli a «\(nome)»"
                    + (scelto.troppe.isEmpty ? "." : " (troppe: \(scelto.troppe.map(\.nome).joined(separator: ", ")))"))
                exit(1)
            }
            final class Esito { var righe = ""; var fatto = false }
            let e = Esito()
            Task { @MainActor in
                e.righe += "== riga del bundle ==\n" + InventarioApp.sintesi(s) + "\n"
                if CommandLine.arguments.contains("--rifai") {
                    // rifare il ponte da terminale: serve per provare il flusso senza
                    // aspettare il giro del contatore, e per rigenerare una scheda vecchia
                    // con la pulizia nuova della risposta di Gemini
                    e.righe += await Integrazione.integra(s) + "\n"
                }
                let ponte = Integrazione.sintesiPerIlPrompt(s)
                e.righe += "\n== ponte nel prompt ==\n"
                    + (ponte.isEmpty ? "(nessun ponte: `app azione=integra nome=\(s.nome)` per costruirlo)" : ponte)
                e.righe += "\n== nota che vede il modello ==\n"
                    + InventarioApp.notaSullaDomanda("cosa sai fare con \(s.nome)?", in: inventario)
                e.fatto = true
            }
            while !e.fatto { RunLoop.main.run(until: Date() + 0.2) }
            print(e.righe)
            exit(0)
        }

        if CommandLine.arguments.contains("--ponti") {
            // Gira il contatore delle app ADESSO e costruisce i ponti di ciò che è nuovo:
            // serve per provare il flusso "installa una app -> \(Marca.nome) sa pilotarla"
            // senza aspettare i dieci minuti del timer, e per rivedere cosa è uscito dal Mac.
            setbuf(stdout, nil)
            final class Ponte { var fatto = false; var riga = "" }
            let p = Ponte()
            Task { @MainActor in
                let esito = await InventarioApp.vigila()
                var fuori = esito.annuncio ?? "Nessuna novità nel conteggio."
                if !esito.nuove.isEmpty {
                    let lavoro = await Integrazione.creaNuove(esito.nuove)
                    fuori += "\n" + lavoro
                }
                fuori += "\nponti costruiti: \(Integrazione.quante()) in \(Integrazione.cartella.path)"
                p.riga = fuori
                p.fatto = true
            }
            while !p.fatto { RunLoop.main.run(until: Date() + 0.2) }
            print(p.riga)
            exit(0)
        }

        let isRete = CommandLine.arguments.contains("--test-rete")
        let isTutto = CommandLine.arguments.contains("--test-tutto")
        let isRapido = CommandLine.arguments.contains("--test") || CommandLine.arguments.contains("--test-rapido")
        // i test paragonano risposte: il cervello deve restare quello locale
        CervelloPortatile.forzatoPerTest = false

        guard isRete || isTutto || isRapido else { return }

        // Niente semaforo: il test tocca anche pezzi MainActor (il watchdog dei compiti).
        // Se il filo principale aspetta un segnale, quei blocchi non girano mai e si blocca tutto.
        // Qui si pompa il run loop finche' la suite non ha finito.
        final class Segno { var finito = false }
        let stato = Segno()
        Task { @MainActor in
            if isTutto {
                await rapido()
                print("\n" + String(repeating: "-", count: 50) + "\n")
                await rete()
            } else if isRete {
                await rete()
            } else {
                await rapido()
            }
            stato.finito = true
        }
        while !stato.finito {
            RunLoop.main.run(until: Date() + 0.1)
        }
        if fallimenti > 0 { print("\n== \(fallimenti) controlli falliti ==") }
        exit(fallimenti == 0 ? 0 : 1)
    }

    // MARK: - Test Rapido (Locale, ~30s)

    static func rapido() async {
        let t0 = ProcessInfo.processInfo.systemUptime
        AppPaths.prepare()
        Tools.confirm = { _ in false }
        print("== JARVIS TEST RAPIDO (locale, verifiche in 30s) ==\n")

        // 1. Ollama vivo
        let alive = await Brain.shared.isAlive()
        // ambiente, non regressione: conta come avviso, non fa fallire la suite
        avviso("Ollama raggiungibile", alive, "http://127.0.0.1:11434")

        // 2. Modello presente
        let model = await Brain.shared.resolveModel()
        avviso("Modello locale trovato", model != nil, model ?? "nessuno scaricato")

        // 3. Cancello Shell
        gateTest()

        // 4. Memoria persistente e orario
        let prof = Memory.readProfile()
        report("memoria persistente profilo.md", !prof.isEmpty, "\(prof.components(separatedBy: .newlines).count) righe in ~/.jarvis/profilo.md")

        let sched = Memory.readSchedule()
        report("orario scolastico orario.md", sched.contains("Materie"), String(sched.prefix(80)))

        let marca = "verifica temporanea \(Int(Date().timeIntervalSince1970))"
        let memAdd = Memory.appendFact(marca)
        report("aggiornamento memoria", memAdd.contains("memorizzato") && Memory.readProfile().contains(marca), memAdd)
        Memory.rimuovi(marca)
        report("il test non lascia righe nel profilo", !Memory.readProfile().contains(marca), "~/.jarvis/profilo.md")

        // 5. Ricerca Storico
        Store.shared.record(role: "tu", text: "test automatico: interrogazione di scienze", source: "selftest")
        let hits = Store.shared.search("interrogazione scienze")
        report("ricerca nello storico", !hits.isEmpty, "\(hits.count) risultati, log totale \(Store.shared.count()) righe")

        // 5b. Lista chat: da terminale lo storico e' un file separato, quindi si scrive
        // una riga vera (source "chat") e si vede se il raggruppamento la pesca.
        Store.shared.record(role: "tu", text: "prova lista chat di scienze", source: "chat")
        Store.shared.record(role: "jarvis", text: "tre compiti, due gia' fatti", source: "chat")
        let sessioni = Store.shared.sessions()
        report("lista chat: le sessioni si raggruppano", !sessioni.isEmpty,
               "\(sessioni.count) chat, l'ultima e' «\(sessioni.first?.titolo ?? "-")»")
        report("lista chat: il filo corrente c'e'",
               sessioni.contains { $0.id == Store.shared.sessioneAttuale },
               Store.shared.sessioneAttuale)
        report("lista chat: la riga di un test non entra in lista",
               Store.shared.sessions().allSatisfy { !$0.titolo.contains("test automatico") },
               "le fonti selftest/debug restano fuori")

        // 5c. Compiti: scrittura, lettura, scadenze dette a parole, spunta, watchdog
        let marcaCompito = "compito di prova \(Int(Date().timeIntervalSince1970))"
        _ = Compiti.salva(Compiti.leggi(tutti: true).filter { !$0.cosa.contains(marcaCompito) })
        let aggiunto = Compiti.aggiungi(materia: "scienze", cosa: marcaCompito,
                                       scadenza: "domani", pagina: "https://example.com/compiti")
        report("compiti: aggiunge", aggiunto.contains("Aggiunto"), String(aggiunto.prefix(110)))
        let letto = Compiti.lista()
        report("compiti: li rilegge con la scadenza",
               letto.contains(marcaCompito) && letto.contains("domani"), String(letto.prefix(120)))
        report("compiti: ritrova la pagina", letto.contains("example.com/compiti"),
               Compiti.paginaDiStudio())
        let venerdi = Compiti.aggiungi(materia: "matematica", cosa: marcaCompito + " ven",
                                       scadenza: "venerdi", pagina: "")
        report("compiti: «venerdi» diventa una data", venerdi.contains("entro 20"), String(venerdi.prefix(90)))
        report("compiti: niente doppioni",
               Compiti.aggiungi(materia: "scienze", cosa: marcaCompito, scadenza: "domani", pagina: "")
                   .contains("gia' nella lista"), "duplicato respinto")
        let segnato = Compiti.fatto(marcaCompito)
        report("compiti: si spunta", segnato.contains("Fatto"), String(segnato.prefix(90)))
        _ = Compiti.salva(Compiti.leggi(tutti: true).filter { !$0.cosa.contains(marcaCompito) })
        report("il test non lascia compiti nel file", !Compiti.lista().contains(marcaCompito), "~/.jarvis/compiti.md")

        let accesso = await MainActor.run { Studio.shared.accendi(pagina: "https://example.com/compiti", minuti: 1) }
        report("watchdog: si accende", accesso.contains("Modalita' compiti accesa"), String(accesso.prefix(110)))
        let statoStudio = await MainActor.run { Studio.shared.stato }
        report("watchdog: vede l'app davanti", statoStudio.contains("App davanti"), String(statoStudio.prefix(110)))
        let distrattici = await MainActor.run { Studio.distrazioni() }
        report("watchdog: lista distrazioni pronta", !distrattici.isEmpty,
               "\(distrattici.count) app in ~/.jarvis/distrazioni.txt")
        // la regola del "quando lo sgrido", provata senza dipendere dall'app davanti
        let liste = ["Fortnite", "Chrome"]
        report("watchdog: 45 s su Fortnite = scossa",
               Studio.deveScuotere(nome: "Fortnite", daQuanto: 45, dallUltima: 200, distrazioni: liste), "")
        report("watchdog: 20 s non bastano",
               !Studio.deveScuotere(nome: "Fortnite", daQuanto: 20, dallUltima: 200, distrazioni: liste),
               "sotto la soglia di 40 s")
        report("watchdog: Finder non e' una distrazione",
               !Studio.deveScuotere(nome: "Finder", daQuanto: 300, dallUltima: 300, distrazioni: liste), "")
        report("watchdog: non ripete subito",
               !Studio.deveScuotere(nome: "Fortnite", daQuanto: 300, dallUltima: 30, distrazioni: liste),
               "aspetta 150 s tra un avviso e l'altro")
        report("watchdog: basta il nome parziale",
               Studio.deveScuotere(nome: "Google Chrome", daQuanto: 60, dallUltima: 600, distrazioni: liste), "")
        _ = await MainActor.run { Studio.shared.spegni() }
        report("watchdog: si spegne", (await MainActor.run { Studio.shared.stato }).contains("spenta"), "spento")

        // 5e. ClasseViva: si salva solo indirizzi veri, e i compiti letti entrano in lista
        let marcaCv = "lettura cv \(Int(Date().timeIntervalSince1970))"
        report("classeviva: rifiuta le cose che non sono url",
               ClasseViva.salvaPagina("paperino").contains("Non mi sembra"), "paperino respinto")
        let fintaVisione = """
        2026-10-21 · scienze · \(marcaCv) cap. 5
        2026-10-22 · matematica · \(marcaCv) esercizi 30-34
        una riga senza separatori veri
        """
        let esitoCv = ClasseViva.incassa(fintaVisione)
        report("classeviva: i compiti letti finiscono in lista", esitoCv.contains("2 compiti"),
               String(esitoCv.prefix(110)))
        let fileCv = ((try? String(contentsOf: Compiti.path, encoding: .utf8)) ?? "")
        report("classeviva: la data letta diventa scadenza",
               fileCv.contains("2026-10-21 · scienze") && Compiti.lista().contains(marcaCv),
               String(fileCv.components(separatedBy: .newlines).last ?? "").prefix(120).description)
        _ = Compiti.salva(Compiti.leggi(tutti: true).filter { !$0.cosa.contains(marcaCv) })

        // 5f. Voce: si cambia senza ricompilare
        let vocePrima = ((try? String(contentsOf: AppPaths.voceSceltaFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        report("voce: le voci pronte sono piu' d'una", AppPaths.disponibili().count >= 2,
               AppPaths.disponibili().map { "\($0.nome) (\($0.desc))" }.joined(separator: ", "))
        report("voce: il cambio scrive la scelta", AppPaths.scegliVoce("riccardo").contains("Voce cambiata"),
               "attuale = \(AppPaths.voceCorrente)")
        report("voce: una voce inventata viene rifiutata",
               AppPaths.scegliVoce("morgan freeman").contains("Non conosco"), "")
        if !vocePrima.isEmpty { try? vocePrima.write(to: AppPaths.voceSceltaFile, atomically: true, encoding: .utf8) }

        // 5d. Voce: come viene riscritto il testo prima di parlarlo
        let detto = Speaker.normalizzaItaliano("18°C, 456 GB liberi, esercizi 14-18 entro 2026-10-20  e 20% in più")
        report("voce: numeri e unita' letti bene",
               detto.contains("gradi") && detto.contains("giga") && detto.contains("per cento"),
               String(detto.prefix(120)))
        report("voce: la data diventa ottobre", detto.contains("ottobre 2026"), String(detto.prefix(120)))
        report("voce: il trattino non e' 'meno'", detto.contains("dal 14 al 18"), "")
        report("voce: la scorciatoia ⌥ diventa option",
               Speaker.normalizzaItaliano("premi ⌥ Spazio").contains("option"), "")

        // 6. Tools locali immediati
        let t = Tools.shared

        let found = await t.run("trova_file", ["testo": "f1_simulator"])
        report("trova_file su Spotlight", found.contains("f1"), String(found.prefix(90)))

        report("porte Arduino", true, Tools.arduinoPorts().replacingOccurrences(of: "\n", with: " "))

        let vol = await t.run("volume", ["azione": "leggi"])
        report("volume del Mac", vol.contains("%"), String(vol.prefix(60)))

        let shot = await t.run("schermo", [:])
        let shotOk = shot.contains("schermo-") || shot.contains("could not create image") || shot.contains("Fallito")
        report("screenshot", shotOk, String(shot.prefix(70)))

        let df = await t.run("esegui_comando", ["comando": "df -h /"])
        report("comando lettura df -h", df.contains("%") || df.contains("Capacit"), String(df.prefix(70)))

        let blocked = await t.run("esegui_comando", ["comando": "sudo ls /var/root"])
        report("sudo rifiutato", blocked.contains("Non lo eseguo"), String(blocked.prefix(70)))

        // touch adesso e' permesso (politica scelta dall'utente): quello che resta
        // bloccato senza clic e' cancellare, quindi si prova quello.
        let bersaglio = "/tmp/jarvis-non-devo-cancellare.txt"
        try? "".write(toFile: bersaglio, atomically: true, encoding: .utf8)
        let needsClick = await t.run("esegui_comando", ["comando": "rm \(bersaglio)"])
        let clickBlocked = needsClick.contains("conferm") || needsClick.contains("detto di no")
        report("cancellazione bloccata senza conferma",
               clickBlocked && FileManager.default.fileExists(atPath: bersaglio),
               String(needsClick.prefix(80)))
        try? FileManager.default.removeItem(atPath: bersaglio)

        let stl = await t.run("genera_stl", ["forma": "scatola", "larghezza": "70", "profondita": "50",
                                             "altezza": "25", "spessore": "2", "cava": "si"])
        let stlOk = stl.contains(".stl") && !stl.hasPrefix("Fallito")
        report("genera STL parametrico", stlOk, String(stl.prefix(95)))

        // 2c-bis. la regola dell'utente sul provare gli invii: solo a lui o a nana
        report("una prova di invio a un'altra persona si ferma",
               GuardiaMessaggio.testFuoriDaiPermessi("Test di \(Marca.nome): questo te l'ho mandato io",
                                                     destinatario: "mamma") != nil,
               "mai spedire robe di prova a gente che non c'entra")
        // I due controlli qui sotto dipendono da ~/.jarvis/numero.txt e prove.txt: su
        // una macchina pulita non ci sono, e in quel caso devono dire "niente da
        // verificare", non "fallito" (un'app che la gente scarica non ha i suoi contatti).
        report("le prove agli autorizzati passano (se configurati)",
               GuardiaMessaggio.numeriPerLeProve.allSatisfy {
                   GuardiaMessaggio.testFuoriDaiPermessi("Test di \(Marca.nome)", destinatario: $0) == nil
               },
               "tutto quello che c'e' in numero.txt + prove.txt resta disponibile")
        report("«mandami» finisce sul numero del padrone di casa",
               GuardiaMessaggio.numeroDiCasa.isEmpty
                || GuardiaMessaggio.destinatarioVero(per: "+390000000000",
                                                     chiesto: "mandami un messaggio di prova")
                    == GuardiaMessaggio.numeroDiCasa,
               "il modello l'aveva scambiato per 'rispondi all'ultimo'")
        report("una richiesta per un'altra persona resta sua",
               GuardiaMessaggio.destinatarioVero(per: "nonna",
                                                 chiesto: "dici alla nonna che arrivo tra poco")
                   == "nonna",
               "nessun redirect se non ha chiesto per se'")
        report("un messaggio vero a chiunque passa",
               GuardiaMessaggio.testFuoriDaiPermessi("Ciao, non posso venire domani", destinatario: "mamma") == nil,
               "la guardia guarda solo le prove, non i messaggi")

        // 2c-ter. la promessa "non ti rubo lo schermo" deve essere scritta negli argomenti
        report("aprire una app gia' aperta non la porta davanti",
               Silenzio.argomentiApri("/Applications/Blender.app", eraGiaAperta: true) == ["-g", "/Applications/Blender.app"],
               "open -g senza -j: la app esiste gia'")
        report("aprire una app che non c'era la apre nascosta",
               Silenzio.argomentiApri("/Applications/Blender.app", eraGiaAperta: false) == ["-gj", "/Applications/Blender.app"],
               "-g + -j: nessun affaccio sullo schermo")
        report("la risposta a \(Identita.nome) dice la verita' su cosa si vede",
               Silenzio.loSchermoRestaTuo("Blender", eraGiaAperta: false).contains("non ti compare"),
               "deve dire che la app non si affaccia")
        // 2c-ter-bis. AppleScript: la via che il modello prende DA SOLO da quando i verbi
        // della .sdef stanno nel prompt, e che non passa da `open`
        let inventarioDiProva = [SchedaApp(nome: "Musica", percorso: "/System/Applications/Music.app",
                                           id: "com.apple.Music", categoria: "musica", versione: "1",
                                           schemi: [], estensioni: [], pilotabile: true,
                                           architettura: "arm64", ultimoUso: nil,
                                           comandiAppleScript: ["playpause"])]
        report("uno script che nomina una app viene riconosciuto",
               Silenzio.interpretabileOsascript(#"osascript -e 'tell application "Music" to playpause'"#,
                                                 in: inventarioDiProva)?.id == "com.apple.Music",
               "altrimenti AppleScript se la porta avanti e nessuno lo ferma")
        report("uno script che non nomina nessuna app non viene toccato",
               Silenzio.interpretabileOsascript("osascript -e 'return 2+2'", in: inventarioDiProva) == nil,
               "la guardia sta solo su chi puo' affacciare una finestra")
        report("un comando qualunque non e' uno script di app",
               Silenzio.interpretabileOsascript("df -h /", in: inventarioDiProva) == nil,
               "nil = si esegue com'e', senza nascondere niente")
        report("una app non nell'inventario non viene inventata",
               Silenzio.interpretabileOsascript(#"osascript -e 'tell application "Fantasma" to quit'"#,
                                                 in: inventarioDiProva) == nil,
               "nome sconosciuto = niente id, meglio non toccare")
        // 2c-quinquies. il ponte che si costruisce da sé quando installa una app nuova
        let cartellaPonti = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-ponti-di-prova")
        try? FileManager.default.removeItem(at: cartellaPonti)
        try? FileManager.default.createDirectory(at: cartellaPonti, withIntermediateDirectories: true)
        Integrazione.cartellaDiProva = cartellaPonti          // le prove non finiscono nelle sue
        func appDiProva(_ nome: String) -> SchedaApp {
            SchedaApp(nome: nome, percorso: "/Applications/\(nome).app", id: "it.prova." + nome.lowercased(),
                      categoria: "utility", versione: "1.0", schemi: ["keka"], estensioni: ["zip", "7z"],
                      pilotabile: true, architettura: "arm64", ultimoUso: nil,
                      comandiAppleScript: ["unpack all", "open"])
        }
        let keka = appDiProva("Keka")
        let bozza = Integrazione.bozzaPerGemini(keka)
        report("il testo che va a Gemini non porta percorsi del suo Mac",
               !bozza.contains("/Users") && !bozza.contains(NSHomeDirectory()) && !bozza.contains(Identita.nome),
               "escono il nome dell'app e le sue capacità dichiarate: il resto resta qui")
        report("la bozza porta i verbi che l'app dichiara da sé",
               bozza.contains("unpack all"),
               "senza la lista Gemini inventerebbe comandi che non esistono")
        let scheletro = Integrazione.scheletro(keka, nuvola: nil)
        report("senza chiave la scheda lo dice, non finge di aver chiesto",
               scheletro.contains("non usato"), "onestà degli stati: anche nei file scritti")
        report("la scheda locale ha già schemi URL e verbi",
               scheletro.contains("keka") && scheletro.contains("unpack all"),
               "i dati del bundle bastano per pilotarla anche senza nuvola")
        try? Integrazione.scheletro(keka, nuvola: "FRASI: comprimi questa cartella\nVERBI: unpack all, open")
            .write(to: Integrazione.filePer("Keka"), atomically: true, encoding: .utf8)
        report("il ponte si scrive e si rilegge",
               Integrazione.esiste("Keka") && (Integrazione.letta("Keka") ?? "").contains("FRASI"),
               "in ~/(cartella di prova), non nella sua")
        let nelPrompt = Integrazione.sintesiPerIlPrompt(keka)
        report("nel prompt non finisce la scheda intera",
               nelPrompt.count < 900 && nelPrompt.contains("unpack all") && !nelPrompt.contains("Ricette provate"),
               "poche righe: i token qui sono stati misurati, e costano risposte")
        report("un giro non fa più di tre ponti",
               Integrazione.daFare((1...5).map { appDiProva("Prova-\($0)") }, massimo: 3).count == 3,
               "il resto resta in coda per il giro dopo")
        report("il secondo blocco di scuse di Gemini non entra nella scheda",
               Integrazione.ripulisciNuvola("""
               FRASI: comprimi questo
               VERBI: comprimi, verifica
               SCHEMI: nessuno
               LIMITI: niente di più
               FRASI: perché sono modi naturali
               VERBI: perché sono nella sdef
               """) == "FRASI: comprimi questo\nVERBI: comprimi, verifica\nSCHEMI: nessuno\nLIMITI: niente di più",
               "visto dal vivo sul ponte di 'Ponte Prova': raddoppiava la scheda con i perché")
        report("una risposta fuori formato non sporca il ponte",
               Integrazione.ripulisciNuvola("Certo! Questa app serve a comprimere cose. Spero sia utile!") .isEmpty,
               "meglio una scheda locale onesta che un paragrafo che non pilota niente")
        report("«fai il ponte di Keka» chiede l'integrazione, non il circuito",
               Agent.strumentoGiusto("fai il ponte di Keka") == "apri_app",
               "senza indizio qwen3 rispondeva con il ponte di Wheatstone (misurato il 2026-10-22)")
        report("«crea l'integrazione per Keka» va sullo strumento delle app",
               Agent.strumentoGiusto("crea l'integrazione per Keka") == "apri_app",
               "la parola che usa lui, non quella che piace al modello")
        Integrazione.cartellaDiProva = nil
        try? FileManager.default.removeItem(at: cartellaPonti)

        // 2c-quater. la decisione "chiudo le app che ho aperto io"
        let diMezzo = Silenzio.Apertura(id: "com.aone.keka", nome: "Keka", motivo: .mezzo,
                                        quando: Date(), eraAperta: false)
        let chiesta = Silenzio.Apertura(id: "com.aone.keka", nome: "Keka", motivo: .richiesta,
                                        quando: Date(), eraAperta: false)
        let giaAperta = Silenzio.Apertura(id: "com.aone.keka", nome: "Keka", motivo: .mezzo,
                                          quando: Date(), eraAperta: true)
        let vecchia = Silenzio.Apertura(id: "com.aone.keka", nome: "Keka", motivo: .mezzo,
                                        quando: Date().addingTimeInterval(-40 * 60), eraAperta: false)
        report("l'app aperta per un lavoro si chiude alla fine",
               Silenzio.deveChiudere(diMezzo, davanti: "com.openai.chat"),
               "aperta lei, non lui, non in primo piano")
        report("quella che gli hai chiesto di aprire resta su",
               !Silenzio.deveChiudere(chiesta, davanti: nil),
               "motivo = richiesta")
        report("quella che gia' c'era non la chiude \(Marca.nome)",
               !Silenzio.deveChiudere(giaAperta, davanti: nil),
               "era gia' aperta: non e' merito ne' colpa sua")
        report("se lui se l'e' presa in mano non si tocca",
               !Silenzio.deveChiudere(diMezzo, davanti: "com.aone.keka"),
               "\(Identita.nome) ce l'ha davanti")
        report("dopo venti minuti non la chiudo piu' (potrebbe essere in uso)",
               !Silenzio.deveChiudere(vecchia, davanti: nil),
               "oltre 20 minuti: potrebbe starci lavorando")

        // 2c-septies. i suggerimenti a schermo: regole pure, niente effetti
        report("«domani» e' a un giorno", Suggerimenti.giorniDaOggi("domani") == 1, "letto da compiti.md")
        report("una data ISO si capisce", Suggerimenti.giorniDaOggi("2099-01-01") == nil
               || (Suggerimenti.giorniDaOggi("2099-01-01") ?? 0) > 300, "oltre un anno")
        report("una scadenza di due giorni fa' «in arrivo»",
               Suggerimenti.regole(Suggerimenti.Contesto(ora: 15, giornoDiScuola: false, compitiOggi: 0,
                                                         compitiEntro3: 2, stampaInCorso: false, stampaFinita: false,
                                                         appuntiPieni: false, inCarica: true))
                   .contains { $0.chip == "Cose in arrivo" },
               "la lista non deve essere vuota quando ci sono compiti")
        report("la stampa in corso va per prima",
               Suggerimenti.regole(Suggerimenti.Contesto(ora: 15, giornoDiScuola: false, compitiOggi: 3,
                                                         compitiEntro3: 0, stampaInCorso: true, stampaFinita: false,
                                                         appuntiPieni: true, inCarica: true)).first?.chip == "Quanto manca?",
               "e' la cosa piu' urgente e non lo sa nessuno tranne il MQTT")
        report("i suggerimenti non sono mai piu' di quattro",
               Suggerimenti.regole(Suggerimenti.Contesto(ora: 8, giornoDiScuola: true, compitiOggi: 4,
                                                         compitiEntro3: 9, stampaInCorso: true, stampaFinita: true,
                                                         appuntiPieni: true, inCarica: false)).count <= 4,
               "quattro chip sopra la barra di input e' il massimo reggibile")
        report("il pomeriggio senza niente da dire non inventa",
               Suggerimenti.regole(Suggerimenti.Contesto(ora: 15, giornoDiScuola: false, compitiOggi: 0,
                                                         compitiEntro3: 0, stampaInCorso: false, stampaFinita: false,
                                                         appuntiPieni: false, inCarica: true)).isEmpty,
               "meglio il vuoto che un consiglio a caso")

        // 2c-sexies. l'innesco del briefing: largo quanto basta, stretto dove serve
        report("«facciamo il punto» fa il briefing", Giornata.innesco("facciamo il punto"),
               "innesco corto e diretto")
        report("«la giornata» fa il briefing", Giornata.innesco("la giornata"),
               "era la #4 della lista del 2026-10-17")
        report("una domanda sulla giornata di ieri NON lo fa",
               !Giornata.innesco("come e' andata la giornata di ieri a scuola?"),
               "quella la deve leggere il modello")
        report("una frase lunga non innesca il briefing",
               !Giornata.innesco("la giornata oggi e' stata una giornata infinita"),
               "evita falsi positivi")

        // 2c-quinquies. la memoria non deve rubare i compiti
        report("«segna questo come compito» non finisce nel profilo",
               Agent.fattoDaSalvare("segna questo come compito") == nil,
               "e' un compito: va in compiti.md, non nelle verita' su di lui")
        report("una frase corta vuota non viene salvata come fatto",
               Agent.fattoDaSalvare("ricordati questo") == nil,
               "due parole non sono un fatto")
        report("un fatto vero si salva ancora",
               Agent.fattoDaSalvare("ricordati che il mio banco si chiama Polo")?.fatto.contains("Polo") == true,
               "la memoria buona non si rompe")
        report("gli appunti non sono un fatto sul profilo",
               Agent.fattoDaSalvare("segna questo dagli appunti") == nil,
               "la parola 'appunti' se ne occupa lo strumento")

        // 2d. verdetto di blocco e inventario app: pure funzioni, niente effetti
        fintaApp = [SchedaApp(nome: "Blender", percorso: "/Applications/Blender.app",
                              id: "org.blenderfoundation.blender", categoria: "grafica e 3D",
                              versione: "5.0", schemi: [], estensioni: ["blend"], pilotabile: true,
                              architettura: "Apple Silicon", ultimoUso: nil)]
        report("la domanda nomina un'app e la scheda arriva nel prompt",
               InventarioApp.notaSullaDomanda("cosa puoi fare con blender?", in: fintaApp!)
                   .contains("apre file: blend"),
               "deve portare i dati del bundle, non la memoria del modello")
        report("una domanda senza app non aggiunge niente",
               InventarioApp.notaSullaDomanda("che tempo fa?", in: fintaApp!).isEmpty,
               "nota vuota = prompt pulito")
        report("il verdetto di blocco viene riportato com'e'",
               Agent.verdettoDaRiportare("NON COLLEGATO: nella riga codice = c'e' la seriale"),
               "NON COLLEGATO: deve arrivare intero a \(Identita.nome)")
        report("una risposta normale se la scrive il modello",
               !Agent.verdettoDaRiportare("Ugello a 210 gradi, letto al 64 per cento"),
               "non e' un blocco: il modello la riscrive")
        // Il secondo giro: l'indizio sullo strumento e il blocco delle chiamate fuori
        // luogo. Nati dal vedere `genera_stl` ESEGUITO per «che tempo fa?».
        report("l'indizio nomina meteo per la domanda sul tempo",
               Agent.indizioStrumento("Che tempo fa?").contains("`meteo`"),
               Agent.indizioStrumento("Che tempo fa?"))
        report("l'indizio nomina f1 per il mondiale piloti",
               Agent.indizioStrumento("chi sta vincendo il mondiale piloti?").contains("`f1`"),
               "deve dire f1")
        report("«notizie di sport» nomina notizie, non il web",
               Agent.strumentoGiusto("dimmi un po' di notizie di sport") == "notizie",
               "bocciata nella suite del 2026-10-22: non chiamava niente")
        report("«su internet» vince ancora su notizie",
               Agent.strumentoGiusto("cercami su internet quando esce l'iphone nuovo") == "cerca_web",
               "l'ordine della tabella conta: la riga cerca_web viene prima")
        report("l'indizio non spara a caso su una domanda che non conosce",
               Agent.indizioStrumento("come stai oggi?").isEmpty,
               "nessuna parola nota = nessun consiglio")
        report("il GP di Austin chiede f1, non l'orario di scuola",
               Agent.strumentoGiusto("quanto manca al GP di Austin?") == "f1",
               Agent.strumentoGiusto("quanto manca al GP di Austin?") ?? "nil")
        report("«il file della simulazione f1» e' trova_file, non f1",
               Agent.strumentoGiusto("cercami il file della simulazione f1") == "trova_file",
               "l'ordine della tabella conta: prima il file, poi la Formula 1")
        report("«accendi l'orecchio» non viene rimbalzato su messaggi",
               Agent.strumentoGiusto("accendi l'orecchio dei messaggi") == nil,
               "nessun indizio = nessuna forzatura: orecchio resta la scelta giusta")
        report("chi legge i nuovi messaggi puo' usare anche l'orecchio",
               Agent.alternativeDi("leggi i nuovi messaggi").contains("orecchio"),
               "orecchio deve stare tra le alternative ammesse")
        report("i tick CPU: metà inattivi = metà occupata",
               Sensori.percentualeDaTick(utente: 40, sistema: 10, inattivo: 50, nice: 0) == 50,
               "1 - 50/100 = 50%")
        report("i tick CPU: tutto inattivo dà zero",
               Sensori.percentualeDaTick(utente: 0, sistema: 0, inattivo: 100, nice: 0) == 0,
               "nessun lavoro = 0%")
        report("i tick CPU: zero inattivi dà cento",
               Sensori.percentualeDaTick(utente: 70, sistema: 30, inattivo: 0, nice: 0) == 100,
               "macchina piena")
        report("i tick CPU: nessun tick non inventa nulla",
               Sensori.percentualeDaTick(utente: 0, sistema: 0, inattivo: 0, nice: 0) == 0,
               "totale zero -> 0, non divisione per zero")
        // MARK: il piano di risparmio (Risparmio.decidi): la regola, provata senza staccare il cavo
        let freddo = ProcessInfo.ThermalState.nominal
        let bollente = ProcessInfo.ThermalState.serious
        let dorme = Risparmio.decidi(carica: false, termica: freddo, risparmioSistema: false, modo: .dormi)
        report("a batteria (dormi): niente sorveglianza, niente letture, niente anelli, server chiuso",
               !dorme.sorveglianza && !dorme.diagnostica && !dorme.inventario
                && !dorme.animazioni && !dorme.server && !dorme.siChiude,
               dorme.perche)
        report("a batteria (dormi): la priorita' e' background, non utility",
               dorme.priorita == .background, "\(dorme.priorita)")
        let chiude = Risparmio.decidi(carica: false, termica: freddo, risparmioSistema: false, modo: .esci)
        report("a batteria (esci): l'app dice di chiudersi", chiude.siChiude, chiude.perche)
        let continua = Risparmio.decidi(carica: false, termica: freddo, risparmioSistema: false, modo: .lavora)
        report("a batteria (lavora): la sorveglianza torna, il conto delle app resta spento",
               continua.sorveglianza && !continua.inventario && continua.diagnosticaLenta && !continua.server,
               continua.perche)
        let acceso = Risparmio.decidi(carica: true, termica: freddo, risparmioSistema: false, modo: .dormi)
        report("all'alimentatore: tutto attivo, anche se lui ha detto dormi",
               acceso.sorveglianza && acceso.inventario && acceso.diagnostica && acceso.animazioni
                && acceso.server && !acceso.diagnosticaLenta && !acceso.siChiude,
               acceso.perche)
        let caldo = Risparmio.decidi(carica: true, termica: bollente, risparmioSistema: false, modo: .dormi)
        report("all'alimentatore ma scotta: niente scansione app e letture a passo lento",
               !caldo.inventario && caldo.diagnostica && caldo.diagnosticaLenta && caldo.sorveglianza,
               caldo.perche)
        let risparmioDiScuola = Risparmio.decidi(carica: true, termica: freddo, risparmioSistema: true, modo: .dormi)
        report("Modalita Risparmio Energetico del sistema: stesso passo lento",
               risparmioDiScuola.diagnosticaLenta && !risparmioDiScuola.inventario,
               risparmioDiScuola.perche)
        report("la scelta 'esci' non chiude MAI l'app mentre e' attaccata",
               !acceso.siChiude && !caldo.siChiude,
               "a corrente si lavora: la scelta vale solo a batteria staccata")
        // MARK: la voce a flusso (DivisoreDiFrasi): parlare sulla prima frase
        var div = DivisoreDiFrasi()
        report("la frase chiusa esce subito, quella a meta' resta dentro",
               div.appenda("Ho controllato il disco. Manc") == ["Ho controllato il disco."],
               "una sola frase da dire, il resto non esiste ancora")
        report("i decimali non spezzano una frase",
               div.appenda("Ho controllato il disco. Mancano 64.5 giga liberi.") == ["Mancano 64.5 giga liberi."],
               "il punto di 64.5 non e' un punto fermo")
        var tre = DivisoreDiFrasi()
        report("sotto i 14 caratteri la voce non si sveglia per tre parole",
               tre.appenda("Sì.").isEmpty,
               "un processo piper + un WAV per «Sì.» non e' risparmio, e lo si dice alla fine")
        var corto = DivisoreDiFrasi()
        _ = corto.appenda("Sì.")
        report("quello che resta lo dice chiudi(), non sparisce",
               corto.chiudi() == ["Sì."], "l'ultima frase non ha il punto: va detta lo stesso")
        var codice = DivisoreDiFrasi()
        report("il codice non si legge a voce",
               codice.appenda("Prova a scrivere ```\nrm -rf /tmp/x\n``` e dimmi").isEmpty,
               "dentro i backtick si tace, altrimenti Jarvis recita i punti e le barre")
        var dopo = DivisoreDiFrasi()
        _ = dopo.appenda("Prima frase lunga abbastanza. ")
        report("un a capo chiude una frase come il punto",
               dopo.appenda("Prima frase lunga abbastanza. Seconda riga che chiude.\nTerza in corso")
                   == ["Seconda riga che chiude."],
               "dopo il punto fermo della prima, la seconda si chiude a capo")
        var righe = DivisoreDiFrasi()
        report("le risposte a elenco si dicono riga per riga, anche senza punto",
               righe.appenda("Latte, pane e uova\n\nTi avviso giovedi") == ["Latte, pane e uova"],
               "il modello scrive a capo: aspettare il punto vorrebbe dire non parlare")
        var taglio = DivisoreDiFrasi()
        _ = taglio.appenda("Ho controllato")
        report("un punto che arriva nel frammento successivo non schianta niente",
               taglio.appenda("Ho controllato. Ti dico ora") == ["Ho controllato."],
               "il punto era il primo carattere del pezzo nuovo: index(before:) andava fuori")
        var ripartenza = DivisoreDiFrasi()
        _ = ripartenza.appenda("Ciao come va stasera.")
        report("se il fumetto viene azzerato non ripete la parte vecchia",
               ripartenza.appenda("Ricomincio da qui e va bene.") == ["Ricomincio da qui e va bene."],
               "solo la frase nuova: «Ciao come va stasera» non deve essere detta due volte")
        report("la scheda dice i verbi che l'app dichiara da se'",
               InventarioApp.sintesi(SchedaApp(nome: "Musica", percorso: "/Applications/Musica.app",
                                               id: "com.apple.Music", categoria: "musica", versione: "1",
                                               schemi: [], estensioni: [], pilotabile: true,
                                               architettura: "arm64", ultimoUso: nil,
                                               comandiAppleScript: ["playpause", "current track"]))
                   .contains("playpause"),
               "non 'prova a pilotarla': verbi suoi, scritti da chi ha fatto l'app")
        report("senza verbi letti la scheda non ne inventa",
               !InventarioApp.sintesi(SchedaApp(nome: "Keka", percorso: "/Applications/Keka.app", id: "a.b",
                                                categoria: "utility", versione: "1", schemi: [], estensioni: [],
                                                pilotabile: false, architettura: "arm64", ultimoUso: nil))
                   .contains("comandi AppleScript suoi"),
               "pilotabile = false deve restare tale")
        report("la .sdef finta dà i suoi comandi, non testo a caso",
               InventarioApp.comandiDaSdef("""
               <sdef><suite><command name="playpause"/><command name="reveal"/><class name="track"/></suite></sdef>
               """).contains("playpause"),
               "il parser legge <command name=...>, che e' la forma vera del file")
        report("il recupero di f1 legge Austin come gara di Austin",
               Agent.argomentiDiRicupero("f1", "quanto manca al GP di Austin?")?["tipo"] == "austin",
               Agent.argomentiDiRicupero("f1", "quanto manca al GP di Austin?").map { "\($0)" } ?? "nil")
        report("il recupero di f1 per i piloti chiede la classifica piloti",
               Agent.argomentiDiRicupero("f1", "chi sta vincendo il mondiale piloti?")?["tipo"] == "piloti",
               "piloti")
        report("il recupero del volume legge il numero detto a voce",
               Agent.argomentiDiRicupero("volume", "alza il volume a 40") == ["azione": "metti", "valore": "40"],
               Agent.argomentiDiRicupero("volume", "alza il volume a 40").map { "\($0)" } ?? "nil")
        report("il recupero delle notizie sceglie la sezione ANSA che esiste davvero",
               Agent.argomentiDiRicupero("notizie", "dimmi un po' di notizie di sport") == ["argomento": "sport"],
               "era il buco: 'notizie' non era nella lista del recupero e la frase restava senza risposta")
        report("senza una sezione detta le notizie vanno in prima pagina",
               Agent.argomentiDiRicupero("notizie", "che si dice oggi?") == ["argomento": "prima pagina"],
               "le sezioni sbagliate su ANSA rispondono 404")
        report("«fai il ponte di Keka» in recupero chiama l'integrazione, non la lista",
               Agent.argomentiDiRicupero("apri_app", "fai il ponte di Keka") == ["azione": "integra", "nome": "Keka"],
               "se l'ha chiesto con parole sue, il recupero fa proprio quello")
        report("una domanda di app normale non finisce sull'integrazione",
               Agent.argomentiDiRicupero("apri_app", "che app ho per montare video?")?["azione"] == "lista",
               "l'azione integra scatta solo se la frase parla di ponte/integrazione")
        report("il recupero del meteo usa la citta' configurata, non quella di chi ha scritto il codice",
               Agent.argomentiDiRicupero("meteo", "che tempo fa?")?["citta"] == (Identita.citta ?? ""),
               Identita.citta ?? "nessuna citta' in ~/.jarvis/citta.txt")
        report("una citta' detta nella frase vince su quella configurata",
               Agent.argomentiDiRicupero("meteo", "che tempo fa a Torino?")?["citta"] == "Torino",
               Agent.argomentiDiRicupero("meteo", "che tempo fa a Torino?")?["citta"] ?? "nil")
        report("le parole chiave tolgono le istruzioni e lasciano la cosa",
               Agent.paroleChiave("cercami il file della simulazione f1").contains("simulazione"),
               Agent.paroleChiave("cercami il file della simulazione f1"))
        report("nessun recupero per gli strumenti che scrivono o mandano",
               Agent.argomentiDiRicupero("esegui_comando", "apri il terminale") == nil
                && Agent.argomentiDiRicupero("stampa", "stampa questa cosa") == nil
                && Agent.argomentiDiRicupero("genera_stl", "fammi una scatola") == nil
                && Agent.argomentiDiRicupero("whatsapp", "manda un whatsapp") == nil,
               "eseguire noi al posto del modello vale solo per chi legge")
        report("una domanda che non conosce non riceve indizi",
               Agent.suggerimentoStrumento("come stai oggi?") == nil,
               "nil = nessuna lista ristretta, nessuna forzatura")
        report("genera_stl bloccato se la domanda non parla di 3D",
               Agent.chiamataFuoriLuogo("genera_stl", domanda: "che tempo fa?") != nil,
               "meteo non deve generare una scatola")
        report("genera_stl libero se la domanda e' davvero di 3D",
               Agent.chiamataFuoriLuogo("genera_stl", domanda: "fammi una scatola 60x40x30 per i cavi") == nil,
               "qui va eseguito, non bloccato")
        report("esegui_comando libero per una richiesta di terminale",
               Agent.chiamataFuoriLuogo("esegui_comando", domanda: "apri il terminale e dimmi lo spazio") == nil,
               "il blocco non deve mangiarsi i casi veri")
        report("aggiorna_profilo bloccato se nessuno ha chiesto di ricordare",
               Agent.chiamataFuoriLuogo("aggiorna_profilo", domanda: "che app ho per montare video?") != nil,
               "non si scrive nel profilo per sbaglio")
        report("gli strumenti di lettura non vengono mai bloccati",
               Agent.chiamataFuoriLuogo("meteo", domanda: "che tempo fa?") == nil
                && Agent.chiamataFuoriLuogo("volume", domanda: "alza il volume a 40") == nil,
               "il cancello sta solo su chi tocca il Mac")
        report("la categoria delle app esce in italiano",
               InventarioApp.categoriaUmana("public.app-category.utilities") == "utilità",
               InventarioApp.categoriaUmana("public.app-category.utilities"))
        report("il trattino sta DENTRO il nome, non dopo il prefisso",
               InventarioApp.categoriaUmana("public.app-category.graphics-design") == "grafica e 3D",
               "era qui il bug che faceva 'altro' per tutte e 168 le app")
        report("le categorie Apple lette dai bundle veri tornano",
               InventarioApp.categoriaUmana("public.app-category.productivity") == "produttività"
                && InventarioApp.categoriaUmana("public.app-category.photography") == "foto"
                && InventarioApp.categoriaUmana("public.app-category.social-networking") == "social",
               "photography e social-networking sono le forme vere: la mappa vecchia aveva photo e social-media")
        report("una categoria che non conosciamo non diventa 'altro' muto",
               InventarioApp.categoriaUmana("public.app-category.cose-nuove") == "cose nuove",
               "meglio la parola sua letta umana che 'altro', che non dice niente")
        report("i tipi di file numerici non rubano il posto a zip e 7z",
               InventarioApp.estensioniPerLaScheda(["001", "002", "zip", "7z", "rar"]).prefix(3).map { $0 } == ["7z", "rar", "zip"],
               "Keka dichiara .001….014: con l'ordine alfabetico puro la scheda non diceva cosa comprime davvero")
        report("la categoria sconosciuta non e' vuota",
               InventarioApp.categoriaUmana("").isEmpty == false && InventarioApp.categoriaUmana("") == "altro",
               "vuoto -> 'altro'")
        report("il nome dell'app si normalizza senza accenti e '.app'",
               InventarioApp.senzaAccenti("CrossOver") == "crossover", InventarioApp.senzaAccenti("CrossOver"))
        report("la distanza di Levenshtein conta i caratteri",
               InventarioApp.distanza("crossover", "corsover") == 2, "due swap = 2")
        report("un uso lontano dice 'mesi fa'",
               SchedaApp(nome: "x", percorso: "/Applications/x.app", id: "x", categoria: "altro",
                         versione: "1", schemi: [], estensioni: [], pilotabile: false,
                         architettura: "Apple Silicon",
                         ultimoUso: Date(timeIntervalSinceNow: -60 * 60 * 24 * 90)).usoUmano.contains("mesi"),
               "novanta giorni")
        report("mai aperta lo dice davvero",
               SchedaApp(nome: "x", percorso: "/Applications/x.app", id: "x", categoria: "altro",
                         versione: "1", schemi: [], estensioni: [], pilotabile: false,
                         architettura: "Apple Silicon", ultimoUso: nil).usoUmano.contains("mai"),
               "nessuna data da Spotlight")

        let dt = ProcessInfo.processInfo.systemUptime - t0
        print(String(format: "\n== Fine test rapido: completato in %.1fs ==\n", dt))
    }

    // MARK: - Test Rete e Modello Completo

    static func rete() async {
        let t0 = ProcessInfo.processInfo.systemUptime
        AppPaths.prepare()
        Tools.confirm = { _ in false }
        print("== JARVIS TEST RETE E MODELLO ==\n")

        let alive = await Brain.shared.isAlive()
        guard alive else {
            print("Ollama non e' avviato: impossibile eseguire i test di rete/modello.\n")
            return
        }

        let tw0 = ProcessInfo.processInfo.systemUptime
        await Brain.shared.warmUp()
        print("  modello caricato in RAM in \(String(format: "%.1f", ProcessInfo.processInfo.systemUptime - tw0))s")

        await chatTest("Rispondi solo con la parola: pronto")
        await toolTest()

        let t = Tools.shared

        let drivers = await t.run("f1", ["tipo": "piloti"])
        report("f1 piloti", drivers.contains("Classifica"), drivers.split(separator: "\n").prefix(3).joined(separator: " | "))

        let next = await t.run("f1", ["tipo": "prossima"])
        report("f1 prossima gara con countdown", next.contains("Prossima") || next.contains("mancano"), String(next.prefix(90)))

        let austin = await t.run("f1", ["tipo": "austin"])
        report("f1 gara Austin con countdown", austin.contains("Austin") || austin.contains("mancano") || austin.contains("GP"), String(austin.prefix(90)))

        let wx = await t.run("meteo", ["citta": "Milano"])
        report("meteo Milano", wx.contains("Meteo"), String(wx.prefix(90)))

        let web = await t.run("cerca_web", ["cosa": "Formula 1 GP Austin 2026"])
        report("ricerca web (DuckDuckGo)", web.contains("Risultati per") && web.contains("http"), String(web.prefix(70)))

        let news = await t.run("notizie", ["argomento": "cronaca"])
        report("notizie ANSA", news.contains("•"), String(news.prefix(70)))

        let pagina = await t.run("leggi_pagina", ["url": "https://example.com"])
        report("lettura pagina web", pagina.contains("Testo di"), String(pagina.prefix(70)))

        let rasp = await t.run("raspberry", ["azione": "stato"])
        let raspOk = rasp.contains("load") || rasp.contains("up ") || rasp.contains("Mem:") || rasp.contains("non risponde")
        report("raspberry via SSH", raspOk, String(rasp.prefix(80)).replacingOccurrences(of: "\n", with: " | "))

        let ping = await t.run("invia_ad_arduino", ["comando": "ping"])
        let ponteOk = ping.lowercased().contains("porta") && !ping.contains("Manca lo script")
            && !ping.contains("Fallito") && !ping.contains("Errore")
        report("ponte Python/Arduino", ponteOk, String(ping.prefix(90)))

        sttTest()

        let dt = ProcessInfo.processInfo.systemUptime - t0
        print(String(format: "\n== Fine test rete: completato in %.1fs ==\n", dt))
    }

    /// Quanto costano in token il prompt di sistema e i 20 strumenti.
    static func misuraCosto() async {
        let dati = (try? JSONSerialization.data(withJSONObject: Tools.shared.definitions, options: [.prettyPrinted])) ?? Data()
        let compatti = (try? JSONSerialization.data(withJSONObject: Tools.shared.definitions)) ?? Data()
        print("strumenti:", Tools.shared.definitions.count)
        print("descrizioni lette dal modello: \(compatti.count) byte compatti (\(dati.count) con a capo)")
        print("prompt di sistema: \(JarvisCore.systemPrompt().utf8.count) byte")

        let messaggi = [["role": "user", "content": "Ciao, come stai?"]]
        for (nome, conTools) in [("senza strumenti", false), ("con tutti gli strumenti", true)] {
            var payload: [String: Any] = [
                "model": "qwen3:8b", "stream": false, "think": false, "keep_alive": "5m",
                "options": ["temperature": 0.2, "num_ctx": 8192], "messages": messaggi
            ]
            if conTools { payload["tools"] = Tools.shared.definitions }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            let t0 = ProcessInfo.processInfo.systemUptime
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let dt = ProcessInfo.processInfo.systemUptime - t0
            print("  \(nome): prompt = \(obj["prompt_eval_count"] ?? 0) token, tempo \(String(format: "%.1f", dt))s")
        }
        print("\n== in RAM adesso ==")
        print(await Shell.run("/usr/local/bin/ollama", ["ps"], timeout: 20))
    }

    /// Stacca la vista dalla finestra di prova prima di uscire: il render di
    /// `NSHostingView` in corso era parte del problema degli .ips.
    @MainActor private static func scollaFinestraDiProva(_ finestra: NSWindow) {
        finestra.contentView?.removeFromSuperview()
        finestra.contentView = nil
        finestra.orderOut(nil)
    }

    @MainActor private static func scatto(to path: String) {
        let core = JarvisCore.shared
        core.headline = "qwen3:8b · ascolto pronto · voce " + Speaker.shared.voiceName
        core.bubbles = [
            Bubble(role: "user", text: "Quanti giga liberi ho sul disco?"),
            Bubble(role: "note", text: "→ esegui_comando {\"comando\":\"df -h\"}"),
            Bubble(role: "jarvis", text: "Hai 456 GB liberi sul disco principale, quindi stai tranquillo."),
            Bubble(role: "user", text: "E il Raspberry com'è?")
        ]
        core.pendingCommand = "brew install wget"
        let vista = JarvisPanel(core: core).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: vista)
        renderer.scale = 2
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render fallito")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("scatto salvato: \(path) (\(Int(img.size.width))x\(Int(img.size.height)))")
    }

    @MainActor static func scattoFinestra(to path: String) {
        let core = JarvisCore.shared
        core.headline = "qwen3:8b · voce " + Speaker.shared.voiceName
        core.bubbles = [
            Bubble(role: "user", text: "Quanti giga liberi ho sul disco?"),
            Bubble(role: "note", text: "→ esegui_comando {\"comando\":\"df -h\"}"),
            Bubble(role: "jarvis", text: "Hai 451 GiB liberi su /."),
            Bubble(role: "user", text: "E il Raspberry com'e'?"),
            Bubble(role: "jarvis", text: "Carico 2.0, temperatura 52°C, su da un giorno e 12 ore.")
        ]
        core.pendingCommand = "brew install wget"
        let vista = JarvisFinestra(core: core).frame(width: 1080, height: 660).preferredColorScheme(.dark)
        let r = ImageRenderer(content: vista)
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
           let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("finestra salvata: \(path)")
        }
    }

    private static func gateTest() {
        let cases: [(String, String)] = [
            ("ls -la ~", "allowed"),
            ("df -h", "allowed"),
            ("git status -sb", "allowed"),
            ("pmset -g batt", "allowed"),
            ("find . -name '*.py' -maxdepth 2", "allowed"),
            ("find . -exec rm {} ;", "confirm"),
            ("ollama list", "allowed"),
            ("ls | wc -l", "allowed"),
            // politica nuova (l'utente, 2026-10-18): accesso pieno, clic solo sul pericoloso
            // ma "installare" esegue codice di altri (formula, Makefile, pacchetto npm):
            // dal 2026-10-30 chiede il clic, come git push
            ("brew install wget", "confirm"),
            ("make deploy", "confirm"),
            ("npx create-qualcosa", "confirm"),
            ("pip3 install pacchetto", "confirm"),
            ("swift run", "confirm"),
            ("swift build", "allowed"),
            ("echo ciao >> ~/.zshrc", "confirm"),
            ("git commit -m \"sistemo i conti\"", "allowed"),
            ("touch ~/Desktop/appunti.txt", "allowed"),
            ("mkdir -p ~/programmi/prova", "allowed"),
            ("git push origin main", "confirm"),
            ("rm -rf ~/Documents/prova", "confirm"),
            ("rm -rf ~", "blocked"),
            ("defaults write com.apple.dock autohide -bool yes", "confirm"),
            ("python3 -c 'import os'", "confirm"),
            ("awk 'BEGIN{system(\"id\")}'", "confirm"),
            ("ls > /tmp/scheda.txt", "confirm"),
            ("sudo pmset -a sleep 0", "blocked"),
            ("cat ~/.ssh/id_rsa", "blocked"),
            ("rm -rf /", "blocked"),
            ("pmset sleepnow", "blocked"),
            ("ls ~/Desktop/Matteo", "blocked")
        ]
        var wrong = 0
        for (cmd, want) in cases {
            let got: String
            switch ShellGate.classify(cmd) {
            case .allowed: got = "allowed"
            case .confirm: got = "confirm"
            case .blocked: got = "blocked"
            }
            if got != want {
                wrong += 1
                print("  FAIL cancello: «\(cmd)» dava \(got), doveva \(want)")
            }
        }
        report("cancello shell (\(cases.count) casi)", wrong == 0,
               wrong == 0 ? "tutti i giudizi giusti" : "\(wrong) giudizi sbagliati")

        let bugie = ["Ho aperto il Finder.", "La pagina Chrome mostra il simulatore F1. È attivo e visibile.",
                     "Apri YouTube e cerca Alberto Naska.", "Vai su Impostazioni e controlla tu."]
        let lecite = ["Sono 456 GB liberi.", "Antonelli è primo con 340 punti.", "Ciao, come va?",
                      "Ho messo il volume al 40%."].dropLast()
        var sbagli = 0
        for b in bugie where !Agent.suonaFalsato(b) { sbagli += 1; print("  FAIL non rilevata: \(b)") }
        for l in lecite where Agent.suonaFalsato(l) { sbagli += 1; print("  FAIL scartata a torto: \(l)") }
        report("rilevatore di invenzioni", sbagli == 0, "\(bugie.count + lecite.count) frasi del log provate")
    }

    private static func chatTest(_ prompt: String) async {
        let t0 = ProcessInfo.processInfo.systemUptime
        do {
            let r = try await Brain.shared.stream(
                turns: [ChatTurn(role: "system", content: "Sei \(Marca.nome). Rispondi cortissimo."),
                        ChatTurn(role: "user", content: prompt)],
                tools: []) { _ in }
            let secs = ProcessInfo.processInfo.systemUptime - t0
            report("risposta semplice (\(String(format: "%.1f", secs))s)", !r.text.isEmpty,
                   r.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70).description)
        } catch {
            report("risposta semplice", false, error.localizedDescription)
        }
    }

    private static func toolTest() async {
        let prompt = "Guarda la classifica piloti della stagione 2026 e dimmi chi e primo."
        do {
            let r = try await Brain.shared.stream(
                turns: [ChatTurn(role: "system", content: JarvisCore.systemPrompt()),
                        ChatTurn(role: "user", content: prompt)],
                tools: Tools.shared.definitions) { _ in }
            let ok = !r.calls.isEmpty
            report("il modello chiama i tool", ok,
                   ok ? r.calls.map { $0.name }.joined(separator: ", ") : "nessun tool richiesto (\(r.text.prefix(50)))")
        } catch {
            report("il modello chiama i tool", false, error.localizedDescription)
        }
    }

    private static func sttTest() {
        let phrase = "\(Marca.nome), dimmi la classifica della formula uno"
        guard let bin = AppPaths.whisperBinary else {
            report("whisper-cli presente", false, "run brew install whisper-cpp")
            return
        }
        report("whisper-cli trovato", true, bin)
        guard FileManager.default.fileExists(atPath: AppPaths.whisperModel.path) else {
            report("modello di ascolto", false, AppPaths.whisperModel.path)
            return
        }
        let dir = AppPaths.tmp
        let aiff = dir.appendingPathComponent("test.aiff").path
        let wav = dir.appendingPathComponent("test.wav").path
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Alice", "-o", aiff, phrase]
        let conv = Process()
        conv.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        conv.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav]
        do {
            try say.run(); say.waitUntilExit()
            try conv.run(); conv.waitUntilExit()
        } catch {
            report("sintesi di prova", false, error.localizedDescription)
            return
        }
        guard FileManager.default.fileExists(atPath: wav) else {
            report("conversione in WAV", false, "afconvert non ha prodotto il file")
            return
        }
        let t0 = ProcessInfo.processInfo.systemUptime
        let text = runSync(bin, ["-m", AppPaths.whisperModel.path, "-f", wav, "-l", "it", "-nt", "-np", "-t", "6"])
        let secs = ProcessInfo.processInfo.systemUptime - t0
        let clean = text.split(separator: "\n").joined(separator: " ")
        let ok = clean.lowercased().contains("classifica") || clean.lowercased().contains("formula")
        report("orecchie: \(String(format: "%.1f", secs))s per trascrivere", ok, clean.trimmingCharacters(in: .whitespaces).prefix(90).description)
    }

    /// Collaudo della modalita' a batteria: il cervello deve stare su Gemini,
    /// le mani (strumenti) sul Mac, e i contenuti privati non devono salire.
    static var batteriaBocciata = false

    static func provaBatteria() async {
        var promossi = 0, bocciati = 0
        func prova(_ nome: String, _ ok: Bool, _ dettaglio: String = "") {
            print("  \(ok ? "ok  " : "FAIL") \(nome)\(dettaglio.isEmpty ? "" : " — \(dettaglio.prefix(110))")")
            if ok { promossi += 1 } else { bocciati += 1 }
        }

        print("== BATTERIA: \(Alimentazione.descrizione()), scelta \(CervelloPortatile.scelta()) ==")
        guard Gemini.pronto else {
            print("FAIL chiave Gemini assente: a batteria senza cloud non c'e' il cervello")
            batteriaBocciata = true
            return
        }

        // 1. l'interruttore
        _ = CervelloPortatile.imposta("gemini")
        CervelloPortatile.forzatoPerTest = true
        prova("a batteria forzato uso Gemini", CervelloPortatile.daUsare())
        CervelloPortatile.forzatoPerTest = false
        prova("a corrente uso il modello locale", !CervelloPortatile.daUsare())
        CervelloPortatile.forzatoPerTest = true

        // 2. la privacy: cosa parte davvero verso il cloud
        var locale = ""
        let mask = Gemini.daMandare("messaggi", "Ciao \(Identita.nome), il codice e' 3334567890", locale: &locale)
        prova("i messaggi non salgono sul cloud", !mask.contains("3334567890") && locale.contains("3334567890"), mask)
        var l2 = ""
        let percorso = Gemini.daMandare("esegui_comando", NSHomeDirectory() + "/Documents/prova.txt", locale: &l2)
        prova("i percorsi di casa restano mascherati", percorso.contains("~") && !percorso.contains(NSHomeDirectory()), percorso)

        // 2a2. le date dette a voce devono diventare date vere
        let cal = Calendar.current
        // riferimento: martedi 20 ottobre 2026, ore 13
        let adesso = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 13, minute: 0)) ?? Date()
        func data(_ testo: String, _ attesoGiorno: Int, _ attesoOra: Int) {
            guard let d = Agenda.dataItaliana(testo, adesso: adesso) else {
                print("  FAIL data \(testo) → nil"); batteriaBocciata = true; return
            }
            let c = cal.dateComponents([.day, .hour], from: d)
            let ok = c.day == attesoGiorno && c.hour == attesoOra
            print("  \(ok ? "ok  " : "FAIL") data «\(testo)» → \(c.day ?? 0)/10 alle \(c.hour ?? 0)")
            if !ok { batteriaBocciata = true }
        }
        data("domani", 21, 9)
        data("giovedi alle 16", 22, 16)
        data("sabato pomeriggio", 24, 15)
        data("stasera alle 8", 20, 20)
        data("20/10 alle 18:30", 20, 18)
        data("domani mattina", 21, 9)

        // 2b. la verita' sull'invio: "NON INVIATO" non deve mai diventare "inviato"
        Agent.esitoCanaleAttuale = "NON INVIATO: la chat aperta non e' quella giusta."
        Agent.esitoCanaleFallito = true
        prova("un fallimento non viene chiamato invio",
              Agent.verificaParoleInvio("Inviato!").contains("NON INVIATO"))
        prova("un invio vero non viene bloccato", {
            Agent.esitoCanaleFallito = false
            return Agent.verificaParoleInvio("Inviato: e' nell'archivio.") == "Inviato: e' nell'archivio."
        }())
        Agent.esitoCanaleFallito = false

        // 3. il giro vero: domanda, strumento locale, risposta utile
        let agente = Agent()
        var note: [String] = []
        var finale = ""
        let primaDelleChiamate = Brain.richieste
        finale = ""
        note = []
        await agente.ask("Che tempo fa adesso a Milano? Rispondi con la temperatura.",
                         source: "test-batteria",
                         onDelta: { _ in },
                         onNote: { note.append($0) },
                         onFinal: { finale = $0 })
        let risponde = finale.contains("non risponde") || finale.contains("HTTP") || finale.contains("non capisco")
        prova("risposta arrivata", !finale.isEmpty && !risponde, String(finale.prefix(110)))
        prova("lo strumento ha girato sul Mac", note.contains { $0.contains("→ meteo") }, note.joined(separator: " | "))
        let usatoLocale = Brain.richieste > primaDelleChiamate
        prova("il modello locale non e' stato invocato", !usatoLocale,
              usatoLocale ? "Gemini era saturo e \(Marca.nome) e' passato in locale (riserva che funziona)"
                          : "richieste a Ollama: \(Brain.richieste - primaDelleChiamate)")
        prova("la risposta ha un numero vero", finale.contains(where: { $0.isNumber }), String(finale.prefix(110)))

        // 4. si rimette a posto da solo
        CervelloPortatile.forzatoPerTest = nil
        print("== \(promossi) promossi, \(bocciati) bocciati ==")
        batteriaBocciata = bocciati > 0
    }

    private static func runSync(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "errore: \(error)" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static var fintaApp: [SchedaApp]?
    /// Quanti controlli sono falliti in questo giro. `--test` usciva SEMPRE con 0
    /// anche quando stampava FAIL (solo `--prova-guardia` e `--prova-watchdog`
    /// propagavano l'esito), quindi nessuna automazione poteva accorgersi di una
    /// regressione: la suite sembrava verde per costruzione.
    nonisolated(unsafe) static var fallimenti = 0

    /// Un controllo che dipende dall'ambiente (Ollama aperto, modello scaricato).
    /// Se manca non e' una regressione del codice: si dice, ma non fa fallire il
    /// giro — altrimenti l'exit code sarebbe 1 per sempre e non direbbe piu' niente.
    private static func avviso(_ what: String, _ ok: Bool, _ detail: String) {
        print("\(ok ? "  ok  " : " AVVISO") \(what)\n         \(detail)")
    }

    private static func report(_ what: String, _ ok: Bool, _ detail: String) {
        if !ok { fallimenti += 1 }
        print("\(ok ? "  ok  " : " FAIL ") \(what)\n         \(detail)")
    }
}
