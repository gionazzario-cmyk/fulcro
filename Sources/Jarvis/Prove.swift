import Foundation

/// La prova completa: chiama ogni strumento uno per uno, con input realistici e con
/// input assurdi (vuoti, unicode, percorsi inesistenti, date sbagliate, testi lunghissimi),
/// e dice quali rispondono bene. `Jarvis --prova-tutto` scrive anche il referto in
/// ~/.jarvis/logs/prove.txt cosi' si puo' rileggere senza rilanciare tutto.
///
/// Regole di sicurezza della suite: non stampa su carta (stampa prova=si), non manda
/// messaggi e non spedisce mail, non tocca niente fuori dalle cartelle di Jarvis.
enum Prove {
    struct Caso {
        let nome: String
        let strumento: String
        let args: [String: Any]
        let entro: Double
        /// True se la risposta e' accettabile. Riceve il testo grezzo dello strumento.
        let ok: (String) -> Bool
        /// Casi che aprono finestre: si saltano con --prova-tutto-quieto
        let rumoroso: Bool
        init(_ nome: String, _ strumento: String, _ args: [String: Any] = [:],
             entro: Double = 25, rumoroso: Bool = false, ok: @escaping (String) -> Bool) {
            self.nome = nome; self.strumento = strumento; self.args = args
            self.entro = entro; self.ok = ok; self.rumoroso = rumoroso
        }
    }

