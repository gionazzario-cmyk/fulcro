import Foundation
import AppKit

/// Le "mani" di Jarvis: funzioni che il modello locale puo chiamare.
/// Tutte girano sul Mac; le uniche uscite di rete sono letture (F1, meteo).
final class Tools: @unchecked Sendable {
    static let shared = Tools()

    /// interruttore di collaudo per `definitions`
    static var nienteStrumentoApp: Bool {
        ProcessInfo.processInfo.environment["JARVIS_NO_APP_TOOL"] != nil
    }
    private init() {}

    /// Installata da JarvisCore all'avvio: chiede il clic all'utente e dice si/no.
    static var confirm: ((String) async -> Bool)?

    /// Con JARVIS_NO_APP_TOOL=1 lo strumento `app` sparisce dalla lista. Messa il
    /// 2026-10-20 per il `--prova-frasi`: con `app` dentro, il modello chiamava `app`
    /// per "che stampanti ho?" e per "cercami il file della simulazione f1".
    var definitions: [[String: Any]] {
        [
            tool("cerca_nella_storia", "Cerca nel log di cosa \(Identita.nome) ha detto prima.", ["query": str("parole")], required: ["query"]),
            tool("apri_app", "Tutte le app del Mac (inventario letto dai bundle, vale anche per quelle installate domani): aprirle, chiuderle, metterle davanti, dire cosa \(Marca.nome) ci puo' fare (scheda, schemi URL, se si pilota, che file apre, le piu' usate). Con `integra` costruisce l'integrazione di una app (la scheda — il «ponte» — che dice come si pilota davvero, con i suoi verbi); `integrazioni` elenca quelle fatte. Le app si aprono IN BACKGROUND: niente sullo schermo, solo il resoconto; quelle aperte per un lavoro suo le chiude da sole alla fine.", ["azione": list(["apri", "chiudi", "davanti", "scheda", "lista", "stato", "vai", "recenti", "intel", "visibilita", "ripulisci", "aggiorna", "integra", "ponti"], "cosa fare (vuoto = apri)"), "nome": str("nome dell'app, anche sbagliato"), "testo": str("per lista: parola nel nome; per visibilita: visibile o invisibile"), "dentro": str("per vai: punto dentro l'app")], required: []),
            tool("trova_file", "Trova file per nome o contenuto. Per elencare una cartella usa esegui_comando con ls.", ["testo": str("nome o parte")], required: ["testo"]),
            tool("apri_percorso", "Apre un file o cartella a un path.", ["percorso": str("path assoluto")], required: ["percorso"]),
            tool("apri_url", "Apre un indirizzo nel browser.", ["url": str("http/https")], required: ["url"]),
            tool("f1", "Dati F1 veri: classifica, prossima gara, calendario, e quanto manca ad Austin.", ["tipo": list(["piloti", "costruttori", "prossima", "calendario", "austin"], "cosa"), "anno": str("anno o vuoto")], required: ["tipo"]),
            tool("meteo", "Meteo reale per una citta.", ["citta": str("nome citta")], required: ["citta"]),
            tool("volume", "Volume del Mac.", ["azione": list(["leggi", "su", "giu", "metti", "muto", "parlato"], "cosa fare"), "valore": str("0-100 solo per metti")], required: ["azione"]),
            tool("musica", "Controlla Spotify o Musica.", ["azione": list(["stato", "playpausa", "avanti", "indietro"], "cosa fare")], required: ["azione"]),
            tool("stampanti", "Elenca le stampanti CUPS."),
            tool("stampa", "Stampa testo o file. Chiedi il permesso a \(Identita.nome) prima.", ["testo": str("testo"), "percorso": str("file"), "stampante": str("vuoto=default"), "copie": str("numero"), "prova": str("si=simula")]),
            tool("cerca_web", "Cerca su internet: torna titoli, link e stralci. Internet c'e'.", ["cosa": str("testo ricerca")], required: ["cosa"]),
            tool("leggi_pagina", "Riporta il testo vero di una pagina web.", ["url": str("http/https")], required: ["url"]),
            tool("notizie", "Notizie ANSA dal feed RSS.", ["argomento": list(["prima pagina", "cronaca", "tecnologia", "sport", "mondo", "economia"], "sezione")], required: ["argomento"]),
            tool("youtube", "Cerca su YouTube e APRE il video.", ["cosa": str("cosa cercare"), "azione": list(["metti", "apri_ricerca"], "metti=apre il video")], required: ["cosa"]),
            tool("raspberry", "Diagnostica vera del Raspberry Pi via SSH.", ["azione": list(["stato", "processi", "f1", "rete"], "cosa controllare")], required: ["azione"]),
            tool("leggi_schermo", "Guarda cosa c'e' adesso sullo schermo col modello visivo.", ["domanda": str("cosa vuoi sapere")], required: ["domanda"]),
            tool("schermo", "Screenshot silenzioso, torna il path del file."),
            tool("genera_stl", "Crea un STL parametrico per la Bambu: scatola o cilindro. Tre numeri dati da \(Identita.nome) = larghezza, profondita, altezza in quest'ordine. Una scatola/contenitore/cassetto si intende APERTA sopra (cava=si) a meno che lui non dica chiusa.", ["forma": list(["scatola", "cilindro", "cono", "sfera", "prisma"], "forma"), "larghezza": str("mm X (scatola)"), "profondita": str("mm Y (scatola)"), "diametro": str("mm (cilindro, cono, sfera, prisma)"), "diametro2": str("mm in cima al cono, 0 = punta"), "lati": str("lati del prisma, default 6"), "altezza": str("mm Z"), "spessore": str("mm parete, vuoto=2"), "cava": list(["si", "no"], "scatola aperta sopra (default si)"), "tubo": list(["si", "no"], "cilindro scavato"), "apri": list(["si", "no"], "apri in Bambu Studio")], required: ["forma"]),
            tool("esegui_comando", "Esegui TU un comando zsh sul Mac. Lettura subito, il resto con conferma da sola. Non dire all'utente cosa digitare.", ["comando": str("comando esatto, es. df -h oppure ls -la /percorso"), "motivo": str("perche")], required: ["comando"]),
            tool("stato_arduino", "Elenca le seriali USB collegate."),
            tool("invia_ad_arduino", "Manda una riga all'Arduino in USB e legge la risposta.", ["comando": str("testo"), "porta": str("vuoto=l'unica trovata"), "baud": str("di solito 9600")], required: ["comando"]),
            tool("aggiorna_profilo", "Salva un fatto o preferenza persistente su \(Identita.nome) in ~/.jarvis/profilo.md.", ["fatto": str("fatto o preferenza da ricordare")], required: ["fatto"]),
            tool("leggi_profilo", "Rilegge il profilo persistente di \(Identita.nome) con tutte le sue abitudini e preferenze."),
            tool("leggi_orario", "Legge le materie scolastiche per domani o per un giorno dato.", ["giorno": str("vuoto=domani, oppure lunedi, martedi, ecc.")]),
            tool("compiti", "I compiti di \(Identita.nome) in ~/.jarvis/compiti.md: cosa deve fare, entro quando, su che pagina.", ["azione": list(["lista", "aggiungi", "fatto", "togli"], "cosa fare"), "materia": str("materia"), "cosa": str("cosa deve fare"), "scadenza": str("oggi, domani, 20-11 o 2026-11-20; vuoto=nessuna"), "pagina": str("link, file o app dove si fa")], required: ["azione"]),
            tool("modalita_studio", "Il controllo sui compiti: se \(Identita.nome) passa piu' di 40 secondi su un'app di distrazione, \(Marca.nome) glielo dice e riapre la pagina dei compiti.", ["azione": list(["accendi", "spegni", "stato", "riapri_pagina"], "cosa fare"), "pagina": str("url/percorso/app; vuoto=presa dalla lista compiti"), "minuti": str("durata in minuti, vuoto=90")], required: ["azione"]),
            tool("voce", "Accende, spegne o cambia la voce di \(Marca.nome) (non il volume del Mac).", ["azione": list(["accendi", "spegni", "stato", "cambia"], "cosa fare"), "nome": str("serena o riccardo, solo con cambia")], required: ["azione"]),
            tool("messaggi", "iMessage/SMS di \(Identita.nome). Con azione invia compila SEMPRE anche 'a' e 'testo': il testo lo scrivi tu nel tono di \(Identita.nome) partendo dal concetto che lui ti ha dato, mai lasciarlo vuoto.", ["azione": list(["ultimi", "non_letti", "apri", "invia"], "cosa fare"), "a": str("numero o nome del destinatario - obbligatorio con invia"), "testo": str("il messaggio da mandare, scritto da te: mai vuoto"), "numero": str("quanti, vuoto=10")], required: ["azione"]),
            tool("mail", "Posta via Microsoft Outlook (riserva Mail.app). Con azione scrivi compila SEMPRE 'a', 'oggetto' e 'testo': il corpo lo scrivi tu nel tono di \(Identita.nome), mai lasciarlo vuoto.", ["azione": list(["non_lette", "riassumi", "corpo", "scrivi"], "cosa fare"), "a": str("indirizzo del destinatario"), "oggetto": str("oggetto mail"), "testo": str("il corpo, scritto da te: mai vuoto"), "invia": list(["si", "no"], "no=lascio la bozza aperta"), "quale": str("quale non letta aprire, 1=prima")], required: ["azione"]),
            tool("whatsapp", "WhatsApp: apre la chat col testo pronto e, se puo, preme invio. Per leggere si guarda lo schermo.", ["azione": list(["manda", "apri", "leggi"], "cosa fare"), "numero": str("+39... o nome"), "testo": str("da scrivere"), "domanda": str("cosa leggere a schermo")], required: ["azione"]),
            tool("orecchio", "Avvisa da solo quando arrivano messaggi o mail.", ["azione": list(["accendi", "spegni", "stato"], "cosa fare")], required: ["azione"]),
            tool("confronta", "Le due intelligenzi lavorano insieme: qwen3 risponde, Gemini Flash revisiona, qwen3 scrive la versione finale.", ["domanda": str("cosa chiedere"), "materia": str("materia, vuota=nessuna")], required: ["domanda"]),
            tool("fucina", "\(Marca.nome) modifica il proprio codice: prova, compila, e solo con il clic di \(Identita.nome) applica. Gate.swift e gli script di firma non si possono toccare.", ["azione": list(["stato", "leggi", "prova", "applica", "ripristina"], "cosa fare"), "file": str("percorso relativo nel progetto"), "testo_nuovo": str("contenuto intero del file, se riscrivi tutto"), "trova": str("pezzo di codice da sostituire (meglio di testo_nuovo)"), "sostituisci": str("il pezzo nuovo"), "motivo": str("perche'")], required: ["azione"]),
            tool("spiegami", "Secondo cervello: spiega un argomento di studio. Prova in locale e, se la chiave c'e', usa Gemini Flash.", ["domanda": str("cosa devi spiegare"), "materia": str("materia, vuota=nessuna")], required: ["domanda"]),
            tool("gemini", "Stato del secondo cervello e prova della chiave.", ["azione": list(["stato", "apri_file", "prova"], "cosa fare")], required: ["azione"]),
            tool("conversazione", "Prende in mano lui una chat: legge quello che ha scritto la persona, risponde col tono di \(Identita.nome), aspetta la replica e continua da solo. Da usare quando \(Identita.nome) dice 'rispondi tu' o 'pensaci tu'.", ["azione": list(["prendi"], "cosa fare"), "a": str("nome o numero della persona"), "scopo": str("cosa vuoi ottenere, vuoto: rispondere in modo naturale"), "giri": str("quanti scambi, vuoto=3")], required: ["azione", "a"]),
            tool("riunione", "Assistente per le riunioni (Meet/Zoom/Teams): guarda lo schermo, prende appunti e li scrive in chat SENZA mai parlare. Con 'nota' scrive una cosa che gli dici tu.", ["azione": list(["accendi", "spegni", "stato", "nota", "riepilogo"], "cosa fare"), "testo": str("cosa annotare, con nota")], required: ["azione"]),
            tool("scrivi_file", "Scrivi un file vero (codice, script, testo) e, se vuoi, lo esegui subito. Usa questo per programmare: `fucina` serve SOLO a modificare il codice di \(Marca.nome).", ["percorso": str("path, anche con ~ all'inizio"), "contenuto": str("il testo del file"), "esegui": list(["si", "no"], "si = lo fai girare e torni l'output")], required: ["percorso", "contenuto"]),
            tool("leggi_file", "Leggi un file di testo (righe numerate).", ["percorso": str("path"), "righe": str("quante righe, vuoto=200")], required: ["percorso"]),
            tool("cose", "L'archivio delle cose di \(Identita.nome): link, numeri, indirizzi. Con 'salva' si mette una etichetta e il suo valore, con 'ritrova' torna il valore. Serve per 'mandami il link di quell'affare'.", ["azione": list(["salva", "ritrova", "lista", "togli"], "cosa fare"), "etichetta": str("come la chiama \(Identita.nome)"), "valore": str("link / numero / indirizzo")], required: ["azione"]),
            tool("agenda", "Il calendario vero di \(Identita.nome) (EventKit): impegni, e se e' libero in un giorno. Con 'libero' dice LIBERO o OCCUPATO con l'impegno che disturba.", ["azione": list(["stato", "oggi", "domani", "giorno", "libero", "prossimi", "aggiungi", "togli"], "cosa fare"), "quando": str("oggi, domani, sabato, domenica, 20/10, anche con l'ora: 'martedi alle 16'"), "cosa": str("titolo dell'impegno, con aggiungi e togli"), "minuti": str("durata in minuti, vuoto=60")], required: ["azione"]),
            tool("bambu", "La stampante 3D di \(Identita.nome) (Bambu A1 mini in rete): stato, temperatura, avanzamento, ETA, avviso a fine stampa. Con 'config' dice cosa manca nel file di configurazione; con 'cerca' ritrova il suo indirizzo in rete quando 'stato' non la trova (il router di casa glielo cambia).", ["azione": list(["stato", "cerca", "test", "watch", "config"], "cosa fare"), "minuti": str("per watch: per quanto tempo guardare, vuoto=90")], required: ["azione"]),
            tool("contatti", "Anagrafica del Mac: legge i contatti col nome e il numero, e ne salva di nuovi. Con 'salva' servono nome e numero.", ["azione": list(["stato", "lista", "cerca", "numero", "salva"], "cosa fare"), "nome": str("nome del contatto o parte di esso"), "numero": str("numero di telefono")], required: ["azione"]),
            tool("cervello", "Le due scelte a corrente staccata. DOVE RAGIONA: gemini (cervello sul cloud, sul Mac non pesa) o locale (tutto offline ma mangia batteria). QUANTO GIRA: dormi (zero sveglie, default), esci (l'app si chiude), lavora (continua a passo lento). 'stato' dice l'alimentatore e il passo attuale.", ["azione": list(["stato", "gemini", "locale", "dormi", "esci", "lavora"], "cosa fare")], required: ["azione"]),
            tool("sistema", "Diagnostica vera del Mac: perche' un'app si e' piantata, cosa mangia CPU/RAM, spazio, batteria, log recenti.", ["azione": list(["perche_piantato", "processi", "spazio", "batteria", "log"], "cosa controllare"), "cosa": str("nome dell'app o del problema, vuoto=tutto")], required: ["azione"]),
            tool("permessi", "Stato vero dei permessi macOS di \(Marca.nome) e pannelle da aprire.", ["azione": list(["stato", "apri_disco", "apri_accessibilita", "chiedi_accessibilita"], "cosa fare")], required: ["azione"]),
            tool("appunti", "Lavora su cio' che \(Identita.nome) ha copiato (Cmd+C): spiegamelo, traducilo, correggilo, o segnalo come compito. Di default il testo non esce dal Mac.", ["azione": list(["leggi", "spiega", "traduci", "correggi", "compito"], "cosa fare cogli appunti"), "nuvola": str("si' = solo se lui lo chiede: passa il testo a Gemini")], required: ["azione"]),
            tool("compiti_da_classeviva", "Legge i compiti dalla pagina di ClasseViva gia' aperta nel browser (nessuna password: usa la sessione di \(Identita.nome)) e li scrive nella lista compiti.", ["azione": list(["leggi", "ricorda_pagina", "stato"], "cosa fare"), "url": str("indirizzo, vuoto=pagina salvata")], required: ["azione"])
        ]
        // niente definizione = niente tentazione: l'interruttore e' qui sopra
        .filter { !(Self.nienteStrumentoApp && ($0["function"] as? [String: Any])?["name"] as? String == "app") }
    }

