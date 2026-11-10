import Foundation
import EventKit

/// Jarvis che si prende cura di una chat: legge, risponde, aspetta la risposta e
/// risponde ancora. l'utente lo usa cosi: «rispondi a papi» / «pensaci tu».
///
/// Regole sue che valgono qui:
/// - il testo lo scrive lui, non chiede all'utente la frase;
/// - niente parole d'amore (quelle le scrive l'utente a mano);
/// - se in gioco c'e' un impegno, prima guarda il calendario;
/// - ogni messaggio partito viene scritto nella chat di Jarvis, cosi' lui sa cosa
///   e' stato detto senza dover aprire Messaggi.
enum Conversazione {

    /// Risponde a una persona e continua per un po', da solo.
    @MainActor
    static func prendi(a: String, scopo: String, giri: Int = 3, aspettare: TimeInterval = 70) async -> String {
        guard !a.trimmingCharacters(in: .whitespaces).isEmpty else { return "Dimmi con chi devo parlare." }
        var resoconto: [String] = []
        var ultimoId = Messaggi.ultimoId()

        for giro in 1...max(1, min(giri, 5)) {
            let cronologia = Messaggi.cronologiaPer(a, limite: 8)
            guard !cronologia.isEmpty, !cronologia.lowercased().contains("non trovo messaggi") else {
                return "Non riesco a leggere la conversazione con \(a): \(cronologia.prefix(120))"
            }
            GuardiaMessaggio.haLettoChat = true
            GuardiaMessaggio.segnalaInvito(cronologia)

            let risposta = await componi(chronologia: cronologia, scopo: scopo, persona: a, giaDetto: resoconto)
            let pulita = Agent.pulisciRisposta(risposta).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pulita.isEmpty else {
                resoconto.append("giro \(giro): non sono riuscito a comporre la risposta")
                break
            }
            if let bloccato = LimitiMessaggio.verifica(pulita, destinatario: a) {
                resoconto.append("giro \(giro): \(Agent.pulisciRisposta(bloccato))")
                break
            }
            let esito = await Messaggi.inviaConTastiera(a: a, testo: pulita, invio: true)
            resoconto.append("giro \(giro) — scritto da me: \u{201c}\(pulita.prefix(180))\u{201d} → \(Agent.pulisciRisposta(esito).prefix(120))")
            JarvisCore.shared.notaSenzaVoce("Conversazione con \(a): \(pulita.prefix(200))")
            if esito.uppercased().contains("NON INVIATO") { break }

            guard giro < giri else { break }
            // aspetto che risponda: controllo l'archivio, non lo schermo
            var nuovoTesto = ""
            let scadenza = Date().addingTimeInterval(aspettare)
            while Date() < scadenza {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let nuovo = Messaggi.daAnnunciare(dopoId: ultimoId).first(where: { Anagrafica.stessoNumero($0.chi, a)
                    || Memory.senzaAccenti($0.chi).contains(Memory.senzaAccenti(a)) }) {
                    nuovoTesto = nuovo.testo
                    ultimoId = max(ultimoId, nuovo.id)
                    break
                }
            }
            if nuovoTesto.isEmpty {
                resoconto.append("non ha risposto entro \(Int(aspettare)) secondi: mi fermo qui")
                break
            }
            resoconto.append("\(a) ha risposto: \u{201c}\(nuovoTesto.prefix(160))\u{201d}")
        }
        return resoconto.joined(separator: "\n")
    }

    /// Il testo della risposta, scritto nel tono dell'utente.
    @MainActor
    private static func componi(chronologia: String, scopo: String, persona: String, giaDetto: [String]) async -> String {
        let sistema = """
        Sei Jarvis che scrive AL POSTO di \(Identita.nome) nella chat con \(persona).
        Regole: italiano da ragazzo, breve (2-3 frasi), del tu, niente emoji a raffica, niente formalita'.
        Puoi mettere una parolaccia se ci sta. MAI parole d'amore (ti amo, amore, tesoro, abbracci):
        quelle le scrive \(Identita.nome) a mano, e se servono tu dici che glielo fai scrivere a lui.
        Se ti serve un dato (orari, compiti, meteo) non inventare: dillo con una frase onesta.
        \(scopo.isEmpty ? "Rispondi in modo naturale a quello che ha scritto per ultimo." : "Obiettivo della conversazione: \(scopo)")
        \(LimitiMessaggio.permesso)
        """
        var richiesta = "Ecco la conversazione (l'ultima riga e' il suo messaggio):\n\(chronologia.prefix(2200))"
        if !giaDetto.isEmpty {
            richiesta += "\n\nCose che hai gia' mandato tu in questa conversazione:\n" + giaDetto.joined(separator: "\n")
        }
        richiesta += "\n\nScrivi SOLO il testo del messaggio da mandare, senza virgolette e senza spiegare cosa fai."
        let giri = [ChatTurn(role: "system", content: sistema), ChatTurn(role: "user", content: richiesta)]
        var accumulato = ""
        if let risposta = try? await Brain.shared.stream(turns: giri, tools: []) { pezzo in accumulato += pezzo } {
            accumulato = risposta.text
        }
        let fuori = accumulato.trimmingCharacters(in: .whitespacesAndNewlines)
        return fuori.isEmpty ? accumulato : fuori
    }
}

extension Tools {
    /// `conversazione`: prende in mano una chat.
    @MainActor static func conversazioneSkill(_ args: [String: Any]) async -> String {
        let a = { (k: String) -> String in (args[k] as? String) ?? "" }
        switch a("azione") {
        case "prendi":
            let giri = Int(a("giri").filter { $0.isNumber }) ?? 3
            return await Conversazione.prendi(a: a("a"), scopo: a("scopo"), giri: giri)
        default:
            return "Azioni: prendi (con a= e, se serve, scopo= e giri=)."
        }
    }
}