    static func casi() -> [Caso] {
        let si = "prova-tutto \(Int(Date().timeIntervalSince1970))"
        return [
            // MARK: memoria, cronologia, profilo
            Caso("cerca nella storia", "cerca_nella_storia", ["query": "interrogazione"],
                 ok: { !$0.isEmpty }),
            Caso("cerca nella storia senza query", "cerca_nella_storia", [:],
                 ok: { !$0.isEmpty }),
            Caso("leggi il profilo", "leggi_profilo", [:], ok: { $0.contains("\(Identita.nome)") }),
            Caso("aggiorna profilo con una cosa vera", "aggiorna_profilo", ["fatto": si],
                 ok: { $0.contains("memorizzato") || $0.contains("gia' scritto") }),
            Caso("aggiorna profilo vuoto", "aggiorna_profilo", ["fatto": "   "],
                 ok: { $0.lowercased().contains("nessun fatto") || $0.lowercased().contains("vuoto") }),

            // MARK: scuola
            Caso("orario di domani", "leggi_orario", [:], ok: { $0.contains("Materie") || $0.contains("Nessuna") }),
            Caso("orario di lunedi", "leggi_orario", ["giorno": "lunedi"], ok: { $0.contains("italiano") }),
            Caso("orario con un giorno inventato", "leggi_orario", ["giorno": "domenicadopo"],
                 ok: { $0.contains("Nessuna materia") || $0.contains("nessuna") }),
            Caso("compiti in lista", "compiti", ["azione": "lista"], ok: { !$0.isEmpty }),
            Caso("compiti: aggiunge e toglie", "compiti",
                 ["azione": "aggiungi", "materia": "test", "cosa": si, "scadenza": "domani"],
                 ok: { $0.contains("Aggiunto") }),
            Caso("compiti: cosa vuota", "compiti", ["azione": "aggiungi", "materia": "test", "cosa": ""],
                 ok: { $0.lowercased().contains("dimmi cosa") }),
            Caso("compiti: scadenza assurda", "compiti",
                 ["azione": "aggiungi", "materia": "x", "cosa": si + " assurda", "scadenza": "fra mille anni"],
                 ok: { $0.contains("Aggiunto") }),
            Caso("compiti: toglie quello che non c'e", "compiti", ["azione": "togli", "cosa": "zcxdvnoncè"],
                 ok: { $0.lowercased().contains("nessun compito") }),
            Caso("modalita studio: stato", "modalita_studio", ["azione": "stato"], ok: { !$0.isEmpty }),

            // MARK: mondo reale
            Caso("meteo a Milano", "meteo", ["citta": "Milano"],
                 ok: { $0.contains("°") || $0.contains("gradi") }),
            Caso("meteo citta vuota", "meteo", ["citta": ""], ok: { $0.contains("°") || $0.contains("gradi") }),
            Caso("meteo citta inventata", "meteo", ["citta": "Xyzzytownia"],
                 ok: { $0.lowercased().contains("non") || $0.lowercased().contains("errore") || $0.count > 4 }),
            Caso("f1 piloti", "f1", ["tipo": "piloti"],
                 ok: { $0.contains("LEADER:") && $0.contains("punti") }),
            Caso("f1 prossima gara", "f1", ["tipo": "prossima"], ok: { $0.count > 10 }),
            Caso("f1 austin", "f1", ["tipo": "austin"], ok: { $0.contains("Austin") || $0.contains("giorni") }),
            Caso("f1 anno vecchio", "f1", ["tipo": "piloti", "anno": "1994"], ok: { $0.count > 10 }),
            Caso("ricerca web", "cerca_web", ["cosa": "chi ha vinto il campionato f1 2025"],
                 ok: { $0.count > 20 }),
            Caso("ricerca web vuota", "cerca_web", ["cosa": ""], ok: { !$0.isEmpty }),
            Caso("notizie ANSA", "notizie", ["argomento": "sport"], ok: { $0.count > 20 }),
            Caso("leggi una pagina vera", "leggi_pagina", ["url": "https://example.com"],
                 ok: { $0.lowercased().contains("example") }),
            Caso("leggi una pagina inesistente", "leggi_pagina", ["url": "https://nonesiste-xyz-12345.it"],
                 ok: { $0.lowercased().contains("non") || $0.lowercased().contains("errore") }),
            Caso("leggi pagina senza url", "leggi_pagina", [:], ok: { !$0.isEmpty }),

            // MARK: Mac e file
            Caso("trova un file", "trova_file", ["testo": "f1_simulator"], ok: { $0.contains("f1") }),
            Caso("trova un file che non esiste", "trova_file", ["testo": UUID().uuidString],
                 ok: { let l = $0.lowercased(); return l.contains("nessun") || l.contains("non") }),
            Caso("comando di lettura", "esegui_comando", ["comando": "df -h /"], ok: { $0.contains("GiB") || $0.contains("disk") }),
            Caso("comando con sudo", "esegui_comando", ["comando": "sudo ls"], ok: { $0.contains("Non lo eseguo") }),
            Caso("comando vuoto", "esegui_comando", ["comando": ""], ok: { !$0.isEmpty }),
            Caso("scrittura permessa", "esegui_comando",
                 ["comando": "touch ~/.jarvis/tmp/\(si.replacingOccurrences(of: " ", with: "-")).txt"],
                 ok: { !$0.contains("Non lo eseguo") }),
            Caso("volume", "volume", ["azione": "leggi"], ok: { $0.contains("%") }),
            Caso("volume valore impossibile", "volume", ["azione": "metti", "valore": "999"],
                 ok: { $0.lowercased().contains("numero") || $0.lowercased().contains("tra 0") }),
            Caso("stampanti", "stampanti", [:], ok: { !$0.isEmpty }),
            Caso("stampa in simulazione", "stampa", ["testo": si, "prova": "si"],
                 ok: { $0.lowercased().contains("simul") || $0.lowercased().contains("prova") }),
            Caso("musica stato", "musica", ["azione": "stato"], ok: { !$0.isEmpty }),
            Caso("screenshot", "schermo", [:], ok: { $0.contains(".png") }),
            Caso("arduino: porte", "stato_arduino", [:], ok: { !$0.isEmpty }),
            Caso("raspberry: stato", "raspberry", ["azione": "stato"], entro: 40,
                 ok: { let l = $0.lowercased()
                     return l.contains("load average") || l.contains("carico") || l.contains("up ") || l.contains("non") }),
            Caso("raspberry: azione inventata", "raspberry", ["azione": "balla"], ok: { !$0.isEmpty }),

            // MARK: generare roba
            Caso("stl scatola", "genera_stl", ["forma": "scatola", "larghezza": "70", "profondita": "50",
                                               "altezza": "25", "spessore": "2", "cava": "si"],
                 ok: { $0.contains(".stl") }),
            Caso("stl misure assurde", "genera_stl", ["forma": "scatola", "larghezza": "-40", "profondita": "ciao"],
                 ok: { !$0.contains("crash") }),
            Caso("stl forma inesistente", "genera_stl", ["forma": "piramide"], ok: { !$0.isEmpty }),

            // MARK: voce e permessi
            Caso("voce: stato", "voce", ["azione": "stato"], ok: { $0.contains("Voce attuale") || $0.contains("voce") }),
            Caso("voce: cambia riccardo", "voce", ["azione": "cambia", "nome": "riccardo"],
                 ok: { $0.contains("cambiata") || $0.contains("Voce") }),
            Caso("voce: cambia una voce che non c'e", "voce", ["azione": "cambia", "nome": "zucchina"],
                 ok: { $0.contains("Non conosco") }),
            Caso("permessi: stato", "permessi", ["azione": "stato"], ok: { $0.contains("schermo") }),
            Caso("sistema: processi", "sistema", ["azione": "processi"], ok: { $0.count > 20 }),
            Caso("sistema: perche' si e' piantato", "sistema", ["azione": "perche_piantato"], entro: 40,
                 ok: { !$0.isEmpty }),
            Caso("sistema: log", "sistema", ["azione": "log", "cosa": "\(Marca.nome)"], entro: 60, ok: { !$0.isEmpty }),
            Caso("sistema: azione inventata", "sistema", ["azione": "teletrasporto"],
                 ok: { $0.contains("Azioni") }),

            // MARK: cervello a batteria (legge IOKit, scrive ~/.jarvis/batteria.txt)
            // MARK: le sue cose (link e numeri salvati)
            Caso("cose: salva un link", "cose", ["azione": "salva", "etichetta": "prova automatismo",
                                                 "valore": "https://example.com/prova"],
                 ok: { $0.contains("Ricordato") || $0.contains("gia") }),
            Caso("cose: ritrova", "cose", ["azione": "ritrova", "etichetta": "prova automatismo"],
                 ok: { $0.contains("example.com") }),
            Caso("cose: lista", "cose", ["azione": "lista"], ok: { $0.contains("prova automatismo") }),
            Caso("cose: etichetta che non c'e", "cose", ["azione": "ritrova", "etichetta": "zmxxk"],
                 ok: { $0.contains("Non ho niente") }),
            Caso("cose: togli", "cose", ["azione": "togli", "etichetta": "prova automatismo"],
                 ok: { $0.contains("Tolta") }),
            Caso("cose: azione inventata", "cose", ["azione": "iplaser"], ok: { $0.contains("Azioni") }),
            Caso("riunione: stato", "riunione", ["azione": "stato"], ok: { $0.lowercased().contains("riunioni") }),
            Caso("riunione: nota vuota", "riunione", ["azione": "nota", "testo": ""], ok: { $0.contains("Dimmi") }),
            Caso("riunione: azione inventata", "riunione", ["azione": "iplaser"], ok: { $0.contains("Azioni") }),
            Caso("leggi_file: file che non c'e", "leggi_file", ["percorso": "~/non-esiste-zx.txt"], ok: { $0.contains("Non esiste") }),
            Caso("scrivi_file: vuoto", "scrivi_file", ["percorso": "", "contenuto": ""], ok: { $0.contains("Dimmi") }),
            Caso("scrivi_file: cartella vietata", "scrivi_file",
                 ["percorso": "~/Desktop/matteo/prova.txt", "contenuto": "x"], ok: { $0.uppercased().contains("FUORI DALLA PORTATA") || $0.contains("non si toccano") }),
            Caso("scrivi_file: sistema vietato", "scrivi_file",
                 ["percorso": "/usr/bin/prova.sh", "contenuto": "x"], ok: { $0.lowercased().contains("non si toccano") || $0.lowercased().contains("fuori") }),
            Caso("scrivi_file: prova vera ed esecuzione", "scrivi_file",
                 ["percorso": "~/.jarvis/tmp/prova-multipli.py",
                  "contenuto": "for i in range(1, 6):\n    print(i * 7)\n", "esegui": "si"],
                 ok: { $0.contains("7") && $0.contains("35") }),
            Caso("leggi_file: legge quella prova", "leggi_file", ["percorso": "~/.jarvis/tmp/prova-multipli.py"],
                 ok: { $0.contains("print") }),
            Caso("agenda: stato", "agenda", ["azione": "stato"], ok: { $0.contains("Calendario") }),
            Caso("contatti: stato", "contatti", ["azione": "stato"], ok: { $0.contains("Contatti") }),

            // MARK: stampante 3D (solo la configurazione: niente rete nei test)
            Caso("bambu: cosa manca nella config", "bambu", ["azione": "config"],
                 ok: { $0.contains("bambu.conf") || $0.contains("completa") }),
            Caso("bambu: azione inventata", "bambu", ["azione": "iplaser"], ok: { $0.contains("Azioni") }),
            // Con la stampante spenta NON deve mai venire "la stampante non risponde":
            // qui e' il Mac che non la trova, e la differenza per l'utente e' tutto.
            Caso("bambu: stato reale o diagnosi, mai una bugia", "bambu", ["azione": "stato"],
                 ok: { !$0.contains("whisper") && !$0.lowercased().contains("non ha risposto")
                     && !$0.contains("NON COLLEGATO") }),
            Caso("bambu: cerca in rete", "bambu", ["azione": "cerca"],
                 ok: { $0.contains("8883") || $0.contains("stampante") || $0.contains("Bambu")
                     || $0.contains("ugello") || $0.contains("°C") }),

            // MARK: inventario app (legge solo i bundle: niente finestre, niente rete)
            // gli appunti si provano solo sulla forma: il contenuto della sua
            // clipboard non deve finire nel referto
            Caso("appunti: azione inventata", "appunti", ["azione": "riscrivi"],
                 ok: { $0.contains("Azioni") || $0.contains("credenziale") }),
            Caso("app: stato dell'inventario", "app", ["azione": "stato"],
                 ok: { $0.contains("app") && $0.contains("inventario") }),
            Caso("app: scheda di un'app vera", "app", ["azione": "scheda", "nome": "blender"],
                 ok: { $0.contains("Blender") && $0.contains("cosa posso fare") }),
            Caso("app: nome inventato non spara errori", "app", ["azione": "scheda", "nome": "xyzzy-non-c'e"],
                 ok: { $0.contains("Non ho nell'inventario") }),
            Caso("app: apri una app che non c'e'", "app", ["azione": "apri", "nome": "fantasma"],
                 ok: { $0.contains("Non la trovo") }),
            Caso("app: filtro a vuoto", "app", ["azione": "lista", "testo": "zzzzz"],
                 ok: { $0.lowercased().contains("nessun") }),
            Caso("app: azione inventata", "app", ["azione": "ripara"], ok: { $0.contains("Azioni") }),
            Caso("app: ricontare le app trova le differenze", "app", ["azione": "aggiorna"],
                 ok: { $0.contains("Inventario aggiornato") && $0.contains("app") }),
            Caso("app: due con lo stesso nome non le indovina", "app",
                 ["azione": "scheda", "nome": "ChatGPT Classic"],
                 ok: { $0.contains("quale delle due") && $0.contains("com.openai") }),
            Caso("app: con l'id del bundle non c'e' dubbio", "app",
                 ["azione": "scheda", "nome": "com.openai.chat"],
                 ok: { $0.contains("OpenAI") || ($0.contains("ChatGPT") && !$0.contains("quale delle due")) }),
            Caso("app: la nota per un'app si salva", "app",
                 ["azione": "nota", "nome": "prova-tutto", "testo_nota": "la finestra si apre con ⌘1"],
                 ok: { $0.contains("Segnato") }),
            Caso("app: la nota si rilegge (non la scrive due volte)", "app",
                 ["azione": "nota", "nome": "prova-tutto", "testo_nota": "la finestra si apre con ⌘1"],
                 ok: { $0.lowercased().contains("già scritto") || $0.contains("Già") }),

            // MARK: Anagrafica (stato passivo: niente finestra di permesso nei test)
            Caso("contatti: stato", "contatti", ["azione": "stato"],
                 ok: { $0.contains("Contatti") }),
            Caso("contatti: azione inventata", "contatti", ["azione": "iplaser"],
                 ok: { $0.contains("Azioni") }),
            Caso("cervello: stato", "cervello", ["azione": "stato"],
                 ok: { $0.contains("Alimentazione") && $0.contains("Scelta") }),
            Caso("cervello: passa al locale", "cervello", ["azione": "locale"],
                 ok: { $0.lowercased().contains("locale") }),
            Caso("cervello: rimette gemini", "cervello", ["azione": "gemini"],
                 ok: { $0.contains("Gemini") }),
            Caso("cervello: azione inventata", "cervello", ["azione": "iplaser"],
                 ok: { $0.contains("Azioni") }),

            // MARK: messaggi (sola lettura: mai inviare)
            Caso("messaggi: ultimi", "messaggi", ["azione": "ultimi"], ok: { !$0.isEmpty }),
            Caso("messaggi: non letti", "messaggi", ["azione": "non_letti"], ok: { !$0.isEmpty }),
            Caso("orecchio: stato", "orecchio", ["azione": "stato"], ok: { $0.contains("Orecchio") }),
            Caso("mail: non lette", "mail", ["azione": "non_lette"], ok: { !$0.isEmpty }),

            // MARK: mail: login a codice (non serve la password dell'utente)
            Caso("mail: stato del login", "mail", ["azione": "stato_login"],
                 ok: { $0.lowercased().contains("collegato") }),
            Caso("mail: chiede il codice a Microsoft", "mail", ["azione": "accedi"], entro: 35,
                 ok: { $0.contains("VAI SU") || $0.lowercased().contains("non mi da un codice") }),
            Caso("mail: login senza una richiesta aperta", "mail", ["azione": "login_fatto"],
                 ok: { let l = $0.lowercased(); return l.contains("nessuna richiesta") || l.contains("gia' collegato") || l.contains("aspetto") }),

            // MARK: roba improbabile che pero' capita
            Caso("strumento che non esiste", "fammi_il_caffe", [:], ok: { $0.contains("Non conosco") }),
            Caso("testo lunghissimo nel profilo", "aggiorna_profilo", ["fatto": String(repeating: "parola ", count: 400)],
                 ok: { !$0.isEmpty }),
            Caso("unicode e emoji ovunque", "compiti",
                 ["azione": "aggiungi", "materia": "🇹 mate", "cosa": "esercizi <&|> ' \" \\ \(si)", "scadenza": "2026-13-45"],
                 ok: { !$0.isEmpty }),
            Caso("path con spazi", "apri_percorso", ["percorso": "/non c'è niente qui"], ok: { !$0.isEmpty }),
            Caso("url non http", "apri_url", ["url": "javascript:alert(1)"],
                 ok: { $0.lowercased().contains("http") || $0.lowercased().contains("non") })
        ]
    }