    /// L'elenco dei nomi, da buttare nel prompt quando il modello si tira indietro:
    /// cosi' non "scopre" di non poter fare una cosa che ha gia' in mano.
    var nomiStrumenti: String {
        definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
            .joined(separator: ", ")
    }

    private func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {        ["type": "function",
         "function": [
            "name": name,
            "description": desc,
            "parameters": ["type": "object", "properties": props, "required": required]
         ]]
    }
    private func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private func list(_ v: [String], _ d: String) -> [String: Any] { ["type": "string", "description": d, "enum": v] }

    func run(_ name: String, _ args: [String: Any]) async -> String {
        switch name {
        case "cerca_nella_storia": return searchLog(arg(args, "query"))
        case "apri_app": return await Tools.appSkill(args)
        case "trova_file": return findFile(arg(args, "testo"))
        case "apri_percorso": return await shell("/usr/bin/open", [arg(args, "percorso")])
        case "apri_url":
            let url = arg(args, "url")
            guard url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("file://") else {
                return "Posso aprire solo indirizzi http/https."
            }
            return await shell("/usr/bin/open", [url])
        case "f1": return await f1(tipo: arg(args, "tipo"), anno: arg(args, "anno"))
        case "meteo":
            // La città di default non è quella di chi ha scritto il codice: se
            // ~/.jarvis/citta.txt non c'è, lo dice e chiede dove abita.
            let richiesta = arg(args, "citta")
            if richiesta.isEmpty {
                if let casa = Identita.citta { return await meteo(citta: casa) }
                return "NON CONFIGURATO: non so in che città vivi. Dimmelo (es. \"meteo Milano\") e lo salvo in ~/.jarvis/citta.txt."
            }
            return await meteo(citta: richiesta)
        case "stato_arduino": return Tools.arduinoPorts()
        case "invia_ad_arduino": return await arduinoSend(args)
        case "volume": return await volume(args)
        case "musica": return await music(arg(args, "azione"))
        case "stampanti": return await printers()
        case "stampa": return await printJob(args)
        case "schermo": return await screenshot()
        case "cerca_web": return await cercaWeb(arg(args, "cosa"))
        case "leggi_pagina": return await leggiPagina(arg(args, "url"))
        case "notizie": return await notizie(arg(args, "argomento"))
        case "youtube": return await youtube(args)
        case "raspberry": return await raspberry(arg(args, "azione"))
        case "leggi_schermo": return await readScreen(arg(args, "domanda"))
        case "esegui_comando": return await runCommand(args)
        case "genera_stl": return await generaStl(args)
        case "aggiorna_profilo": return Memory.appendFact(arg(args, "fatto"))
        case "leggi_profilo": return Memory.readProfile()
        case "leggi_orario": return Memory.readSchedule(day: arg(args, "giorno"))
        case "compiti": return Tools.compitiSkill(args)
        case "modalita_studio": return await Tools.studioSkill(args)
        case "voce": return await Tools.voceSkill(arg(args, "azione"), nome: arg(args, "nome"))
        case "compiti_da_classeviva": return await Tools.classevivaSkill(args)
        case "messaggi": return await Tools.messaggiSkill(args)
        case "mail": return await Tools.mailSkill(args)
        case "whatsapp": return await Tools.whatsappSkill(args)
        case "orecchio": return await Tools.orecchioSkill(args)
        case "permessi": return Tools.permessiSkill(arg(args, "azione"))
        case "sistema": return await sistema(arg(args, "azione"), arg(args, "cosa"))
        case "spiegami": return await Tools.spiegamiSkill(args)
        case "confronta": return await Tools.dibattitoSkill(args)
        case "fucina": return await Tools.fucinaSkill(args)
        case "gemini": return await Tools.geminiSkill(arg(args, "azione"))
        case "cervello": return Tools.cervelloSkill(arg(args, "azione"))
        case "contatti": return await Tools.contattiSkill(args)
        case "appunti": return await Tools.appuntiSkill(args)
        case "bambu": return await Tools.bambuSkill(args)
        case "app": return await Tools.appSkill(args)
        case "cose": return Tools.coseSkill(args)
        case "scrivi_file": return await Tools.scriviFileSkill(args)
        case "riunione": return await Tools.riunioneSkill(args)
        case "conversazione": return await Tools.conversazioneSkill(args)
        case "leggi_file": return Tools.leggiFileSkill(args)
        case "agenda": GuardiaMessaggio.agendaControllata = true; return await Tools.agendaSkill(args)
        default: return "Non conosco l'azione \(name)."
        }
    }

