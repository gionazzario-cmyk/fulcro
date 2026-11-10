import Foundation

/// Il ciclo conversazione + tool, usato sia dal pannello sia dalla chat dell'iPad.
/// La logica e' una sola: cosi un comportamento giusto sul Mac lo e' anche sull'iPad.
final class Agent {
    private var history: [ChatTurn] = []
    private var toolsThisTurn: [String] = []
    private let maxTurns = 22
    private let maxRounds = 5

    init() {}

    func reset() { history = [] }

    /// Riprende una chat gia' salvata: Jarvis ritrova il filo senza ripartire da zero.
    func restore(_ turns: [ChatTurn]) {
        history = turns
        trim()
    }

    /// `onStep(id, etichetta, iniziato)` muove l'animazione del pensiero nel finestrone.
    func ask(_ text: String, source: String,
             onDelta: @escaping (String) -> Void,
             onNote: @escaping (String) -> Void,
             onFinal: @escaping (String) -> Void,
             onStep: @escaping (String, String, Bool) -> Void = { _, _, _ in }) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Store.shared.record(role: "tu", text: clean, source: source)
        toolsThisTurn = []
        filtroStrumenti = nil
        hoGiaRimbalzato = false
        hoSalvatoIo = false
        notaMemoria = ""
        nudge = ""
        ultimoOutputStrumento = ""
        ultimaBozzaBuona = ""
        esitoCanale = ""
        // Prima di tutto il salvataggio: «ricordati che X» non può dipendere dalla
        // buona volontà del modello, quindi lo scrivo su disco e al modello passa
        // solo la parte rimasta da eseguire.
        var domanda = clean
        if let estratto = Self.fattoDaSalvare(clean) {
            let esito = Memory.appendFact(estratto.fatto)
            hoSalvatoIo = true
            onNote(esito)
            notaMemoria = "\(esito) — il fatto è già scritto su disco da te, \(Marca.nome). Non chiamare aggiorna_profilo."
            domanda = estratto.resto
            if domanda.isEmpty {
                // Frase che era solo un ricordo: niente modello, niente attesa.
                let risposta = "Segnato: \(estratto.fatto)"
                history.append(ChatTurn(role: "user", content: clean))
                history.append(ChatTurn(role: "assistant", content: risposta))
                Store.shared.record(role: "jarvis", text: risposta, source: source)
                onFinal(risposta)
                return
            }
        }
        // «la giornata», «facciamo il punto»: il briefing esce dai controlli veri, non
        // dalla memoria del modello. Passa davanti a tutto perche' cosi' non serve
        // nessuno strumento nuovo in lista (e lo schermo non si tocca).
        if Giornata.innesco(domanda) {
            onNote("(faccio il punto con i controlli veri, non a memoria)")
            let punto = await Giornata.punto()
            history.append(ChatTurn(role: "user", content: domanda))
            history.append(ChatTurn(role: "assistant", content: punto))
            Store.shared.record(role: "jarvis", text: punto, source: source)
            onDelta(punto)
            onFinal(punto)
            return
        }
        ultimaDomanda = domanda
        // Se la domanda nomina un'app, la sua scheda va nel prompt di testa: cosi'
        // risponde con i dati veri al primo colpo invece di girare cinque volte sullo
        // strumento `app` (visto il 2026-10-20 con "cosa puoi fare con blender?").
        let notaApp = InventarioApp.notaSullaDomanda(domanda)
        if !notaApp.isEmpty {
            notaMemoria = notaMemoria.isEmpty ? notaApp : notaMemoria + "\n" + notaApp
        }
        Agent.richiestaCorrente = clean
        GuardiaMessaggio.haLettoChat = false   // "leggi e rispondi" va letto DAVVERO in questo giro
        GuardiaMessaggio.agendaControllata = false
        GuardiaMessaggio.invitoVisto = false
        history.append(ChatTurn(role: "user", content: domanda))
        trim()
        await loop(source: source, onDelta: onDelta, onNote: onNote, onFinal: onFinal, onStep: onStep)