    // MARK: - prove di comprensione (frasi vere → strumento giusto)

    /// Una frase che l'utente direbbe davvero, e lo strumento che deve chiamare.
    struct Frase {
        let testo: String
        let strumento: String      // "" = nessuna chiamata attesa
        let deveDire: [String]     // pezzetti che devono comparire nella risposta
        /// Altre strade ugualmente giuste: `sistema azione=spazio` e `df -h` dicono la
        /// stessa cosa, e il test non deve penalizzare quella migliore.
        let oppure: [String]
        init(testo: String, strumento: String, deveDire: [String], oppure: [String] = []) {
            self.testo = testo; self.strumento = strumento; self.deveDire = deveDire; self.oppure = oppure
        }
    }

    static func frasi() -> [Frase] {
        [
            Frase(testo: "quanti giga liberi ho?", strumento: "sistema", deveDire: [], oppure: ["esegui_comando"]),
            Frase(testo: "chi sta vincendo il mondiale piloti?", strumento: "f1", deveDire: ["punti"]),
            Frase(testo: "quanto manca al GP di Austin?", strumento: "f1", deveDire: []),
            Frase(testo: "che tempo fa?", strumento: "meteo", deveDire: []),
            Frase(testo: "che materie ho domani?", strumento: "leggi_orario", deveDire: []),
            Frase(testo: "che compiti ho da fare?", strumento: "compiti", deveDire: []),
            Frase(testo: "dimmi i compiti perche' devo studiare", strumento: "compiti", deveDire: []),
            Frase(testo: "come sta il raspberry?", strumento: "raspberry", deveDire: []),
            Frase(testo: "alza il volume a 40", strumento: "volume", deveDire: []),
            Frase(testo: "che stampanti ho?", strumento: "stampanti", deveDire: []),
            Frase(testo: "guarda cosa c'e' sullo schermo", strumento: "leggi_schermo", deveDire: []),
            Frase(testo: "cercami il file della simulazione f1", strumento: "trova_file", deveDire: []),
            // l'integrazione di una app nuova: preso il 2026-10-22 perche' senza indizio il
            // modello rispondeva con il ponte di Wheatstone (il circuito) invece di chiamare
            // lo strumento delle app
            Frase(testo: "fai il ponte di Keka", strumento: "apri_app", deveDire: []),
            Frase(testo: "ho messaggi?", strumento: "messaggi", deveDire: []),
            Frase(testo: "accendi l'orecchio dei messaggi", strumento: "orecchio", deveDire: []),
            Frase(testo: "metti la voce da uomo", strumento: "voce", deveDire: []),
            Frase(testo: "perche' il mac si e' piantato stasera?", strumento: "sistema", deveDire: []),
            Frase(testo: "dimmi un po' di notizie di sport", strumento: "notizie", deveDire: []),
            Frase(testo: "fammi una scatola 60x40x30 per i cavi", strumento: "genera_stl", deveDire: []),
            Frase(testo: "ricordati che il mio gatto si chiama test", strumento: "nessuno", deveDire: ["Segnato"]),
            Frase(testo: "la giornata", strumento: "", deveDire: []),
            Frase(testo: "apri il terminale", strumento: "apri_app", deveDire: [], oppure: ["esegui_comando"]),
            Frase(testo: "che app ho per montare dei video?", strumento: "apri_app", deveDire: [], oppure: ["app"]),
            Frase(testo: "cosa puoi fare con blender?", strumento: "apri_app", deveDire: [], oppure: ["app", "nessuno"]),
            Frase(testo: "spiegami quello che ho copiato", strumento: "appunti", deveDire: [], oppure: ["spiegami"]),
            Frase(testo: "cercami su internet quando esce l'iphone nuovo", strumento: "cerca_web", deveDire: []),
            // cose improbabili: non deve inventare e non deve tirarsi indietro
            Frase(testo: "dimmi che ora e' a tokio", strumento: "", deveDire: []),
            Frase(testo: "quante persone vivono sulla luna", strumento: "", deveDire: []),
            Frase(testo: "mandami una foto del sole dallo spazio", strumento: "", deveDire: [])
        ]
    }