    private func arg(_ args: [String: Any], _ key: String) -> String { (args[key] as? String) ?? "" }

    // MARK: - diagnostica del Mac

    /// Risponde a "perche' si e' piantato": i crash report veri, non la memoria.
    private func sistema(_ azione: String, _ cosa: String) async -> String {
        switch azione {
        case "perche_piantato":
            let cartella = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports")
            let fm = FileManager.default
            let file = ((try? fm.contentsOfDirectory(at: cartella, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "ips" || $0.pathExtension == "crash" || $0.pathExtension == "panic" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return da > db
                }
            let filtro = cosa.lowercased()
            let scelti = file.filter { filtro.isEmpty || $0.lastPathComponent.lowercased().contains(filtro) }
            var righe: [String] = []
            let f = DateFormatter()
            f.dateFormat = "dd/MM HH:mm"
            for url in scelti.prefix(6) {
                let quando = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                var motivo = ""
                // si legge solo l'inizio: i report .ips arrivano a centinaia di kB
                let testa = (try? String(data: Self.inizioFile(url, 6000), encoding: .utf8)) ?? ""
                if !testa.isEmpty {
                    // la prima riga dell'ips e' JSON con nome/eta'; la seconda ha il motivo del crash
                    if let r = testa.range(of: "\"exception\":") ?? testa.range(of: "\"termination\":") {
                        motivo = String(testa[r.lowerBound...].prefix(220)).replacingOccurrences(of: "\n", with: " ")
                    }
                }
                righe.append("\(f.string(from: quando)) · \(url.deletingPathExtension().lastPathComponent) \(motivo.prefix(180))")
            }
            if righe.isEmpty {
                // 2 ore di log volevano dire 40+ secondi: si guarda mezz'ora, con fretta
                let loghi = await shell("/usr/bin/log", ["show", "--last", "30m", "--style", "compact",
                                                         "--predicate", "process == \"ReportCrash\""],
                                        timeout: 18)
                return "Nessun crash report\(cosa.isEmpty ? "" : " per \(cosa)") negli ultimi tempi."
                    + (loghi.contains("error") ? "" : "\n\(String(loghi.prefix(700)))")
            }
            return "Ecco cosa e' andato in crash:\n" + righe.joined(separator: "\n")
        case "processi":
            // `ps -Arc 8` senza terminale esce con codice 1: questa e' la forma che
            // funziona anche lanciata da un'app in background
            let o = await shell("/bin/ps", ["-Ao", "pid,pcpu,pmem,comm", "-r"])
            let righe = o.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return righe.isEmpty ? "Non riesco a leggere i processi."
                                 : String(righe.prefix(10).joined(separator: "\n").prefix(900))
        case "spazio":
            let o = await shell("/bin/df", ["-h", "/"])
            return String(o.split(separator: "\n").suffix(2).joined(separator: "\n"))
        case "batteria":
            let o = await shell("/usr/bin/pmset", ["-g", "batt"])
            return String(o.prefix(400))
        case "log":
            let cerca = cosa.isEmpty ? "error" : cosa
            // `log show` e' lentissimo su finestre ampie: 10 minuti bastano e avanzano,
            // e sotto i 25 secondi se non risponde si molla (altrimenti Jarvis si blocca)
            let o = await shell("/usr/bin/log", ["show", "--last", "10m", "--style", "compact",
                                                 "--predicate", "eventMessage CONTAINS[c] \"\(cerca)\""],
                                timeout: 25)
            let righe = o.components(separatedBy: .newlines).filter { !$0.contains("Filtering") }
            return righe.isEmpty ? "Niente nei log degli ultimi 30 minuti su \(cerca)."
                                 : String(righe.suffix(14).joined(separator: "\n").prefix(1400))
        default:
            return "Azioni: perche_piantato, processi, spazio, batteria, log."
        }
    }

    // MARK: - storia

    private func searchLog(_ query: String) -> String {
        let hits = Store.shared.search(query)
        guard !hits.isEmpty else { return "Nel log non c'e niente su «\(query)»." }
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM HH:mm"
        return hits.map { "[\(fmt.string(from: $0.ts))] \($0.role): \($0.text.prefix(220))" }.joined(separator: "\n")
    }

    // MARK: - file

    private func findFile(_ testo: String) -> String {
        // Due passate: per nome e dentro il contenuto (Spotlight indicizza anche i volumi esterni).
        let perNome = (try? shellSync("/usr/bin/mdfind", ["-name", testo])) ?? ""
        let perContenuto = (try? shellSync("/usr/bin/mdfind", [testo])) ?? ""
        var seen = Set<String>()
        var lines: [String] = []
        for l in (perNome + "\n" + perContenuto).split(separator: "\n") {
            let s = String(l)
            if !s.isEmpty, !seen.contains(s) { seen.insert(s); lines.append(s) }
            if lines.count >= 14 { break }
        }
        guard !lines.isEmpty else { return "Nessun file che contiene «\(testo)» nel nome o dentro (ho cercato anche sui dischi esterni)." }
        return lines.joined(separator: "\n")
    }

    // MARK: - shell

    private func shell(_ path: String, _ args: [String], timeout: TimeInterval = 20) async -> String {
        await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async { c.resume(returning: self.shellSyncOrError(path, args, timeout: timeout)) }
        }
    }

    /// Il comando del Terminale passa sempre da ShellGate: lettura libera, resto con clic.
    private func runCommand(_ args: [String: Any]) async -> String {
        let cmd = arg(args, "comando").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return "Dimmi che comando eseguire." }

        let out: String
        switch ShellGate.classify(cmd) {
        case .blocked(let why):
            return "Non lo eseguo: \(why)."
        case .allowed:
            out = await eseguiSenzaRubareSchermo(cmd)
        case .confirm:
            guard let confirm = Tools.confirm else {
                return "«\(cmd)» cambiare qualcosa e nessuno puo confermarlo: non lo eseguo."
            }
            guard await confirm(cmd) else { return "\(Identita.nome) ha detto di no a: \(cmd)" }
            out = await eseguiSenzaRubareSchermo(cmd)
        }
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Eseguito, nessun output." : String(clean.prefix(4000))
    }