        // «quando ha finito, chiuda i programmi che ha aperto»: le app che Jarvis ha
        // aperto LEI come mezzo per un lavoro si richiudono alla fine del giro, qui -
        // vale per chat, voce, iPad e prove. Quelle che lui gli ha chiesto di aprire
        // restano, e se l'utente nel frattempo se n'e' preso una non si tocca.
        let chiuse = await Silenzio.chiudiAperte(soloMezzo: true)
        if !chiuse.hasPrefix("Niente da chiudere") {
            onNote(chiuse)
            Store.shared.record(role: "jarvis", text: chiuse, source: source)
        }
    }

    private var ultimaDomanda = ""
    /// La frase dell'utente del turno corrente: serve a GuardiaMessaggio per capire se
    /// il modello sta per mandare l'ordine invece del messaggio.
    static var richiestaCorrente = ""
    private var hoSalvatoIo = false
    private var notaMemoria = ""
    private var nudge = ""
    private var ultimoOutputStrumento = ""
    /// Nel secondo giro (quello dopo una risposta a vuoto) gli strumenti restano solo
    /// quelli che centrano con la domanda: qwen3, lasciato libero, prende il primo nome
    /// della lista a caso. Visto il 2026-10-21 con «che tempo fa?».
    private var filtroStrumenti: [String]? = nil
    /// Il rimbalzo "hai chiamato lo strumento sbagliato" puo' succedere anche DOPO il
    /// richiamo anti-invenzione: senza questo secondo flag i due casi si rubavano la
    /// chance a vicenda (visto con «quanto manca al GP di Austin?»).
    private var hoGiaRimbalzato = false
    /// L'ultima risposta non vuota del modello: se un richiamo interno fa uscire il
    /// secondo giro bianco, la risposta buona del primo non va persa.
    private var ultimaBozzaBuona = ""
    /// L'ultimo esito di messaggi/mail/whatsapp: serve per non far dire al modello
    /// "inviato" quando lo strumento ha risposto "NON INVIATO" (visto il 2026-10-19).
    private var esitoCanale = ""

    /// Le definizioni degli strumenti per il giro corrente: tutte, o solo quella
    /// nominata dall'indizio quando il modello sta riprovando.
    func definizioniDelGiro() -> [[String: Any]] {
        guard let filtro = filtroStrumenti else { return Tools.shared.definitions }
        let scelte = Tools.shared.definitions.filter { definizione in
            guard let nome = (definizione["function"] as? [String: Any])?["name"] as? String else { return false }
            return filtro.contains(nome)
        }
        return scelte.isEmpty ? Tools.shared.definitions : scelte
    }

    private func loop(source: String,
                      onDelta: @escaping (String) -> Void,
                      onNote: @escaping (String) -> Void,
                      onFinal: @escaping (String) -> Void,
                      onStep: @escaping (String, String, Bool) -> Void = { _, _, _ in }) async {
        // A batteria il modello locale costa 6,6 GB di RAM e CPU piena: il cervello
        // si sposta su Gemini, le mani (strumenti, file, permessi) restano qui.
        if CervelloPortatile.daUsare() {
            await loopPortatile(source: source, onDelta: onDelta, onNote: onNote, onFinal: onFinal, onStep: onStep)
            return
        }
        var hoGiaAvvisato = false
        // qwen3, davanti a uno strumento con tante azioni, puo' mettersi a esplorarlo:
        // cinque chiamate uguali e poi niente risposta. Le firme tengono conto di cosa
        // ha GIA' chiesto, e alla ripetizione si passa subito alla risposta.
        var firmeChiamate = Set<String>()
        var miRipeto = false
        for round in 1...maxRounds {
            var streamed = ""
            let result: (text: String, calls: [ToolCall])
            do {
                result = try await Brain.shared.stream(turns: turns(), tools: definizioniDelGiro()) { piece in
                    streamed += piece
                    onDelta(streamed)
                }
            } catch {
                onFinal("⚠️ \(error.localizedDescription)")
                return
            }

            if ProcessInfo.processInfo.environment["JARVIS_DEBUG"] != nil {
                FileHandle.standardError.write("DEBUG giro \(round): chiamate=\(result.calls.map { $0.name }) testo=\(result.text.prefix(160))\n".data(using: .utf8)!)
            }
            // Lo strumento che questa domanda si aspetta, deciso una volta per giro:
            // serve sia quando il modello risponde senza chiamare niente, sia dopo.
            let suggeritoDiTesta = Self.suggerimentoStrumento(ultimaDomanda)
            if result.calls.isEmpty {
                let final = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Se sostiene di aver fatto o visto qualcosa senza aver chiamato niente,
                // non glielo lascio passare: un richiamo e riprova.
                let canali = ["messaggi", "mail", "whatsapp"]
                let canaleChiamato = toolsThisTurn.contains { canali.contains($0) }
                let volevaCanale = Self.chiedevaDiMandare(ultimaDomanda) && !canaleChiamato
                // "cosa mi ha scritto X" letto dalla cronologia invece che da Messaggi
                let cercavaMale = Self.chiedevaCosaHaScritto(ultimaDomanda)
                    && toolsThisTurn.contains("cerca_nella_storia")
                    && !toolsThisTurn.contains("messaggi")
                // se il fatto l'ho gia' salvato io (deterministico), dire "l'ho salvato"
                // non e' un'invenzione: senza questo controllo il modello veniva
                // rimandato indietro per una cosa vera (visto il 2026-10-19 notte)
                // Strumento chiamato che non c'entra: «quanto manca al GP di Austin?»
                // leggeva l'orario della scuola, «che stampanti ho?» rispondeva con lo
                // stato della Bambu. Il modello qui non aveva sbagliato la FRASE, aveva
                // sbagliato la MANO: senza questo controllo la risposta arrivava lo stesso.
                let suggerito = Self.suggerimentoStrumento(ultimaDomanda)
                // E se lo strumento giusto non l'ha nemmeno chiamato? «chi sta vincendo
                // il mondiale piloti?» ha risposto a voce senza numeri: li' la risposta non
                // "suona" falsa, pero' la domanda aveva una mano precisa.
                let ignoravaLoStrumento = suggerito != nil && toolsThisTurn.isEmpty
                    && !Self.suonaRinuncia(final) && !Self.suonaVuota(final)
                let strumentoSbagliato = suggerito != nil && !toolsThisTurn.isEmpty
                    && !toolsThisTurn.contains(suggerito!.strumento)
                    && !toolsThisTurn.contains(where: { suggerito!.alternative.contains($0) })
                let diceSoloCoseGiaFatte = hoSalvatoIo && !Self.suonaRinuncia(final)
                    && !Self.dichiaraAzioniNonSalvate(final)
                let rimandata = (Self.suonaFalsato(final) && !diceSoloCoseGiaFatte)
                    || Self.suonaRinuncia(final)
                    || Self.suonaVuota(final)
                    || (!hoSalvatoIo && Self.chiedevaDiRicordare(ultimaDomanda))
                    || (!notaMemoria.isEmpty && final.count < 12 && !notaMemoria.lowercased().contains(final.lowercased()))
                    || volevaCanale || cercavaMale || strumentoSbagliato || ignoravaLoStrumento
                // Il rimbalzo per lo strumento sbagliato (o ignorato) e' una seconda
                // chance in piu': dopo un "okay" il modello poteva aver gia' usato la sua.
                let puoRimbalzare = !hoGiaAvvisato
                    || ((strumentoSbagliato || ignoravaLoStrumento) && !hoGiaRimbalzato)
                if puoRimbalzare && (toolsThisTurn.isEmpty || volevaCanale || cercavaMale || strumentoSbagliato || ignoravaLoStrumento) && rimandata {
                    hoGiaAvvisato = true
                    hoGiaRimbalzato = true
                    if let giusto = Self.strumentoGiusto(ultimaDomanda) { filtroStrumenti = [giusto] }
                    onDelta("")
                    history.append(ChatTurn(role: "assistant", content: final))
                    if Self.chiedevaDiRicordare(ultimaDomanda) && !hoSalvatoIo {
                        nudge = "\(Identita.nome) ti ha chiesto di ricordare qualcosa e tu non hai chiamato nessuno strumento: la cosa NON e' salvata. Chiama adesso aggiorna_profilo con il fatto da salvare."
                    } else if Self.suonaRinuncia(final) {
                        nudge = "\(Identita.nome) ti ha chiesto: «\(ultimaDomanda)». Ti sei tirato indietro senza chiamare nessuno strumento, e questa cosa a \(Identita.nome) non piace. "
                            + "Hai questi strumenti: \(Tools.shared.nomiStrumenti). Chiama quello che serve e prova davvero. "
                            + Self.indizioStrumento(ultimaDomanda)
                            + "Se per quella cosa non esiste proprio uno strumento, dillo in UNA riga e fai subito la cosa piu' vicina che puoi fare, senza dire a \(Identita.nome) cosa dovrebbe premere lui."
                    } else if cercavaMale {
                        nudge = "\(Identita.nome) ha chiesto cosa gli HA SCRITTO una persona. `cerca_nella_storia` trova solo le sue chat con te, non i messaggi: "
                            + "chiama messaggi azione ultimi (o non_letti) e cita quello che c'e' scritto li', parola per parola."
                        onNote("(stavo cercando nella cronologia sbagliata: ora leggo i messaggi)")
                    } else if volevaCanale {
                        nudge = "\(Identita.nome) ha chiesto: «\(ultimaDomanda)». Tu hai scritto il testo QUI nella chat, ma \(canali.joined(separator: ", ")) non l'hai chiamato: significa che NON E' PARTITO NIENTE. "
                            + "Chiama adesso messaggi (azione invia, con a= e testo=) oppure mail (azione scrivi) usando il testo che hai gia' scritto. Non chiedere la frase esatta: l'hai gia' scritta."
                        onNote("(avevo solo recitato il messaggio: ora lo mando davvero)")
                    } else if Self.suonaVuota(final) {
                        nudge = "\(Identita.nome) ha chiesto: «\(ultimaDomanda)». Tu hai risposto solo un verso di assenso: per lui vuol dire NON AVER FATTO NIENTE, e la cosa lo fa arrabbiare. "
                            + "Se la richiesta era di dire/scrivere/spiegare a qualcuno, chiama adesso messaggi o mail (azione invia / scrivi) con il testo gia' scritto da te: se non chiami nessuno strumento il messaggio non parte. "
                            + "Se invece la risposta era a voce, scrivila davvero, tutta, in italiano."
                            + Self.indizioStrumento(ultimaDomanda)
                        onNote("(avevo risposto solo \"okay\": riparto con lo strumento)")
                    } else if (strumentoSbagliato || ignoravaLoStrumento), let giusto = suggerito {
                        nudge = "\(Identita.nome) ha chiesto: «\(ultimaDomanda)». Tu hai chiamato \(toolsThisTurn.joined(separator: ", ")), che non c'entra niente. "
                            + "PRIMA di rispondere devi chiamare `\(giusto.strumento)`: se rispondi senza averlo chiamato hai fallito lo stesso. "
                            + "Chiama quello strumento, e la risposta sia SOLO quello che dice lui."
                        onNote("(avevo chiamato lo strumento sbagliato: riparto con \(giusto.strumento))")
                    } else {
                        nudge = "\(Identita.nome) ti ha chiesto: «\(ultimaDomanda)». Nella risposta precedente hai affermato di aver fatto o visto una cosa senza chiamare nessuno strumento, oppure hai risposto a meta'. Ora o chiami lo strumento giusto, oppure dici in modo chiaro che non hai lo strumento per farlo. Non inventare."
                            + Self.indizioStrumento(ultimaDomanda)
                    }
                    onNote(Self.suonaRinuncia(final)
                           ? "(mi sono tirato indietro senza provare: riparto con lo strumento giusto)"
                           : "(controllo interno: sembrava un'invenzione, riprovo con lo strumento)")
                    continue
                }
                // Ultima chance, deterministica: il modello ha avuto due giri per chiamare
                // lo strumento giusto e continua a non chiamarlo. Qui lo eseguiamo NOI
                // (solo strumenti che leggono, vedi `argomentiDiRicupero`) e la risposta
                // diventa quello che dice lo strumento: un fatto vero vale piu' di una
                // frase plausibile.
                if hoGiaRimbalzato, let giusto = suggeritoDiTesta,
                   !toolsThisTurn.contains(giusto.strumento),
                   !toolsThisTurn.contains(where: { giusto.alternative.contains($0) }),
                   let argomenti = Self.argomentiDiRicupero(giusto.strumento, ultimaDomanda) {
                    // La chiamata vera la si scrive nel formato solito: e' davvero
                    // partita, e nella chat deve vedersi come tutte le altre.
                    onNote("→ \(giusto.strumento) \(argomenti.map { "\($0.key)=\"\($0.value)\"" }.joined(separator: " ").prefix(70))")
                    let eseguito = await Tools.shared.run(giusto.strumento, argomenti)
                    if !eseguito.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        toolsThisTurn.append(giusto.strumento)
                        if eseguito.count > ultimoOutputStrumento.count { ultimoOutputStrumento = eseguito }
                        onDelta("")
                        onDelta(eseguito)
                        Store.shared.record(role: "jarvis", text: eseguito, source: source)
                        onFinal(eseguito)
                        return
                    }
                }
                if !final.isEmpty { ultimaBozzaBuona = final }
                var out = final
                // Il caso visto il 2026-10-18: confronta/spiegami lavorano 60 secondi e
                // lui chiude con "okay". Il risultato c'e', va solo riportato.
                let rispostaMonosillabo = out.count < 34
                // prima chiedeva almeno 60 caratteri di output: con "Nessun messaggio da
                // leggere: sono tutti visti." (43) non scattava e l'utente si prendeva "okay"
                if rispostaMonosillabo && !toolsThisTurn.isEmpty && !ultimoOutputStrumento.isEmpty {
                    if !hoGiaAvvisato {
                        hoGiaAvvisato = true
                        onDelta("")
                        history.append(ChatTurn(role: "assistant", content: out))
                        nudge = "Lo strumento che hai chiamato ha gia' risposto questo:\n\(ultimoOutputStrumento.prefix(1200))\n"
                            + "Non dire \"okay\": usa quel contenuto per rispondere a \(Identita.nome), in italiano e corto."
                        onNote("(lo strumento ha lavorato: ripeto la risposta con il suo risultato)")
                        continue
                    }
                    out = String(ultimoOutputStrumento.prefix(1400))
                }
                out = Self.verificaParoleInvio(out)
                if out.isEmpty { out = ultimaBozzaBuona }
                if out.isEmpty { out = "Non sono riuscito a rispondere." }
                out = Self.togliPreambolo(out)
                // Le diagnosi di blocco vanno lette per intero: riassumele e' il modo in cui
                // si perde proprio la parte che dice cosa fare (Bambu, 2026-10-20).
                if !toolsThisTurn.isEmpty && Self.verdettoDaRiportare(ultimoOutputStrumento) {
                    out = String(ultimoOutputStrumento.prefix(1400))
                }
                // citazione inventata: si sostituisce con quello che ha detto lo strumento
                if !toolsThisTurn.isEmpty && Self.citazioneInventata(out, strumento: ultimoOutputStrumento) {
                    onNote("(quella citazione non c'era nei messaggi: metto il testo vero)")
                    out = "Quello che ho letto davvero:\n" + String(ultimoOutputStrumento.prefix(1200))
                }
                if hoGiaAvvisato && toolsThisTurn.isEmpty && Self.suonaFalsato(out) {
                    out += "\n\n(Da verificare: non ho uno strumento che l'ha controllato davvero.)"
                }
                onFinal(out)
                guard !final.isEmpty else { return }
                history.append(ChatTurn(role: "assistant", content: final))
                Store.shared.record(role: "jarvis", text: out, source: source)
                return
            }

            onDelta("")
            history.append(ChatTurn(role: "assistant", content: result.text, toolCalls: result.calls))
            for call in result.calls {
                let firma = call.name.lowercased() + String(call.arguments
                    .lowercased().filter { !$0.isWhitespace }.sorted())
                if firmeChiamate.contains(firma) {
                    miRipeto = true
                    onNote("(\(call.name) l'avevo gia' chiesto cosi': non lo eseguo due volte)")
                    continue
                }
                let vaControllata = hoGiaAvvisato
                    || ["aggiorna_profilo", "genera_stl", "stampa"].contains(call.name)
                if vaControllata, let fuori = Self.chiamataFuoriLuogo(call.name, domanda: ultimaDomanda) {
                    onNote(fuori)
                    history.append(ChatTurn(role: "tool", content: "BLOCCATO DA JARVIS: \(fuori). "
                                            + "Rispondi alla domanda di \(Identita.nome) con cio' che sai, senza chiamare altro.",
                                            toolCallId: call.id, name: call.name))
                    continue
                }
                firmeChiamate.insert(firma)
                toolsThisTurn.append(call.name)
                onNote("→ \(call.name) \(call.arguments.prefix(70))")
                let passoId = UUID().uuidString
                onStep(passoId, Self.etichetta(call.name, call.arguments), true)
                let out = await Tools.shared.run(call.name, Self.decode(call.arguments))
                if ProcessInfo.processInfo.environment["JARVIS_DEBUG"] != nil {
                    FileHandle.standardError.write("DEBUG risultato \(call.name): \(out.prefix(200))\n".data(using: .utf8)!)
                }
                if out.count > ultimoOutputStrumento.count { ultimoOutputStrumento = out }
                if ["messaggi", "mail", "whatsapp"].contains(call.name) {
                    esitoCanale = out
                    Agent.esitoCanaleAttuale = out
                    Agent.esitoCanaleFallito = out.uppercased().hasPrefix("NON INVIATO")
                        || out.uppercased().contains("NON INVIATO:")
                }
                onStep(passoId, call.name, false)
                history.append(ChatTurn(role: "tool", content: String(out.prefix(4000)),
                                        toolCallId: call.id, name: call.name))
            }
            trim()
            // Rimbalzo di meta' giro: il modello ha chiamato strumenti che con la domanda
            // non c'entrano («chi sta vincendo il mondiale piloti?» era finito su youtube,
            // poi su `esegui_comando` per aprire un sito, poi su `aggiorna_profilo` con
            // "Fatto."). Qui si ferma la corsa e si chiede LO strumento giusto, da solo.
            let chiamatiGiusti = suggeritoDiTesta.map { t in
                toolsThisTurn.contains(t.strumento) || toolsThisTurn.contains(where: { t.alternative.contains($0) })
            } ?? true
            if !chiamatiGiusti, !hoGiaRimbalzato, let giusto = suggeritoDiTesta {
                hoGiaRimbalzato = true
                hoGiaAvvisato = true
                filtroStrumenti = [giusto.strumento]
                nudge = "\(Identita.nome) ha chiesto: «\(ultimaDomanda)». Tu hai chiamato \(toolsThisTurn.joined(separator: ", ")), che non c'entra niente. "
                    + "PRIMA di rispondere devi chiamare `\(giusto.strumento)`: se rispondi senza averlo chiamato hai fallito lo stesso. "
                    + "Chiama quello strumento, e la risposta sia SOLO quello che dice lui."
                onNote("(avevo chiamato lo strumento sbagliato: riparto con \(giusto.strumento))")
                continue
            }
            if miRipeto { onNote("(mi ripetevo: mi fermo e rispondo)"); break }
            if round == maxRounds { onNote("(ho smesso di inseguire i tool dopo \(maxRounds) giri)") }
        }

        // Il giro finiva QUI senza dire niente: con "cosa puoi fare con blender?" ha
        // chiamato `app` cinque volte, il contatore scattava e l'utente restava con la
        // nota "(ho smesso di inseguire i tool)" come ultima cosa. Ora si chiude davvero:
        // una richiesta SENZA strumenti, dove non puo' che parlare, e quella e' la risposta.
        var forzata = ""
        var daChiedere = turns()
        daChiedere.append(ChatTurn(role: "user", content:
            "Rispondi ORA a \(Identita.nome) con quello che hai letto dagli strumenti nei giri qui sopra. "
            + "Niente altre chiamate, niente cose che sai di tuo: se uno strumento ha risposto, cita quel risultato. "
            + "Tre righe al massimo, in italiano."))
        do {
            let ultima = try await Brain.shared.stream(turns: daChiedere, tools: []) { pezzo in
                forzata += pezzo
                onDelta(forzata)
            }
            forzata = ultima.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            forzata = ""
        }
        if forzata.isEmpty { forzata = ultimaBozzaBuona }
        if forzata.isEmpty {
            let cosa = Array(Set(toolsThisTurn)).sorted().joined(separator: ", ")
            forzata = cosa.isEmpty
                ? "Non sono riuscito a rispondere."
                : "Ho chiamato " + cosa + " ma mi sono fermato prima di leggere il risultato: chiedimi di nuovo e riprovo."
        }
        let chiusura = Self.togliPreambolo(Self.verificaParoleInvio(forzata))
        history.append(ChatTurn(role: "assistant", content: chiusura))
        Store.shared.record(role: "jarvis", text: chiusura, source: source)
        onFinal(chiusura)
    }

    /// Giro a batteria: pensa Gemini, esegue Jarvis. Se il cloud non risponde non
    /// lo lascio secco - provo in locale una volta sola e glielo dico.
    private func loopPortatile(source: String,
                               onDelta: @escaping (String) -> Void,
                               onNote: @escaping (String) -> Void,
                               onFinal: @escaping (String) -> Void,
                               onStep: @escaping (String, String, Bool) -> Void) async {
        onNote("(a batteria: cervello su Gemini, mani sul Mac)")
        let storia = history.filter { $0.role == "user" || $0.role == "assistant" }
            .map { ($0.role, $0.content) }
        var richiamo = ""
        var hoGiaAvvisato = false
        for tentativo in 0...1 {
            var prompt = JarvisCore.systemPrompt()
            if !notaMemoria.isEmpty { prompt += "\n\nNOTA DI QUESTO GIRO: \(notaMemoria)" }
            if !richiamo.isEmpty { prompt += "\n\nATTENZIONE: \(richiamo)" }
            let esito = await Gemini.chiediConStrumenti(storia: storia,
                                                        strumenti: definizioniDelGiro(),
                                                        sistema: prompt,
                                                        suNota: onNote,
                                                        suPasso: onStep)
            toolsThisTurn.append(contentsOf: esito.chiamati)
            ultimoOutputStrumento = esito.ultimoOutput
            Agent.verificaCanaleNuvola = true

            var out = esito.testo.trimmingCharacters(in: .whitespacesAndNewlines)
            // Il contenuto privato l'ho letto qui: Gemini ha visto solo che esiste.
            if !esito.contenutoLocale.isEmpty {
                out = out.isEmpty ? String(esito.contenutoLocale.prefix(1400))
                                  : out + "\n\n" + String(esito.contenutoLocale.prefix(1400))
            }
            // Nella STORIA resta solo quello che il modello ha scritto di suo. Il
            // contenuto letto sul Mac (messaggi, agenda, file) veniva appeso a `out`
            // e poi messo in `history` per intero: al turno dopo `history` e' proprio
            // cio' che si spedisce a Gemini, quindi il testo privato ripartiva.
            let inStoria: (String) -> String = { testo in
                esito.contenutoLocale.isEmpty
                    ? testo
                    : (esito.testo.isEmpty ? "[\(Identita.nome) ha letto un contenuto sul Mac: resta qui]"
                                           : String(esito.testo.prefix(4000)))
            }

            // I due difetti visti il 2026-10-19 sul cloud: (1) chiama lo strumento a
            // meta' - "messaggi" senza testo - e poi ti rigira l'errore dello strumento,
            // (2) chiude con "okay" dopo che lo strumento ha lavorato. Il modello locale
            // ha gia' questi cancelli, qui mancavano.
            let eco = out.count < 90 && !esito.chiamati.isEmpty
                && out.count < esito.ultimoOutput.count
            let volevaCanaleNuvola = Self.chiedevaDiMandare(ultimaDomanda)
                && !esito.chiamati.contains { ["messaggi", "mail", "whatsapp"].contains($0) }
            if !hoGiaAvvisato && (eco || Self.suonaRinuncia(out) || Self.suonaVuota(out) || volevaCanaleNuvola) {
                hoGiaAvvisato = true
                if volevaCanaleNuvola {
                    richiamo = "\(Identita.nome) ha chiesto: «\(ultimaDomanda)». Hai scritto il testo qui senza chiamare nessuno strumento: non e' partito niente. Chiama messaggi (azione invia, con a= e testo=) o mail (azione scrivi) con il testo che hai gia' composto."
                    onNote("(testo recitato, non mandato: riprovo con lo strumento)")
                } else if eco {
                    richiamo = "Lo strumento \(esito.chiamati.joined(separator: ", ")) ha risposto: «\(String(esito.ultimoOutput.prefix(700)))». "
                        + "Non ricopiare l'errore e non dire okay: se mancava un pezzo (il testo del messaggio, il destinatario, "
                        + "la citta') scrivilo TU nel tono di \(Identita.nome) e richiama lo strumento completo. "
                        + "Se il pezzo manca perche' non puo' saperlo, fai UNA domanda sola."
                    onNote("(mi ha rigirato l'errore dello strumento: riprovo a chiamarlo completo)")
                } else {
                    richiamo = "\(Identita.nome) ti ha chiesto: «\(ultimaDomanda)». Ti sei tirato indietro senza chiamare nessuno strumento. "
                        + "Hai questi strumenti: \(Tools.shared.nomiStrumenti). Chiama quello giusto e prova davvero."
                    onNote("(mi sono tirato indietro: riparto con lo strumento giusto)")
                }
                continue
            }
            if out.isEmpty && !esito.chiamati.isEmpty {
                out = String(ultimoOutputStrumento.prefix(1400))
            }
            if out.isEmpty, esito.chiamati.isEmpty, !ultimoOutputStrumento.isEmpty {
                // lo strumento ha risposto in un giro PRIMA e la chiusura del modello è
                // venuta bianca (preso il 2026-10-22 con «dimmi un po' di notizie di
                // sport»: notizie l'aveva letta davvero, e lui ha risposto "non sono
                // riuscito a rispondere"). Il dato letto vale più di una scusa.
                out = String(ultimoOutputStrumento.prefix(1400))
                history.append(ChatTurn(role: "assistant", content: inStoria(out)))
                Store.shared.record(role: "jarvis", text: out, source: source)
                onDelta(out)
                onFinal(out)
                return
            }
            if out.isEmpty, esito.chiamati.isEmpty {
                onNote(esito.erroreCloud.isEmpty
                       ? "(Gemini non ha dato una risposta: passo una volta al modello locale)"
                       : "(\(esito.erroreCloud): passo al modello locale, consuma batteria)")
                do {
                    var streamed = ""
                    let locale = try await Brain.shared.stream(turns: turns(), tools: definizioniDelGiro()) { piece in
                        streamed += piece
                        onDelta(streamed)
                    }
                    out = locale.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if out.isEmpty { out = streamed }
                    if out.isEmpty { out = "Non sono riuscito a rispondere." }
                    history.append(ChatTurn(role: "assistant", content: inStoria(out)))
                    Store.shared.record(role: "jarvis", text: out, source: source)
                    onFinal(out)
                } catch {
                    onFinal("⚠️ \(error.localizedDescription)")
                }
                return
            }
            out = Self.verificaParoleInvio(out)
            if out.isEmpty { out = "Non sono riuscito a rispondere." }
            out = Self.togliPreambolo(out)
            if !esito.chiamati.isEmpty && Self.verdettoDaRiportare(ultimoOutputStrumento) {
                out = String(ultimoOutputStrumento.prefix(1400))
            }
            onDelta(out)
            history.append(ChatTurn(role: "assistant", content: inStoria(out)))
            Store.shared.record(role: "jarvis", text: out, source: source)
            onFinal(out)
            return
        }
    }

    /// Le parole con cui l'utente chiede di *salvare* una cosa, non di ripetergliela a voce.
    /// "ricordami" sta fuori di proposito: la scuola e' solo log, niente promemoria.
    static let inneschiMemoria = [
        "ricordati che", "ricordati di", "ricordati quanto", "ricordati questo",
        "ricorda che", "non dimenticare che", "non scordare che",
        "tieni presente che", "tieni a mente che",
        "segna che", "segna questo", "annota che", "annota questo",
        "salva che", "salva questo", "metti nel profilo"
    ]

    /// Cose che, se restano attaccate all'innesco, non sono una richiesta vera.
    private static let paroleVuote: Set<String> = [
        "e", "ed", "poi", "anche", "pure", "dai", "ok", "va", "vabbè", "va'",
        "jarvis", "per", "favore", "prego", "grazie", "allora", "senti", "sai"
    ]

    /// Verbi che dentro la coda segnalano lì finisce il fatto e ricomincia una richiesta.
    private static let marcatoriDiRichiesta = [
        "dimmi", "dimmelo", "controlla", "guarda", "apri", "trova", "leggi", "cerca",
        "dammi", "fammi", "accendi", "spegni", "screenshot", "stampa", "vai", "apriti"
    ]

    private static let separatoreDiFrase = [" e ", " ed ", ", e ", " poi ", " quindi ", " e anche "]

    /// Taglia la coda dopo l'innesco nel punto in cui ricomincia una richiesta vera:
    /// "…che il gatto è Luna e dimmi il meteo" → fatto "Il gatto è Luna", resto "dimmi il meteo".
    private static func dividiCoda(_ coda: String) -> (fatto: String, resto: String) {
        var taglio: Range<String.Index>?
        for sep in separatoreDiFrase {
            var cursore = coda.startIndex
            while cursore < coda.endIndex,
                  let r = coda.range(of: sep, options: .caseInsensitive, range: cursore..<coda.endIndex) {
                let dopo = coda[r.upperBound...].lowercased()
                if marcatoriDiRichiesta.contains(where: { dopo.hasPrefix($0) }),
                   taglio == nil || r.lowerBound < taglio!.lowerBound {
                    taglio = r
                }
                cursore = r.upperBound
            }
        }
        guard let t = taglio else { return (coda, "") }
        // " e" / " ed" / " poi" finali non sono parte del fatto: "il link e X e" -> "il link e X"
        var fattoGrezzo = String(coda[..<t.lowerBound])
        while true {
            let pulito = fattoGrezzo.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!-"))
            let bassa = pulito.lowercased()
            let tagliati = [" e", " ed", " poi", " anche", " pure"]
            guard let fine = tagliati.first(where: { bassa.hasSuffix($0) }) else { fattoGrezzo = pulito; break }
            fattoGrezzo = String(pulito.dropLast(fine.count))
        }
        let fatto = fattoGrezzo
        let resto = String(coda[t.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (fatto, resto)
    }

    /// Estrae il fatto da salvare senza dipendere dal modello.
    /// Ritorna nil se la frase è una domanda o se dopo l'innesco non resta niente;
    /// `resto` è la parte della frase che il modello deve ancora eseguire.
    static func fattoDaSalvare(_ testo: String) -> (fatto: String, resto: String)? {
        let t = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("?") else { return nil }
        // «segna questo come compito» non e' un fatto sul profilo: e' un compito, e va
        // scritto in compiti.md (o preso dagli appunti). Il 2026-10-20 questa frase finiva
        // qui dentro e salvava la parola "compito" come se fosse una verita' su l'utente.
        let basso = t.lowercased()
        if ["compito", "compiti", "appunti", "appunto", "scadenza"].contains(where: basso.contains) { return nil }
        for inn in inneschiMemoria {
            guard let r = t.range(of: inn, options: .caseInsensitive) else { continue }
            let prefissoRaw = String(t[..<r.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!-"))
            let diviso = dividiCoda(String(t[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,;:!-")))
            guard diviso.fatto.count >= 4 else { return nil }
            // "segna questo" da solo non e' un fatto: tre parole sono il minimo per
            // essere una cosa che vale la pena ricordargli
            guard diviso.fatto.split(separator: " ").count >= 3 else { return nil }
            var fatto = diviso.fatto
            if let first = fatto.first { fatto = first.uppercased() + fatto.dropFirst() }
            var resto = diviso.resto
            if !Self.prefissoVuoto(prefissoRaw) {
                resto = resto.isEmpty ? prefissoRaw : prefissoRaw + " " + resto
            }
            return (fatto, resto)
        }
        return nil
    }

    /// "e", "Jarvis,", "poi" non sono una seconda richiesta: sono rumore attorno all'innesco.
    private static func prefissoVuoto(_ prefisso: String) -> Bool {
        let token = prefisso.lowercased()
            .split(whereSeparator: { " ,.;:!'\n\t".contains($0) })
        return token.allSatisfy { paroleVuote.contains(String($0)) }
    }

    /// Come si chiama lo strumento nel fumetto del pensiero: parole sue, non JSON.
    static func etichetta(_ nome: String, _ argomenti: String) -> String {
        let dizionario: [String: String] = [
            "cerca_nella_storia": "cerco nella cronologia",
            "apri_app": "apro un'app", "trova_file": "cerco un file", "apri_percorso": "apro un file",
            "apri_url": "apro una pagina", "f1": "leggo i dati F1", "meteo": "guardo il meteo",
            "volume": "tocco il volume", "musica": "comando la musica", "stampanti": "cerco le stampanti",
            "stampa": "preparo la stampa", "cerca_web": "cerco su internet", "leggi_pagina": "leggo una pagina",
            "notizie": "leggo le notizie", "youtube": "cerco su YouTube", "raspberry": "chiedo al Raspberry",
            "leggi_schermo": "guardo il tuo schermo", "schermo": "faccio uno screenshot",
            "genera_stl": "genero uno STL", "esegui_comando": "eseguo un comando",
            "stato_arduino": "cerco Arduino", "invia_ad_arduino": "parlo con Arduino",
            "aggiorna_profilo": "memorizzo una cosa", "leggi_profilo": "rileggo il profilo",
            "leggi_orario": "guardo l'orario", "compiti": "leggo i compiti",
            "modalita_studio": "accendo il controllo compiti", "voce": "cambio la voce",
            "compiti_da_classeviva": "apro ClasseViva", "messaggi": "leggo i messaggi",
            "mail": "guardo la mail", "whatsapp": "apro WhatsApp", "orecchio": "metto l'orecchio",
            "permessi": "controllo i permessi",
            "contatti": "cerco nell'Anagrafica", "cervello": "controllo dove ragiono",
            "agenda": "guardo il calendario", "cose": "cerco tra le sue cose salvate",
            "scrivi_file": "scrivo un file", "leggi_file": "leggo un file",
            "riunione": "prendo appunti dalla riunione",
            "conversazione": "parlo io con quella persona",
            "bambu": "guardo la stampante 3D"
        ]
        return dizionario[nome] ?? nome
    }

    /// "ricordati che..." senza chiamata allo strumento vuol dire non averlo fatto.
    static func chiedevaDiRicordare(_ testo: String) -> Bool {
        let t = testo.lowercased()
        return ["ricordati", "ricorda che", "salva che", "salva questo", "segna", "annota", "metti nel profilo"]
            .contains(where: t.contains)
    }

    /// Le frasi con cui si tira indietro invece di provare: sono quelle che fanno
    /// arrabbiare l'utente ("mi dice che non posso"), quindi non passano.
    static func suonaRinuncia(_ text: String) -> Bool {
        let low = text.lowercased()
        let rinunce = ["non posso", "non riesco", "non è possibile", "non e possibile", "non sono in grado",
                       "mi dispiace", "purtroppo", "prova a ", "prova tu", "apri tu", "apriti tu",
                       "devi aprire", "devi digitare", "devi controllare", "dovresti", "digita tu",
                       "dammi l'indirizzo", "dammi il link", "non ho accesso", "non ho la possibilita",
                       "non ho questa funzione", "non posso farlo", "non e' possibile", "io non posso",
                       "dimmi cosa scrivere", "dimmi il testo", "cosa devo scrivere", "cosa devo dire",
                       "scrivi tu il messaggio", "dammi il testo", "dimmi esattamente", "dettaglia il testo",
                       "non ho un account", "nessun account", "prova a mandarla di nuovo",
                       // visto il 2026-10-20 con "rispondi a papi": chiedeva la frase invece
                       // di leggere la chat e comporla lui
                       "scrivi il testo", "scrivi tu il testo", "dimmi cosa mandare", "dimmi cosa dire",
                       "che testo mando", "che cosa devo scrivere", "dimmi cosa vuoi che scriva",
                       "scrivimi il testo", "passami il testo", "lo mostro e ti chiedo conferma",
                       "dimmi tu cosa rispondere", "cosa devo rispondere"]
        return rinunce.contains(where: low.contains)
    }

    /// Toglie la parte tra parentesi scritta per il modello: all'utente deve arrivare
    /// il risultato, non il rimprovero interno.
    static func pulisciRisposta(_ testo: String) -> String {
        guard let i = testo.range(of: "(ISTRUZIONI PER TE: ") else { return testo }
        return String(testo[..<i.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "INVIATO" e "NON INVIATO" non sono sinonimi: se lo strumento ha detto che non
    /// e' partito niente, la risposta che arriva all'utente deve dirlo.
    static func verificaParoleInvio(_ testo: String) -> String {
        let low = testo.lowercased()
        let rivendica = ["inviato", "partito", "mandato", "spedito", "ho mandato", "l'ho inviato"]
        let fallito = esitoCanaleFallito
        if fallito && rivendica.contains(where: { low.contains($0) }) {
            return String(pulisciRisposta(esitoCanaleAttuale).prefix(900))
        }
        return testo
    }

    /// Valori di supporto (statici perche' l'helper e' statico): li scrive il turno corrente.
    static var verificaCanaleNuvola = false
    static var esitoCanaleAttuale = ""
    static var esitoCanaleFallito = false

    /// «cosa mi ha scritto Marco?» si legge dall'archivio di Messaggi, non dalla
    /// cronologia delle chat di Jarvis: stanotte ha citato un suo messaggio di servizio
    /// trovato con `cerca_nella_storia` e la cosa sembrava vera.
    static func chiedevaCosaHaScritto(_ testo: String) -> Bool {
        let t = Memory.senzaAccenti(testo)
        let verbi = ["ha scritto", "ha detto", "ha mandato", "risposto", "scrive", "dice"]
        guard verbi.contains(where: { t.contains($0) }) else { return false }
        return t.contains("mi ha") || t.contains("a me") || t.contains("ultima") || t.contains("cosa ha")
    }

    /// Richieste che vogliono un messaggio PARTITO, non un testo recitato qui nella
    /// chat. «spiega bene a il contatto di prova come funzioni» era finita in un "Okay." e
    /// poi in un discorso scritto all'utente: in nessun dei due casi era partito nulla.
    static func chiedevaDiMandare(_ testo: String) -> Bool {
        let t = testo.lowercased()
        let verbi = ["di' a", "dì a", "dire a", "digli", "dille", "scrivi a", "scrivere a", "scrivi",
                     "manda", "mandagli", "spieg", "present", "salut", "rispond", "rispondi", "avvisa"]
        guard verbi.contains(where: { t.contains($0) }) else { return false }
        // sue eccezioni: roba detta all'utente stesso non e' un invio
        let personali = [" a me", "a te", "spiegami", "dimmi", "a noi", "a voi", "rispondi a me"]
        if personali.contains(where: { t.contains($0) }) { return false }
        return t.contains(" a ") || t.contains(" a un") || t.contains("gli ") || t.contains("le ")
    }

    /// Le diagnosi di blocco vanno lette per intero. Se il modello le riassume si perde
    /// proprio la parte che dice cosa fare: il 2026-10-20, chiesto "quanto manca alla
    /// stampa", aveva buttato via "nella riga codice = c'e' la seriale" e lasciato solo
    /// "il codice e' dietro la stampante".
    static func verdettoDaRiportare(_ strumento: String) -> Bool {
        strumento.hasPrefix("NON COLLEGATO:")
    }

    /// "Okay, ..." e "Certo! ..." non sono risposte: il contenuto arriva dopo. Si toglie
    /// il preambolo, ma solo se dopo resta qualcosa di vero (altrimenti e' il caso di
    /// suonaVuota, che fa riprovare).
    static func togliPreambolo(_ testo: String) -> String {
        let bassa = testo.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefisso in ["okay, ", "ok, ", "certo, ", "subito, ", "fatto, ", "d'accordo, ", "okey, "] {
            if bassa.hasPrefix(prefisso) {
                let coda = String(testo.dropFirst(prefisso.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if coda.count > 12 { return prefixmaiuscola(coda) }
            }
            if bassa.hasPrefix(prefisso.replacingOccurrences(of: " ", with: "")) {
                let taglio = prefisso.count - 1
                let coda = String(testo.dropFirst(taglio)).trimmingCharacters(in: CharacterSet(charactersIn: ",.! "))
                let ripulito = coda.trimmingCharacters(in: .whitespacesAndNewlines)
                if ripulito.count > 12 { return prefixmaiuscola(ripulito) }
            }
        }
        return testo
    }

    private static func prefixmaiuscola(_ t: String) -> String {
        guard let prima = t.first else { return t }
        return String(prima).uppercased() + t.dropFirst()
    }

    /// Se la risposta cita quello che qualcuno avrebbe detto, il citato deve esistere
    /// davvero nell'output dello strumento. Stanotte ha risposto "l'ultima cosa che ti ha
    /// scritto nonna e: Ciao, l'utente! Che ci fai qui?..." mentre nel database c'era
    /// solo "Ti amo": una citazione inventata e' la cosa peggiore che puo' fare.
    static func citazioneInventata(_ risposta: String, strumento: String) -> Bool {
        guard strumento.count > 20 else { return false }
        let bassaRisposta = Memory.senzaAccenti(risposta)
        let bassaStrumento = Memory.senzaAccenti(strumento)
        var citate: [String] = []
        // «virgolette basse», "doppie" e : dopo "ha scritto/detto"
        for apri in ["\u{00ab}", "\""] {
            let chiudi = apri == "\u{00ab}" ? "\u{00bb}" : "\""
            var resto = risposta
            while let i = resto.range(of: apri) {
                let dopo = resto[i.upperBound...]
                guard let f = dopo.range(of: chiudi) else { break }
                citate.append(String(dopo[dopo.startIndex..<f.lowerBound]))
                resto = String(dopo[f.upperBound...])
            }
        }
        let verbi = ["ha scritto", "ha detto", "ha mandato", "ti ha scritto", "risposta e", "scrive:"]
        for verbo in verbi {
            if let i = bassaRisposta.range(of: verbo) {
                let coda = String(risposta[i.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " :\u{00ab}\""))
                if coda.count > 14 { citate.append(String(coda.components(separatedBy: "\n").first ?? coda)) }
            }
        }
        for citata in citate {
            let chiave = Memory.senzaAccenti(citata.trimmingCharacters(in: .whitespacesAndNewlines))
            guard chiave.count >= 14 else { continue }
            // bastano 12 caratteri di fila: cosi' una parafrasi corta non viene punita
            let testa = String(chiave.prefix(12))
            if !bassaStrumento.contains(testa) { return true }
        }
        return false
    }

    /// True se la frase dichiara cose fatte che il salvataggio deterministico NON copre
    /// ("ho aperto", "ho controllato", "ho inviato"): quelle restano da verificare.
    static func dichiaraAzioniNonSalvate(_ text: String) -> Bool {
        let low = text.lowercased()
        let oltreIlSalvataggio = ["ho aperto", "ho chiuso", "ho controllato", "ho cercato", "ho inviato",
                                  "ho mandato", "ho stampato", "ho eseguito", "ho letto lo schermo",
                                  "ho guardato", "ho alzato", "ho abbassato", "ho messo la sveglia"]
        return oltreIlSalvataggio.contains(where: { low.contains($0) })
    }

    /// Le risposte che non sono una risposta: un verso di assenso, o l'annuncio che
    /// sta per fare. Il 2026-10-19 l'utente ha ricevuto "Okay." tre volte sulla stessa
    /// richiesta, senza che partisse niente: qwen chiudeva cosi' quando la frase era lunga.
    static func suonaVuota(_ text: String) -> Bool {
        let parole = text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: " \n\t(,;"))
            .filter { !$0.isEmpty }
        let low = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:'\u{201c}\u{201d}\u{2018}\u{2019}\u{2026}\n\t"))
        if low.isEmpty { return true }
        if low.hasPrefix("ok") && !low.contains(where: { $0.isNumber }) { return true }
        // il modello a volte sputa fuori la CHIAMATA invece del risultato
        // ("fucina azione=prova file=... testo_nuovo=..."): non e' una risposta
        let nomi = Tools.shared.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        if let primo = parole.first, nomi.contains(primo) { return true }
        let riempitivi = ["certo", "subito", "fatto", "perfetto", "d'accordo", "va bene", "va bn",
                          "si si", "sisi", "ecco", "grazie", "prega", "sto leggendo", "sto controllando",
                          "continua a scrivere", "continua a testare", "dimmi tu", "come vuoi"]
        if low.count < 26 && riempitivi.contains(where: { low.hasPrefix($0) }) { return true }
        // "ciao sono jarvis." detto all'utente non e' quello che ha chiesto: se la frase
        // era "di'/spiegai/scrivi a X" e non ha chiamato niente, e' solo una recita
        return false
    }

    /// Blocca gli strumenti che **fanno** qualcosa quando il modello li chiama fuori
    /// tempo: succede nel secondo giro, quello che parte dopo una risposta a vuoto,
    /// dove qwen3 prende il primo nome a caso. Misurato il 2026-10-21: alla domanda
    /// «che tempo fa?» ha chiamato `genera_stl` e ha davvero aperto una
    /// scatola in Bambu Studio. Se la domanda non parla di quella cosa, non si fa.
    /// Ritorna nil quando la chiamata e' normale.
    static func chiamataFuoriLuogo(_ strumento: String, domanda: String) -> String? {
        let d = domanda.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
        let nomi = Self.senzaAccenti(d)
        switch strumento {
        case "genera_stl", "stampa":
            let di3d = ["scatola", "stl", "3d", "stamp", "pezzo", "cilindro", "supporto", "tubo", "modello"]
            if di3d.contains(where: { nomi.contains($0) }) { return nil }
            return "«\(strumento)» non c'entra con quello che ha chiesto \(Identita.nome): non genero né stampo niente"
        case "scrivi_file":
            let diScrittura = ["scrivi", "salva", "file", "crea", "programma", "script", "md", "txt"]
            if diScrittura.contains(where: { nomi.contains($0) }) { return nil }
            return "stavo per scrivere un file che nessuno ha chiesto"
        case "esegui_comando":
            let diComando = ["comando", "terminale", "esegui", "installa", "brew", "ls ", "df", "cp ", "mv ",
                             "script", "programma", "cartella", "file", "log", "mac ", "spazio"]
            if diComando.contains(where: { nomi.contains($0) }) { return nil }
            return "«esegui_comando» non c'entra con la domanda: non eseguo nulla alla cieca"
        case "aggiorna_profilo":
            let diMemoria = ["ricordati", "ricorda", "segna", "annota", "salva", "il mio", "preferisco", "odio"]
            if diMemoria.contains(where: { nomi.contains($0) }) { return nil }
            return "non sto salvando niente nel profilo: \(Identita.nome) non l'ha chiesto"
        default:
            return nil
        }
    }

    /// Testo senza accenti, per confrontare parole dette a voce o scritte a mano.
    private static func senzaAccenti(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "it_IT"))
    }

    /// Un indizio sullo strumento giusto, usato **solo nel secondo giro**.
    /// Perche' esiste: quando il modello ha gia' risposto a vuoto, rimandarlo al buio
    /// fa chiamare il primo strumento che capita — misurato il 2026-10-21, per
    /// «che tempo fa?» ha chiamato `genera_stl` e ha davvero aperto una
    /// scatola in Bambu Studio. L'indizio nomina lo strumento, non esegue niente:
    /// se il modello ha una ragione buona per sceglierne un altro e' libero.
    static func indizioStrumento(_ domanda: String) -> String {
        guard let strumento = Self.strumentoGiusto(domanda) else { return "" }
        return " Di solito, per una domanda cosi', lo strumento e' `\(strumento)`: chiama quello, non un altro a caso."
    }

    /// Ultima chance: se la domanda aveva uno strumento giusto e il modello non l'ha
    /// chiamato nemmeno dopo il rimbalzo, **lo eseguiamo noi** e rispondiamo con quello
    /// che dice. Gli argomenti sono ricavati dalla frase, a voce scoperta: qui non ci
    /// va nessuno strumento che scrive o manda qualcosa (`esegui_comando`, `stampa`,
    /// `genera_stl`, `scrivi_file`, e gli invii di `messaggi`/`mail`/`whatsapp`), perche'
    /// un'esecuzione decisa da noi al posto del modello deve poter solo LEGGERE.
    /// L'unica eccezione e' `volume`: quando arriva fin qui, l'utente ha chiesto
    /// esattamente quello ("alza il volume a 40").
    static func argomentiDiRicupero(_ strumento: String, _ domanda: String) -> [String: String]? {
        let d = domanda.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
        switch strumento {
        case "f1":
            if d.contains("austin") { return ["tipo": "austin"] }
            if d.contains("costruttori") || d.contains("squadre") { return ["tipo": "costruttori"] }
            if d.contains("prossima") || d.contains("manca") || d.contains("quando c'e'") { return ["tipo": "prossima"] }
            return ["tipo": "piloti"]
        case "meteo":
            return ["citta": cittaNellaDomanda(domanda)]
        case "volume":
            if let numero = Self.numeroNellaDomanda(domanda) { return ["azione": "metti", "valore": String(numero)] }
            if d.contains("muto") { return ["azione": "muto"] }
            if d.contains("su'") || d.contains("su ") || d.contains("piu' forte") { return ["azione": "su"] }
            if d.contains("giu") || d.contains("piano") { return ["azione": "giu"] }
            return ["azione": "leggi"]
        case "trova_file":
            return ["testo": Self.paroleChiave(domanda)]
        case "cerca_web":
            return ["cosa": Self.paroleChiave(domanda)]
        case "youtube":
            return ["cosa": Self.paroleChiave(domanda), "azione": "apri_ricerca"]
        case "apri_app":
            // «fai il ponte di Keka»: se l'ha chiesto con parole sue, il recupero fa
            // proprio quello — scrive una scheda in ~/.jarvis/app/integrazioni e chiede
            // una mano a Gemini. Non tocca niente fuori da li', e non apre nessuna app.
            if d.contains("ponte") || d.contains("integrazione") || d.contains("estensione") {
                let parole = domanda.split(separator: " ").map(String.init)
                if let i = parole.firstIndex(where: { ["di", "del", "della", "delle", "dei", "per"].contains($0.lowercased()) }),
                   i + 1 < parole.count {
                    let nome = parole[(i + 1)...].joined(separator: " ")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
                    if !nome.isEmpty { return ["azione": "integra", "nome": nome] }
                }
                return ["azione": "integrazioni"]
            }
            return ["azione": "lista", "testo": Self.paroleChiave(domanda)]
        case "notizie":
            // le sezioni che hanno DAVVERO un feed ANSA (le altre rispondono 404, e il
            // feed sbagliato era il motivo per cui "notizie di sport" restava senza risposta)
            for (parola, sezione) in [("sport", "sport"), ("calcio", "sport"), ("formula", "sport"),
                                      ("motor", "sport"), ("olimpi", "sport"),
                                      ("tecnologia", "tecnologia"), ("cellulare", "tecnologia"),
                                      ("smartphone", "tecnologia"), ("economia", "economia"),
                                      ("soldi", "economia"), ("cronaca", "cronaca"),
                                      ("polizia", "cronaca"), ("mondo", "mondo"), ("estero", "mondo")]
            where d.contains(parola) {
                return ["argomento": sezione]
            }
            return ["argomento": "prima pagina"]
        case "compiti":
            return ["azione": "lista"]
        case "raspberry":
            return ["azione": "stato"]
        case "bambu":
            return ["azione": "stato"]
        case "mail":
            return ["azione": "riassumi"]
        case "appunti":
            return ["azione": "spiega"]
        case "leggi_orario":
            return d.contains("domani") ? ["giorno": "domani"] : [:]
        case "stampanti":
            return [:]
        case "leggi_schermo":
            return ["domanda": domanda]
        default:
            return nil
        }
    }

    /// Le parole che restano tolte le istruzioni: servono come ricerca (mdfind, web, app).
    static func paroleChiave(_ domanda: String) -> String {
        let daButtare: Set<String> = ["cercami", "cerca", "trovami", "trova", "dimmi", "guarda", "fammi",
                                      "il", "lo", "la", "i", "gli", "le", "un", "una", "del", "della",
                                      "dei", "delle", "su", "per", "con", "che", "cosa", "come", "dove",
                                      "quando", "esce", "nuovo", "nuova", "mia", "mio", "miei", "delle",
                                      "internet", "online", "google", "youtube", "video", "app", "file",
                                      "ho", "hai", "puoi", "puo", "fare", "questo", "quella", "quello",
                                      "?", "!", ",", ".", "'", "a", "di", "e", "o", "in", "al", "alla"]
        let tenute = domanda.split { " ,?.!\n".contains($0) || $0 == "'" || $0 == "\u{201c}" || $0 == "\u{201d}" }
            .map(String.init)
            .filter { !$0.isEmpty && !daButtare.contains($0.lowercased()) }
        return tenute.prefix(6).joined(separator: " ")
    }

    /// Il primo numero scritto nella frase (per "alza il volume a 40"), o nil.
    static func numeroNellaDomanda(_ domanda: String) -> Int? {
        var corrente = ""
        for carattere in domanda {
            if carattere.isNumber { corrente.append(carattere) }
            else if !corrente.isEmpty { break }
        }
        return Int(corrente).map { min(max($0, 0), 100) }
    }

    /// La citta' detta nella frase, o quella di casa: `meteo` la vuole per forza.
    static func cittaNellaDomanda(_ domanda: String) -> String {
        let d = domanda.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "it_IT"))
        let conosciute: [(String, String)] = [("torino", "Torino"),
                                              ("milano", "Milano"), ("roma", "Roma"), ("napoli", "Napoli"),
                                              ("bologna", "Bologna"), ("genova", "Genova"), ("aosta", "Aosta")]
        for (parte, nome) in conosciute where d.contains(parte) { return nome }
        return Identita.citta ?? ""
    }

    /// Il nome dello strumento che di solito serve per questa domanda, o nil.
    /// Indizio sullo strumento per una domanda: nome + le alternative che vanno bene
    /// lo stesso. Una tabella sola, perche' due tabelle che divergono sono peggio di
    /// nessuna tabella. `alternative` esiste per frasi come «accendi l'orecchio dei
    /// messaggi»: li' `orecchio` e' giusto, e un rimbalzo su `messaggi` sarebbe un danno.
    /// Ritorna nil quando la domanda non somiglia a niente di conosciuto.
    static func suggerimentoStrumento(_ domanda: String) -> (strumento: String, alternative: [String])? {
        let d = domanda.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
        let tabella: [([String], String, [String])] = [
            (["che stampanti", "stampanti ho", "elenca le stampanti", "quante stampanti"], "stampanti", []),
            (["a1 mini", "la mia stampa", "al che punto la stampa", "la stampa finita"], "bambu", ["stampanti"]),
            (["che tempo", "tempo fa", "meteo", "piovera", "piove", "fuori fa freddo", "temperatura fuori"], "meteo", []),
            (["volume", "piu' forte", "piano il mac", "muto il mac"], "volume", []),
            // trova_file prima di f1: «cercami il file della simulazione f1» e' una
            // ricerca di file, non una domanda di Formula 1 (preso in test il 2026-10-21)
            (["il file", "trova file", "cercami il", "dov'e' il", "dove sta il", "la cartella"], "trova_file", ["esegui_comando", "leggi_file"]),
            (["mondiale", "piloti", "costruttori", "gp di", "gran premio", "classifica", "formula 1"], "f1", []),
            (["su internet", "in internet", "google", "online", "quando esce", "cerca sul web"], "cerca_web", ["leggi_pagina", "notizie", "youtube"]),
            // dopo cerca_web: "notizie" vince solo se non si e' chiesto esplicitamente
            // "su internet". Preso perche' "dimmi un po' di notizie di sport" restava senza
            // chiamata (2026-10-22, suite 26/28)
            (["notizie", "telegiornale", "cosa e' successo", "ultime da", "giornale"], "notizie", ["cerca_web"]),
            // l'integrazione/ponte di una app: preso il 2026-10-22 perche' senza indizio
            // qwen3 rispondeva con il **ponte di Wheatstone** (il circuito) alla frase
            // "fai il ponte di Keka". "ponte" da solo e' ambiguo: si chiede "ponte di"
            (["integrazione", "integrazioni", "ponte di", "ponti di", "estensione per", "estensione di"], "apri_app", ["app"]),
            (["che app", "app ho", "app per", "con blender", "con gimp", "con photoshop", "aprire con"], "apri_app", ["app"]),
            (["youtube", "un video di", "cerca video", "video che"], "youtube", ["cerca_web"]),
            (["ho messaggi", "nuovi messaggi", "chat non lette", "cosa mi ha scritto"], "messaggi", ["orecchio", "contatti"]),
            (["che compiti", "i compiti", "compiti ho", "verifiche"], "compiti", ["compiti_da_classeviva", "agenda"]),
            (["raspberry", "il pi", "il raspberry pi"], "raspberry", []),
            (["che materie", "il mio orario", "orario di domani"], "leggi_orario", ["agenda"]),
            (["le mail", "mail non lette", "riassumi le mail"], "mail", []),
            (["sullo schermo", "cosa c'e' sullo schermo", "guarda lo schermo"], "leggi_schermo", ["schermo"]),
            (["negli appunti", "quello che ho copiato"], "appunti", [])
        ]
        for (parole, strumento, alternative) in tabella where parole.contains(where: { d.contains($0) }) {
            return (strumento, alternative)
        }
        return nil
    }

    /// Il nome dello strumento che di solito serve per questa domanda, o nil.
    static func strumentoGiusto(_ domanda: String) -> String? { suggerimentoStrumento(domanda)?.strumento }

    /// Gli strumenti che vanno bene lo stesso per questa domanda (vuoto = solo quello).
    static func alternativeDi(_ domanda: String) -> [String] { suggerimentoStrumento(domanda)?.alternative ?? [] }

    /// Frasi in cui il modello dichiara azioni compiute o percezioni, o se ne lava le mani.
    static func suonaFalsato(_ text: String) -> Bool {
        let low = text.lowercased()
        let dichiarate = ["ho aperto", "ho cercato", "ho controllato", "ho stampato", "ho avviato", "ho trovato",
                          "ho visto", "ho guardato", "ho eseguito", "ho messo", "ho salvato", "ho inviato",
                          "ho letto", "ho alzato", "ho abbassato", "l'ho aperto", "l'ho trovato", "ora apro"]
        let percepite = ["vedo che", "lo vedo", "è attivo e visibile", "risulta aperto", "sul tuo schermo",
                         "la pagina chrome mostra", "lo schermo mostra", "posso vedere", "come vedi"]
        let rimandi = ["apri youtube", "vai su ", "digita ", "puoi aprire", "prova ad aprire", "esegui tu",
                       "devi digitare", "apri il browser", "apri la pagina"]
        let scuse = ["non ho accesso a internet", "non ho accesso internet", "non ho internet",
                     "non posso navigare", "non ho strumenti per cercare", "non posso cercare online",
                     "senza accesso a internet"]
        return dichiarate.contains(where: low.contains)
            || percepite.contains(where: low.contains)
            || rimandi.contains(where: low.contains)
            || scuse.contains(where: low.contains)
    }

    private func turns() -> [ChatTurn] {
        var prompt = JarvisCore.systemPrompt()
        // La nota finisce nel prompt di testa: i messaggi system a meta' storia
        // mandano qwen fuori di testa e si mette a ripetere le istruzioni.
        if !notaMemoria.isEmpty { prompt += "\n\nNOTA DI QUESTO GIRO: \(notaMemoria)" }
        if !nudge.isEmpty { prompt += "\n\nATTENZIONE: \(nudge)" }
        return [ChatTurn(role: "system", content: prompt)] + history
    }

    private func trim() {
        while history.count > maxTurns { history.removeFirst() }
        while let first = history.first, first.role == "tool" { history.removeFirst() }
    }

    private static func decode(_ s: String) -> [String: Any] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = t.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
}