    /// Gira le frasi sull'agent vero e guarda cosa chiama.
    @MainActor static func comprensione() async -> String {
        setbuf(stdout, nil)
        AppPaths.prepare()
        Tools.confirm = { _ in false }
        var promossi = 0, bocciati = 0
        var referto: [String] = []
        print("== PROVA DI COMPRENSIONE — \(frasi().count) frasi ==\n")
        for frase in frasi() {
            let agent = Agent()
            final class R { var chiamate: [String] = []; var testo = "" }
            let r = R()
            let t0 = Date()
            await agent.ask(frase.testo, source: "debug",
                            onDelta: { _ in },
                            onNote: { riga in if riga.hasPrefix("→ ") { r.chiamate.append(String(riga.dropFirst(2).split(separator: " ")[0])) } },
                            onFinal: { r.testo = $0 })
            let secondi = String(format: "%.1fs", Date().timeIntervalSince(t0))
            var motivo = ""
            let alternativaOk = r.chiamate.contains(where: { frase.oppure.contains($0) })
            if !frase.strumento.isEmpty && frase.strumento != "nessuno"
                && !r.chiamate.contains(frase.strumento) && !alternativaOk {
                motivo = "non ha chiamato \(frase.strumento) (ha chiamato: \(r.chiamate.isEmpty ? "niente" : r.chiamate.joined(separator: ",")))"
            }
            if frase.strumento == "nessuno" && !r.chiamate.isEmpty {
                motivo = "non doveva chiamare niente, ha chiamato \(r.chiamate.joined(separator: ","))"
            }
            // se uno strumento ha lavorato e ha riportato un fallimento vero,
            // non e' un "mi sono tirato indietro": e' l'onesta' che gli abbiamo chiesto
            // (e lo stesso vale per «la giornata»: quella non la scrive il modello, e' il
            // briefing deterministico di `Giornata` che incolla risposte di strumenti — e
            // dentro una di quelle c'e' quasi sempre un "assicurati che sia connesso",
            // che il cancello anti-resa leggeva come una resa: falso allarme, preso il
            // 2026-10-22 alle 23:15)
            if r.chiamate.isEmpty, !Giornata.innesco(frase.testo), Agent.suonaRinuncia(r.testo) {
                motivo += " si e' tirato indietro senza provare"
            }
            for pezzo in frase.deveDire where !r.testo.contains(pezzo) {
                motivo += " mancava «\(pezzo)»"
            }
            let promosso = motivo.isEmpty
            if promosso { promossi += 1 } else { bocciati += 1 }
            print("  \(promosso ? "ok  " : "FAIL") «\(frase.testo)» → \(r.chiamate.isEmpty ? "-" : r.chiamate.joined(separator: ",")) (\(secondi)) \(promosso ? "" : "| " + motivo)")
            referto.append("\(promosso ? "ok" : "FAIL") | \(frase.testo) | \(r.chiamate.joined(separator: ",")) | \(motivo)")
        }
        // "ricordati che il mio gatto si chiama test" scrive DAVVERO nel profilo:
        // senza questa pulizia la sua memoria resta sporca di prove a ogni suite
        Memory.rimuovi("Il mio gatto si chiama test")
        _ = Memory.pulisciSpazzatura()

        let riepilogo = "\n== \(promossi) frasi capite, \(bocciati) no ==\n"
        print(riepilogo)
        try? referto.joined(separator: "\n").write(to: AppPaths.jarvisRoot.appendingPathComponent("logs/prove-frasi.txt"),
                                                  atomically: true, encoding: .utf8)
        return riepilogo
    }