    /// Il comando parte, ma se era un `open` di una app viene rifatto in background:
    /// la regola dell'utente non puo' dipendere da quale strumento il modello sceglie.
    private func eseguiSenzaRubareSchermo(_ cmd: String) async -> String {
        if let aperto = Silenzio.interpretabileOpen(cmd) {
            return await Silenzio.eseguiOpen(argomenti: aperto.argomenti, id: aperto.id, nome: aperto.nome)
        }
        // la stessa regola vale per gli AppleScript: se lo script nomina una app, la
        // app non deve restare davanti. `senzaToccareSchermo` segna chi c'era, fa
        // eseguire lo script, poi rimanda dietro quella app e riporta avanti la sua.
        if !Silenzio.vuoleVedereLeApp(), let script = Silenzio.interpretabileOsascript(cmd) {
            await Silenzio.lanciaNascosto(script.id)
            return await Silenzio.senzaToccareSchermo(script.id) {
                await shell("/bin/zsh", ["-lc", cmd])
            }
        }
        return await shell("/bin/zsh", ["-lc", cmd])
    }

    /// Esegue e aspetta con un tempo limite vero. I pipe si leggono IN PARALLELO
    /// all'esecuzione: prima si aspettava la morte del processo e solo dopo si
    /// leggeva, e un figlio che scriveva piu' del buffer del pipe (~64 KB) restava
    /// bloccato in `write` — non moriva mai, scadeva il timeout e l'output andava
    /// perso. Era il caso vero di `sistema azione=log` (18-25 s per un "l'ho fermato").
    /// Se un nipote tiene aperto il descrittore (succede con `open`) i lettori non
    /// vedono l'EOF: si aspetta un secondo, poi si chiude il nostro capo e si sbloccano.
    private func shellSyncOrError(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe(), out = Pipe()
        p.standardError = err; p.standardOutput = out
        do { try p.run() } catch { return "Errore: \(error.localizedDescription)" }

        let gruppo = DispatchGroup()
        let lucchetto = NSLock()
        var datiOut = Data(), datiErr = Data()
        for (maniglia, versoUscita) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            gruppo.enter()
            DispatchQueue.global().async {
                let dati = maniglia.readDataToEndOfFile()
                lucchetto.lock()
                if versoUscita { datiOut = dati } else { datiErr = dati }
                lucchetto.unlock()
                gruppo.leave()
            }
        }

