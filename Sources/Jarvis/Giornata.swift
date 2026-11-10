import Foundation

/// «Facciamo il punto» / «la giornata»: il briefing che l'utente ha chiesto il
/// 2026-10-17 e che non era mai stato fatto.
///
/// Scelta di progettazione importante, e non e' estetica: **non passa dal modello**.
/// Aggiungi uno strumento nuovo e qwen3:8b comincia a sbagliare le scelte (misurato il
/// 2026-10-20: con lo strumento `app` in piu' la prova di comprensione scendeva da 25/25
/// a 17/27). Qui invece la frase si riconosce, i sei controlli veri partono in parallelo,
/// e il testo che esce e' fatto di numeri letti — non di una risposta scritta a memoria.
/// Con un vantaggio pure sulla batteria: niente giri di modello, solo i comandi.
enum Giornata {
    static let inneschi = ["facciamo il punto", "fammi il punto", "il punto della giornata",
                           "la giornata", "che giornata e'", "riassunto della giornata",
                           "punto della situazione", "come e' la giornata"]

    /// Vero se la frase e' IL briefing. Corta e stretta di proposito: "come e' andata la
    /// giornata ieri" deve restare una domanda al modello, non un briefing a vuoto.
    static func innesco(_ testo: String) -> Bool {
        // la misura la prende dalla frase COM'E' DETTA, non dalla versione senza spazi:
        // senza spazi "la giornata oggi e' stata una giornata infinita" e' corta quanto
        // "la giornata" e faceva partire un briefing fuori posto (errore preso in test)
        let cruda = testo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cruda.count <= 34 else { return false }
        let basso = InventarioApp.senzaAccenti(cruda)
        return inneschi.contains { InventarioApp.senzaAccenti($0) == basso }
    }

    private static func pezzo(_ t: String) -> String {
        String(t.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(3).joined(separator: "\n")
            .prefix(320))
    }

    /// I sei pezzi, tutti in parallelo. Uno che non risponde non ferma il resto:
    /// nel resoconto compare la riga "non lo so", che e' piu' utile di un buco.
    @MainActor static func punto() async -> String {
        async let meteo = Tools.shared.run("meteo", Identita.citta.map { ["citta": $0] } ?? [:])
        async let orario = Tools.shared.run("leggi_orario", ["giorno": "oggi"])
        async let domani = Tools.shared.run("leggi_orario", ["giorno": "domani"])
        async let compiti = Tools.shared.run("compiti", ["azione": "lista"])
        async let f1 = Tools.shared.run("f1", ["azione": "prossima"])
        async let mac = Tools.shared.run("sistema", ["azione": "spazio"])
        async let batteria = Tools.shared.run("sistema", ["azione": "batteria"])
        async let pi = Tools.shared.run("raspberry", ["azione": "stato"])

        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE HH:mm"
        var righe: [String] = ["PUNTO — " + f.string(from: Date())]

        func aggiungi(_ titolo: String, _ valore: String) {
            let v = pezzo(valore)
            let pulito = v.isEmpty || v.hasPrefix("⚠️") || v.lowercased().contains("non riesco")
                || v.lowercased().contains("non riesco") || v.count < 4 ? "non ho potuto leggerlo" : v
            righe.append("\(titolo): \(pulito)")
        }

        aggiungi("Meteo", await meteo)
        let oggi = await orario
        aggiungi("Oggi a scuola", oggi)
        let dm = await domani
        // il domani si dice solo se porta qualcosa di diverso dall'oggi
        if !dm.isEmpty, dm != oggi { aggiungi("Domani", dm) }
        aggiungi("Compiti", await compiti)
        aggiungi("F1", await f1)
        aggiungi("Mac", (await mac) + " | " + (await batteria))
        aggiungi("Raspberry", await pi)
        return righe.joined(separator: "\n")
    }
}