    /// Esegue tutto e ritorna il referto.
    @MainActor static func tutto() async -> String {
        setbuf(stdout, nil)
        AppPaths.prepare()
        Tools.confirm = { _ in false }        // niente clic: cio' che chiede conferma risulta "no"
        let quieto = CommandLine.arguments.contains("--prova-tutto-quieto")
        var righe: [String] = []
        var promossi = 0, bocciati = 0, saltati = 0
        print("== PROVA COMPLETA DI \(Marca.nome) — \(casi().count) casi ==\n")
        for caso in casi() {
            if caso.rumoroso && quieto {
                saltati += 1
                print("  --   \(caso.nome) (saltato: apre finestre)")
                continue
            }
            let t0 = Date()
            let risposta = await conLimite(caso.strumento, caso.args, max(caso.entro, 30))
            // un respiro: senza questo, i casi pesanti si mangiavano il tempo a vicenda
            try? await Task.sleep(nanoseconds: 120_000_000)
            let secondi = String(format: "%.1fs", Date().timeIntervalSince(t0))
            let promosso = !risposta.hasPrefix("⏱") && caso.ok(risposta)
            if promosso { promossi += 1 } else { bocciati += 1 }
            print("  \(promosso ? "ok  " : "FAIL") \(caso.nome) [\(caso.strumento)] (\(secondi)) — \(String(risposta.prefix(110)).replacingOccurrences(of: "\n", with: " "))")
            righe.append("\(promosso ? "ok" : "FAIL") | \(caso.nome) | \(caso.strumento) | \(secondi) | \(String(risposta.prefix(300)).replacingOccurrences(of: "\n", with: " ")))")
        }
        // pulizia: niente resti della suite in giro
        pulisci(prova: "prova-tutto")
        let riepilogo = "\n== \(promossi) promossi, \(bocciati) da sistemare, \(saltati) saltati ==\n"
        print(riepilogo)
        let referto = righe.joined(separator: "\n") + riepilogo
        try? referto.write(to: AppPaths.jarvisRoot.appendingPathComponent("logs/prove.txt"),
                          atomically: true, encoding: .utf8)
        return referto
    }