        let uscita = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); uscita.signal() }
        var uscito = true
        if uscita.wait(timeout: .now() + timeout) == .timedOut {
            uscito = false
            p.terminate()
            if uscita.wait(timeout: .now() + 2) == .timedOut, p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                _ = uscita.wait(timeout: .now() + 2)
            }
        }
        if gruppo.wait(timeout: .now() + 1) == .timedOut {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            _ = gruppo.wait(timeout: .now() + 1)
        }
        lucchetto.lock()
        let datiFinaliOut = datiOut, datiFinaliErr = datiErr
        lucchetto.unlock()

        let e = String(data: datiFinaliErr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let o = String(data: datiFinaliOut, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !uscito {
            return o.isEmpty
                ? "Il comando ha superato \(Int(timeout)) secondi e l'ho fermato: \(path)"
                : o + "\n(il comando e' stato fermato dopo \(Int(timeout)) secondi)"
        }
        if p.terminationStatus != 0 { return e.isEmpty ? "Fallito (codice \(p.terminationStatus))." : "Fallito: \(e)" }
        return o.isEmpty ? "Fatto." : o
    }

    private func shellSync(_ path: String, _ args: [String]) throws -> String {        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// Solo i primi byte di un file: serve per non leggersi crash report enormi.
    private static func inizioFile(_ url: URL, _ n: Int) -> Data {
        guard let f = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? f.close() }
        return (try? f.read(upToCount: n)) ?? Data()
    }

    // MARK: - F1 (sola lettura)

    private func f1(tipo: String, anno: String) async -> String {
        let season = anno.isEmpty ? "current" : anno
        // NB: rounds.json non esiste piu' su jolpi.ca (torna 0 gare): il calendario
        // completo sta nell'endpoint della stagione, senza ?limit.
        let endpoint: String
        let limite: String
        switch tipo {
        case "costruttori": endpoint = "constructorStandings"; limite = "?limit=12"
        case "prossima": endpoint = "next"; limite = "?limit=1"
        case "austin", "calendario": endpoint = season; limite = ""
        default: endpoint = "driverStandings"; limite = "?limit=20"
        }
        let url = ["austin", "calendario"].contains(tipo)
            ? "https://api.jolpi.ca/ergast/f1/\(endpoint).json\(limite)"
            : "https://api.jolpi.ca/ergast/f1/\(season)/\(endpoint).json\(limite)"
        guard let data = await fetch(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mr = root["MRData"] as? [String: Any] else {
            return "Il sito dei dati F1 non risponde: riprova fra un momento."
        }
        // Le classifiche stanno in StandingsTable, le gare in RaceTable.
        let standings = mr["StandingsTable"] as? [String: Any]
        let raceTable = mr["RaceTable"] as? [String: Any]
        let shown = ((standings ?? raceTable)?["season"] as? String) ?? season
        let races = (raceTable?["Races"] as? [[String: Any]]) ?? []
        let lists = (standings?["StandingsLists"] as? [[String: Any]]) ?? []

        switch tipo {
        case "austin":
            // Cerca la gara ad Austin / Stati Uniti (Circuit of the Americas)
            let austinRace = races.first { r in
                let jsonStr = (try? JSONSerialization.data(withJSONObject: r)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return jsonStr.localizedCaseInsensitiveContains("Austin") || jsonStr.localizedCaseInsensitiveContains("United States")
            }
            if let r = austinRace {
                return "GP di Austin (USA): " + raceLine(r)
            } else {
                return "Non trovo la tappa di Austin nel calendario \(shown)."
            }
        case "prossima":
            guard let r = races.first else { return "Nessuna prossima gara trovata." }
            return "Prossima gara: " + raceLine(r)
        case "calendario":
            guard !races.isEmpty else { return "Calendario non disponibile." }
            return "Calendario \(shown):\n" + races.map { "  round " + raceLine($0) }.joined(separator: "\n")
        case "costruttori":
            let cs = (lists.first?["ConstructorStandings"] as? [[String: Any]]) ?? []
            guard !cs.isEmpty else { return "Classifica costruttori non disponibile." }
            return "Classifica costruttori \(shown):\n" + cs.map { row in
                let name = ((row["Constructor"] as? [String: Any])?["name"] as? String) ?? "?"
                return "  \(dig(row, "position")) \(name) — \(dig(row, "points")) punti"
            }.joined(separator: "\n")
        default:
            let ds = (lists.first?["DriverStandings"] as? [[String: Any]]) ?? []
            guard !ds.isEmpty else { return "Classifica piloti non disponibile." }
            let righe = ds.map { row -> String in
                let d = row["Driver"] as? [String: Any] ?? [:]
                let nome = [d["givenName"], d["familyName"]].compactMap { $0 as? String }.joined(separator: " ")
                let team = ((row["Constructors"] as? [[String: Any]])?.first)?["name"] as? String ?? "?"
                return "  \(dig(row, "position")) \(nome.isEmpty ? "?" : nome) — \(dig(row, "points")) pt (\(team))"
            }
            // la prima riga e' il fatto secco: cosi' anche un modello pigro risponde
            // con nome e punti veri invece di dire "Kimi va bene"
            let primo = ds.first.map { row -> String in
                let d = row["Driver"] as? [String: Any] ?? [:]
                let nome = [d["givenName"], d["familyName"]].compactMap { $0 as? String }.joined(separator: " ")
                let team = ((row["Constructors"] as? [[String: Any]])?.first)?["name"] as? String ?? "?"
                return "LEADER: \(nome.isEmpty ? "?" : nome) (\(team)) con \(dig(row, "points")) punti"
            } ?? ""
            return "Classifica piloti \(shown):\n\(primo)\n" + righe.joined(separator: "\n")
        }
    }

    private func raceLine(_ r: [String: Any]) -> String {
        let circuit = r["Circuit"] as? [String: Any]
        let place = (circuit?["Location"] as? [String: Any])?["locality"] as? String ?? "?"
        let country = (circuit?["Location"] as? [String: Any])?["country"] as? String ?? ""
        let name = circuit?["circuitName"] as? String ?? "?"
        let time = (r["time"] as? String).map { ", ore \($0.prefix(5))" } ?? ""
        let dateStr = dig(r, "date")

        var countdown = ""
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        if let targetDate = f.date(from: dateStr) {
            let cal = Calendar.current
            let startToday = cal.startOfDay(for: Date())
            let startTarget = cal.startOfDay(for: targetDate)
            let diff = cal.dateComponents([.day], from: startToday, to: startTarget).day ?? 0
            if diff == 0 {
                countdown = " [OGGI!]"
            } else if diff == 1 {
                countdown = " [DOMANI]"
            } else if diff > 1 {
                countdown = " [mancano \(diff) giorni]"
            } else {
                countdown = " [passata da \(-diff) giorni]"
            }
        }

        return "\(dig(r, "raceName")) (round \(dig(r, "round"))) il \(dateStr)\(time) a \(place)\(country.isEmpty ? "" : ", \(country)")\(countdown) — \(name)"
    }

    private func dig(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "?" }

    // MARK: - meteo (sola lettura)

    private func meteo(citta: String) async -> String {
        let q = citta.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? citta
        guard let geoData = await fetch("https://geocoding-api.open-meteo.com/v1/search?count=1&language=it&name=\(q)"),
              let geo = try? JSONSerialization.jsonObject(with: geoData) as? [String: Any],
              let place = (geo["results"] as? [[String: Any]])?.first,
              let lat = place["latitude"] as? Double, let lon = place["longitude"] as? Double else {
            return "Non trovo «\(citta)»."
        }
        let name = (place["name"] as? String) ?? citta
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m"
            + "&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=3&timezone=auto"
        guard let d = await fetch(url),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cur = obj["current"] as? [String: Any] else { return "Il servizio meteo non risponde." }

        func num(_ k: String) -> String { (cur[k] as? Double).map { String(format: "%.0f", $0) } ?? "?" }
        var out = "Meteo a \(name): \(num("temperature_2m"))°C (percepita \(num("apparent_temperature"))°C), "
            + "vento \(num("wind_speed_10m")) km/h, \(wmo(Int((cur["weather_code"] as? Double) ?? -1)))."
        if let daily = obj["daily"] as? [String: Any],
           let codes = daily["weather_code"] as? [Double],
           let maxs = daily["temperature_2m_max"] as? [Double],
           let mins = daily["temperature_2m_min"] as? [Double] {
            let labels = ["oggi", "domani", "dopodomani"]
            out += "\n" + (0..<min(labels.count, codes.count)).map { i in
                "  \(labels[i]): \(wmo(Int(codes[i]))), \(Int(mins[i]))–\(Int(maxs[i]))°C"
            }.joined(separator: "\n")
        }
        return out
    }

    private func wmo(_ c: Int) -> String {
        switch c {
        case 0: return "sereno"
        case 1: return "poco nuvoloso"
        case 2: return "parzialmente nuvoloso"
        case 3: return "nuvoloso"
        case 45, 48: return "nebbia"
        case 51...57: return "pioviggine"
        case 61...65: return "pioggia"
        case 66, 67: return "pioggia gelata"
        case 71...77: return "neve"
        case 80...82: return "rovesci"
        case 85, 86: return "rovesci di neve"
        case 95...99: return "temporali"
        default: return "condizioni non note"
        }
    }

    private func fetch(_ url: String, agent: String = "\(Marca.nome)/1.0 assistente-locale", timeout: TimeInterval = 12) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        // Un errore di rete istantaneo (0,3 s) capitava gia' sul meteo e faceva dire a
        // Jarvis "il servizio non risponde" mentre era solo un colpo a vuoto: tre tentativi.
        var ultimo: Data?
        for tentativo in 0..<3 {
            var req = URLRequest(url: u)
            req.timeoutInterval = timeout
            req.setValue(agent, forHTTPHeaderField: "User-Agent")
            req.setValue("it-IT,it;q=0.9", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, risposta) = try await URLSession.shared.data(for: req)
                let codice = (risposta as? HTTPURLResponse)?.statusCode ?? 200
                if codice < 500 && codice != 429 { return data }
                ultimo = data
            } catch { ultimo = nil }
            if tentativo < 2 { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        return ultimo
    }

    // MARK: - volume, musica, stampa, schermo

    private func osascript(_ source: String, _ timeout: TimeInterval = 15) async -> String {
        await shell("/usr/bin/osascript", ["-e", source], timeout: timeout)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func volume(_ args: [String: Any]) async -> String {
        let azione = arg(args, "azione")
        switch azione {
        case "leggi":
            let v = trimmed(await osascript("output volume of (get volume settings)"))
            let m = trimmed(await osascript("if output muted of (get volume settings) then return 1"))
            return "Volume \(v)%, muto \(m == "1" ? "si" : "no")."
        case "su", "giu":
            let delta = azione == "su" ? 10 : -10
            let script = """
            set v to (output volume of (get volume settings)) + \(delta)
            if v < 0 then set v to 0
            if v > 100 then set v to 100
            set volume output volume v
            return v
            """
            return "Volume adesso a \(trimmed(await osascript(script)))%."
        case "metti":
            guard let n = Int(trimmed(arg(args, "valore"))), (0...100).contains(n) else {
                return "Dammi un numero tra 0 e 100."
            }
            _ = await osascript("set volume output volume \(n)")
            return "Volume messo a \(n)%."
        case "muto":
            _ = await osascript("set volume output muted true")
            return "Tutto zitto."
        case "parlato":
            _ = await osascript("set volume output muted false")
            return "Audio riattivato."
        default:
            return "Conosco leggi, su, giu, metti, muto e parlato, non «\(azione)»."
        }
    }

    private func music(_ azione: String) async -> String {
        // niente System Events: chiede un permesso di automazione e, se nessuno cliccata,
        // si pianta per decine di secondi. NSWorkspace vede le app aperte senza chiedere niente.
        let aperte = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        let app = aperte.contains("Spotify") ? "Spotify"
            : (aperte.contains("Music") || aperte.contains("Musica") ? "Music" : "")
        guard !app.isEmpty else { return "Ne' Spotify ne' Musica sono aperti: non ho niente da controllare." }

        let script: String
        switch azione {
        case "stato":
            script = """
            tell application "\(app)"
                set s to player state as text
                try
                    return s & " | " & (name of current track) & " - " & (artist of current track)
                on error
                    return s & " (nessun brano caricato)"
                end try
            end tell
            """
        case "playpausa":
            script = "tell application \"\(app)\" to playpause"
        case "avanti":
            script = "tell application \"\(app)\" to next track"
        case "indietro":
            script = "tell application \"\(app)\" to previous track"
        default:
            return "Azioni valide: stato, playpausa, avanti, indietro."
        }
        let out = trimmed(await osascript(script))
        if out.hasPrefix("Fallito") {
            return "Ho provato con \(app) ma il Mac mi ha bloccato: Impostazioni di Sistema → Privacy e sicurezza → Automazione → \(Marca.nome)."
        }
        return out.isEmpty ? "Fatto su \(app)." : "\(app): \(out)"
    }

    private func printers() async -> String {
        let out = await shell("/usr/bin/lpstat", ["-p", "-d"])
        return (out.contains("nessuna destinazione") || out.contains("no destinations"))
            ? "Non c'e nessuna stampante configurata in CUPS."
            : out
    }

    private func printJob(_ args: [String: Any]) async -> String {
        let testo = arg(args, "testo")
        var path = arg(args, "percorso")
        if path.isEmpty, !testo.isEmpty {
            let f = AppPaths.tmp.appendingPathComponent("stampa-\(Int(Date().timeIntervalSince1970)).txt")
            do { try testo.write(to: f, atomically: true, encoding: .utf8) }
            catch { return "Non riesco a preparare il testo: \(error.localizedDescription)" }
            path = f.path
        }
        guard !path.isEmpty else { return "Dimmi cosa stampare: un testo o un file." }
        guard FileManager.default.fileExists(atPath: path) else { return "Non trovo il file \(path)." }

        let stampante = arg(args, "stampante")
        var cmd = [path]
        if !stampante.isEmpty { cmd = ["-d", stampante] + cmd }
        if let n = Int(trimmed(arg(args, "copie"))), n > 1, n <= 20 { cmd = ["-n", String(n)] + cmd }

        if arg(args, "prova") == "si" {
            return "Simulazione: eseguirei  lp \(cmd.joined(separator: " "))  — niente sprecato."
        }
        let out = await shell("/usr/bin/lp", cmd)
        return out.hasPrefix("Fallito") ? out : "In coda: \(out)"
    }

    private func screenshot() async -> String {
        let f = AppPaths.tmp.appendingPathComponent("schermo-\(Int(Date().timeIntervalSince1970)).png")
        let r = await shell("/usr/sbin/screencapture", ["-x", f.path])
        guard FileManager.default.fileExists(atPath: f.path) else {
            return "Screenshot non riuscito: \(r). Controlla Privacy e sicurezza → Registrazione schermo per \(Marca.nome)."
        }
        return "Screenshot salvato in \(f.path)"
    }

    // MARK: - internet

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    private func cercaWeb(_ cosa: String) async -> String {
        let q = cosa.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cosa
        guard let data = await fetch("https://html.duckduckgo.com/html/?q=\(q)", agent: Self.browserUA) else {
            return "Il motore di ricerca non risponde: riprova tra un momento."
        }
        let html = String(decoding: data, as: UTF8.self)
        let links = Self.catture(#"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]{1,240}?)</a>"#, html)
        guard !links.isEmpty else { return "Su internet non ho trovato niente per «\(cosa)»." }
        let stralci = Self.catture(#"class="result__snippet"[^>]*>([\s\S]{1,400}?)</a>"#, html)

        var out = "Risultati per «\(cosa)»:\n"
        for (i, riga) in links.prefix(5).enumerated() {
            out += "  \(i + 1). \(Self.testo(riga[1]))\n     \(Self.pulisciLink(riga[0]))\n"
            if i < stralci.count { out += "     \(String(Self.testo(stralci[i][0]).prefix(220)))\n" }
        }
        out += "\nSe vuoi il testo completo di uno di questi, usa leggi_pagina."
        return out
    }

    private func leggiPagina(_ url: String) async -> String {
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return "Serve un indirizzo http/https." }
        guard let data = await fetch(url, agent: Self.browserUA, timeout: 18) else {
            return "Non riesco ad aprire \(url)."
        }
        let html = String(decoding: data, as: UTF8.self)
        var t = html.replacingOccurrences(of: "(?is)<(script|style|noscript|svg|header|footer|nav)[^>]*>.*?</\\1>",
                                          with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = Self.entita(Self.comprimi(t))
        guard t.count > 60 else { return "La pagina non ha testo leggibile (forse serve JavaScript)." }
        return "Testo di \(url):\n" + String(t.prefix(5000))
    }

    private func notizie(_ argomento: String) async -> String {
        let sezioni = ["prima pagina": "topnews", "cronaca": "cronaca", "tecnologia": "tecnologia",
                       "sport": "sport", "mondo": "mondo", "economia": "economia"]
        guard let cat = sezioni[argomento.lowercased()] else {
            return "Per «\(argomento)» ANSA non ha un feed che conosco. Prova: \(sezioni.keys.joined(separator: ", "))."
        }
        guard let data = await fetch("https://www.ansa.it/sito/notizie/\(cat)/\(cat)_rss.xml") else {
            return "ANSA non risponde adesso."
        }
        let xml = String(decoding: data, as: UTF8.self)
        let pezzi = xml.components(separatedBy: "<item>").dropFirst()
        guard !pezzi.isEmpty else { return "Il feed di ANSA «\(cat)» e' vuoto." }
        var out = "Notizie ANSA — \(argomento):\n"
        for pezzo in pezzi.prefix(8) {
            guard let titolo = Self.trotra(pezzo, "<title>", "</title>") else { continue }
            let pulito = Self.comprimi(Self.entita(titolo.replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")))
            out += "  • \(pulito)\n"
        }
        return out.count > 30 ? out : "Non sono riuscito a leggere il feed di ANSA."
    }

    /// Tutti i gruppi di un pattern, riga per riga.
    private static func catture(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).prefix(12).map { m in
            (1..<m.numberOfRanges).compactMap { r in
                Range(m.range(at: r), in: text).map { String(text[$0]) }
            }
        }.filter { !$0.isEmpty }
    }

    private static func trotra(_ testo: String, _ a: String, _ b: String) -> String? {
        guard let i = testo.range(of: a), let j = testo.range(of: b, range: i.upperBound..<testo.endIndex) else { return nil }
        return String(testo[i.upperBound..<j.lowerBound])
    }

    private static func pulisciLink(_ raw: String) -> String {
        var link = raw.replacingOccurrences(of: "&amp;", with: "&")
        if let r = link.range(of: "uddg=") {
            let dopo = String(link[r.upperBound...])
            let valore = dopo.components(separatedBy: "&").first ?? dopo
            return valore.removingPercentEncoding ?? valore
        }
        if link.hasPrefix("//") { return "https:" + link }
        return link
    }

    private static func testo(_ html: String) -> String {
        comprimi(entita(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)))
    }

    private static func entita(_ s: String) -> String {
        var r = s
        for (da, a) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&#8211;": "-", "–": "-"] {
            r = r.replacingOccurrences(of: da, with: a)
        }
        return r
    }

    private static func comprimi(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - YouTube e Raspberry

    private func youtube(_ args: [String: Any]) async -> String {
        let cosa = arg(args, "cosa")
        guard !cosa.isEmpty else { return "Dimmi cosa devo cercare su YouTube." }
        let q = cosa.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cosa
        let url = "https://www.youtube.com/results?search_query=\(q)"
        let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
        let azione = arg(args, "azione")

        guard azione != "apri_ricerca", let data = await fetch(url, agent: browser) else {
            _ = await shell("/usr/bin/open", [url])
            return "Ho aperto la ricerca di «\(cosa)» su YouTube."
        }
        let html = String(decoding: data, as: UTF8.self)
        // videoRenderer = una vera scheda video: id e titolo vengono via insieme
        let pattern = #""videoRenderer":\{"videoId":"([0-9A-Za-z_-]{11})"[\s\S]{0,6000}?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.){3,120})""#
        guard let coppia = Self.cattura(pattern, html) else {
            _ = await shell("/usr/bin/open", [url])
            return "Non ho trovato un video diretto: ho aperto la pagina dei risultati di «\(cosa)»."
        }
        let id = coppia.0
        let titolo = coppia.1.replacingOccurrences(of: "\\\u{0022}", with: "\u{0022}")
            .replacingOccurrences(of: "\\n", with: " ")
        _ = await shell("/usr/bin/open", ["https://www.youtube.com/watch?v=\(id)"])
        return "Faccio partire «\(titolo)»."
    }

    /// Prima corrispondenza con due gruppi: (id, titolo).
    private static func cattura(_ pattern: String, _ text: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 2,
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text) else { return nil }
        return (String(text[r1]), String(text[r2]))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func raspberry(_ azione: String) async -> String {
        let remoto: String
        switch azione {
        case "processi":
            remoto = "ps -eo pcpu,pmem,comm --sort=-pcpu | head -9"
        case "f1":
            remoto = "curl -s -o /dev/null -w '%{http_code}' --max-time 4 http://localhost:8080/ ; echo; uptime"
        case "rete":
            remoto = "hostname -I; ip route | head -2"
        default:
            remoto = "uptime; free -m | head -2; df -h / | tail -1; vcgencmd measure_temp 2>/dev/null || echo 'temperatura non disponibile'"
        }
        // ConnectTimeout non copre la risoluzione del nome (.local via mDNS puo'
        // plantarsi li'): senza un tempo limite proprio, Jarvis restava 20 secondi
        // fermo su un Raspberry spento e alla fine diceva solo "ho fermato il comando".
        let out = await shell("/usr/bin/ssh", ["-o", "ConnectTimeout=4", "-o", "ConnectionAttempts=1",
                                               "-o", "ServerAliveInterval=4", "-o", "ServerAliveCountMax=2",
                                               "-o", "BatchMode=yes", Identita.raspberry ?? "", remoto],
                              timeout: 11)
        if out.hasPrefix("Fallito") || out.contains("timed out")
            || out.contains("Name or service not known") || out.contains("not known")
            || out.contains("Connection refused") || out.contains("No route to host") {
            return "Il Raspberry non risponde: o e' spento o non siete sulla stessa rete "
                + "\(Identita.raspberry.map { "prova a raggiungere \($0).local" } ?? "nessun host configurato: scrivi tu il nome del Raspberry in ~/.jarvis/raspberry.txt"). Dettaglio: \(String(out.prefix(110)))"
        }
        return out
    }

    private func readScreen(_ domanda: String) async -> String {
        guard await Brain.shared.visionModel() != nil else {
            return "Non posso guardare lo schermo: sul Mac non c'e' un modello visivo."
        }
        guard Capacita.schermo || Capacita.chiediSchermo() else {
            return "Il Mac non mi ha dato Registrazione schermo. \(Identita.nome): Impostazioni di Sistema > Privacy e sicurezza > Registrazione schermo > \(Marca.nome), poi riavvia \(Marca.nome). Non chiedermelo di nuovo finche' non lo fa."
        }
        let f = AppPaths.tmp.appendingPathComponent("vista-\(Int(Date().timeIntervalSince1970)).png")
        let r = await shell("/usr/sbin/screencapture", ["-x", f.path])
        guard FileManager.default.fileExists(atPath: f.path) else {
            return "Non riesco a fare lo screenshot: \(r). Serve il permesso Registrazione schermo."
        }
        defer { try? FileManager.default.removeItem(at: f) }
        let testo = domanda.isEmpty ? "Descrivi cosa c'e' sullo schermo, in breve." : domanda
        let out = await Brain.shared.askVision(image: f, prompt: testo)
        return out.isEmpty ? "Il modello visivo non ha risposto." : out
    }

    // MARK: - Arduino

    static func arduinoPorts() -> String {
        let found = arduinoCandidatePorts()
        if found.isEmpty { return "Nessun Arduino collegato via USB adesso." }
        return "Porti seriali trovate:\n" + found.map { "  \($0)" }.joined(separator: "\n")
    }

    private func arduinoSend(_ args: [String: Any]) async -> String {
        guard let script = bridgeScript("arduino_bridge") else {
            return "Manca lo script di collegamento Arduino (Tools/arduino_bridge.py)."
        }
        guard let py = Tools.python else {
            return "Non trovo Python nel Mac: senza di lui non posso parlare con Arduino."
        }
        let baud = arg(args, "baud").isEmpty ? "9600" : arg(args, "baud")
        var cmd = [script, "--send", arg(args, "comando"), "--baud", baud]
        if let p = (args["porta"] as? String), !p.isEmpty { cmd += ["--port", p] }
        return await shell(py, cmd)
    }

    private func generaStl(_ args: [String: Any]) async -> String {
        guard let script = bridgeScript("stl_bridge"), let py = Tools.python else {
            return "Manca il generatore di STL (Tools/stl_bridge.py)."
        }
        let forma = arg(args, "forma")
        let forme = ["scatola", "cilindro", "cono", "sfera", "prisma"]
        guard forme.contains(forma) else {
            return "Forma sconosciuta: so fare \(forme.joined(separator: ", "))."
        }
        // i numeri arrivano dal parlato: "8,5" va letto come 8.5, non scartato
        func numero(_ chiave: String, _ difetto: Double) -> String {
            let t = arg(args, chiave).replacingOccurrences(of: ",", with: ".")
            guard let v = Double(t) else { return String(format: "%g", difetto) }
            return String(format: "%g", v)
        }
        let altezza = numero("altezza", 30)
        let spessore = numero("spessore", 2)
        var cmd = [script, "--forma", forma, "--altezza", altezza, "--spessore", spessore,
                   "--out", AppPaths.stl.path]
        var descrizione = ""
        switch forma {
        case "scatola":
            let l = numero("larghezza", 80), pr = numero("profondita", 60)
            let aperta = arg(args, "cava") != "no"
            cmd += ["--larghezza", l, "--profondita", pr]
            if aperta { cmd.append("--cava") }
            descrizione = "\(l)x\(pr)x\(altezza) mm, parete \(spessore) mm, \(aperta ? "aperta sopra" : "chiusa")"
        case "cilindro":
            let d = numero("diametro", 40)
            let tubo = arg(args, "tubo") == "si"
            cmd += ["--diametro", d]
            if tubo { cmd.append("--tubo") }
            descrizione = "cilindro Ø\(d)x\(altezza) mm" + (tubo ? ", tubo con parete \(spessore) mm" : " pieno")
        case "cono":
            let d = numero("diametro", 40), d2 = numero("diametro2", 0)
            cmd += ["--diametro", d, "--diametro2", d2]
            descrizione = d2 == "0" ? "cono Ø\(d)x\(altezza) mm"
                                    : "tronco di cono Ø\(d) alla base e Ø\(d2) in cima, alto \(altezza) mm"
        case "sfera":
            let d = numero("diametro", 40)
            cmd += ["--diametro", d]
            descrizione = "sfera Ø\(d) mm"
        default:
            let d = numero("diametro", 40), lati = numero("lati", 6)
            cmd += ["--diametro", d, "--lati", lati]
            descrizione = "prisma a \(lati) lati, Ø\(d)x\(altezza) mm"
        }
        let out = await shell(py, cmd)
        // il generatore parla chiaro sui suoi errori (pareti troppo spesse, mesh non
        // chiusa): si riportano all'utente cosi' come sono, senza "Fallito:" davanti
        if out.hasPrefix("Fallito: ") { return String(out.dropFirst("Fallito: ".count)) }
        guard !out.hasPrefix("Fallito"), !out.hasPrefix("Errore") else { return out }
        let lines = out.split(separator: "\n").map(String.init)
        guard let path = lines.first, FileManager.default.fileExists(atPath: path) else {
            return "Il generatore non ha prodotto il file: \(out)"
        }
        let triangoli = lines.dropFirst().first ?? ""
        if arg(args, "apri") == "si" {
            _ = await shell("/usr/bin/open", ["-a", "BambuStudio", path])
            return "Fatto: \(path) (\(triangoli)). \(descrizione). L'ho aperto in Bambu Studio."
        }
        return "File pronto: \(path) (\(triangoli), mesh chiusa e normali verso fuori). \(descrizione). Di' «apri in Bambu Studio» se lo vuoi nello slicer."
    }

    /// Un'app aperta dal Finder ha un PATH ridotto: cerchiamo i python veri.
    /// Qui NON si lancia nessun processo: bloccare il main thread dentro
    /// Process.waitUntilExit() in un inizializzatore statico porta a deadlock.
    static let python: String? = {
        ["/usr/local/bin/python3", "/opt/homebrew/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Il file Python di servizio: dentro il bundle, o nel progetto durante lo sviluppo.
    private func bridgeScript(_ nome: String) -> String? {
        if let u = Bundle.main.url(forResource: nome, withExtension: "py", subdirectory: "Tools") { return u.path }
        if let u = Bundle.main.url(forResource: nome, withExtension: "py") { return u.path }
        let dev = AppPaths.home.appendingPathComponent("programmi/jarvis/Tools/\(nome).py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    static func arduinoCandidatePorts() -> [String] {
        let prefixes = ["cu.usbmodem", "cu.usbserial", "cu.wchusbserial", "cu.SLAB", "cu.usbto"]
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { name in prefixes.contains { name.hasPrefix($0) } }
            .map { "/dev/" + $0 }
            .sorted()
    }
}