    /// Chiama lo strumento con un tempo limite: uno strumento che si impalla e' un bug
    /// tanto quanto uno che risponde male.
    private static func conLimite(_ strumento: String, _ args: [String: Any], _ secondi: Double) async -> String {
        await withTaskGroup(of: String.self) { gruppo in
            gruppo.addTask { await Tools.shared.run(strumento, args) }
            gruppo.addTask {
                try? await Task.sleep(nanoseconds: UInt64(secondi * 1_000_000_000))
                return "⏱ oltre \(Int(secondi))s"
            }
            let primo = await gruppo.next() ?? ""
            gruppo.cancelAll()
            return primo
        }
    }

    /// Toglie le righe di prova dal profilo e i compiti di prova dalla lista.
    private static func pulisci(prova: String) {
        Memory.rimuovi(prova)
        _ = Memory.pulisciSpazzatura()
        var tutti = Compiti.leggi(tutti: true)
        while let i = tutti.firstIndex(where: { $0.cosa.contains(prova) }) {
            tutti.remove(at: i)
        }
        _ = Compiti.salva(tutti)
        // le note per app scritte dai test non devono restare in giro
        if let file = try? FileManager.default.contentsOfDirectory(
            at: InventarioApp.schede, includingPropertiesForKeys: nil) {
            for f in file where f.lastPathComponent.contains(prova) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
