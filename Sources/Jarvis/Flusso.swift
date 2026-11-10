import Foundation

/// Spezza in frasi il testo che **ancora non è finito**.
///
/// È il pezzo che porta Jarvis sui 3-8 secondi invece che sotto i due: tutti gli
/// assistenti aperti (e il Jarvis di ieri sera) aspettano che il modello abbia
/// scritto l'intera risposta prima di aprire bocca. Qui invece la prima frase parte
/// mentre qwen3 sta ancora componendo la seconda, e il tempo che l'utente sente non
/// è più "quanto scrive il modello" ma "quanto ci mette a scrivere una riga".
///
/// Funzione pura apposta: si prova nel `--test` senza accendere il microfono né il
/// modello, e senza aspettare niente.
struct DivisoreDiFrasi {
    /// Sotto questa misura una frase non viene detta da sola: "Sì." sveglierebbe piper
    /// (processo + WAV + afplay) per tre caratteri. Quelle restano in coda e si dicono
    /// con `chiudi()`, insieme a quello che avanza alla fine della risposta.
    static let minimoPerDire = 14

    /// Il testo consegnato fin qui: serve a capire cosa è nuovo nel parziale.
    private var giaVisto = ""
    /// Pezzo di frase non ancora chiuso.
    private var resto = ""
    /// Pari = fuori da un blocco di codice, dispari = dentro: il codice non si legge
    /// a voce (e tra i backtick il testo è pieno di punti e parentesi).
    private var dentroIlCodice = false
    /// Se l'ultimo carattere visto era l'inizio di una ```
    private var backtick = 0

    private(set) var consegnate = 0

    /// `testoFinQui` è tutto quello che il modello ha scritto sinora: `Agent` passa il
    /// parziale accumulato, non il singolo pezzo. Se per qualche motivo il testo riparte
    /// da capo (una nota di servizio azzera il fumetto) si riparte anche qui, invece di
    /// dire metà cosa e metà l'altra.
    mutating func appenda(_ testoFinQui: String) -> [String] {
        let nuovo: String
        if testoFinQui.hasPrefix(giaVisto) {
            nuovo = String(testoFinQui.dropFirst(giaVisto.count))
        } else {
            nuovo = testoFinQui
            resto = ""
            dentroIlCodice = false
        }
        giaVisto = testoFinQui
        guard !nuovo.isEmpty else { return [] }

        var fuori: [String] = []
        var i = nuovo.startIndex
        while i < nuovo.endIndex {
            let c = nuovo[i]

            // ``` può arrivare spezzato tra due parziali: si contano i backtick di fila
            if c == "`" {
                backtick += 1
                if backtick == 3 {
                    dentroIlCodice.toggle()
                    backtick = 0
                }
                if !dentroIlCodice { resto.append(c) }
                i = nuovo.index(after: i)
                continue
            }
            backtick = 0

            if dentroIlCodice {
                // dentro un blocco di codice non si dice niente, ma il separatore sì:
                // serve per non appendere la prosa che viene dopo al blocco
                if c == "\n" { resto.append(" ") }
                i = nuovo.index(after: i)
                continue
            }

            let precedente = resto.last          // serve per capire se "64.5" e' un numero
            resto.append(c)

            // Due confini: un punto/.!?. seguito da spazio, e il capo — le risposte del
            // modello vengono fuori a righe, e una riga finita e' una frase finita
            let confine = (c == "\n") || Self.chiudeFrase(nuovo, dopo: i, prima: precedente)
            if confine, Self.puòEssereDetta(resto) {
                fuori.append(Self.pulisci(resto))
                resto = ""
            }
            i = nuovo.index(after: i)
        }
        consegnate += fuori.count
        return fuori.filter { !$0.isEmpty }
    }

    /// Quello che resta quando la risposta è finita: anche una frase corta o senza
    /// punto finale va detta, è l'ultima cosa che l'utente sente.
    mutating func chiudi() -> [String] {
        giaVisto = ""
        let avanzo = Self.pulisci(resto)
        resto = ""
        dentroIlCodice = false
        consegnate += avanzo.isEmpty ? 0 : 1
        return avanzo.isEmpty ? [] : [avanzo]
    }

    /// Vero quando la frase è finita: un punto esclamativo/d'interrogazione chiude
    /// sempre, il punto chiude solo se non è un decimale ("64.5 giga") e se dopo c'è
    /// spazio, a capo o la fine.
    ///
    /// `prima` è il carattere precedente **presezo dal resto della frase**, non letto
    /// dentro `testo`: il frammento può cominciare proprio sul punto, e in quel caso
    /// `index(before:)` sull'inizio della stringa va fuori di dov'è e schianta il
    /// processo (successo al primo `--latenza` di stasera).
    static func chiudeFrase(_ testo: String, dopo i: String.Index, prima: Character?) -> Bool {
        let c = testo[i]
        guard ".!?".contains(c) else { return false }
        let dopo = testo.index(after: i)
        if c == "." {
            // "1." dentro un numero: se prima o dopo c'è una cifra non è una fine
            if let p = prima, p.isNumber, dopo < testo.endIndex, testo[dopo].isNumber { return false }
        }
        if dopo >= testo.endIndex { return true }
        return testo[dopo].isWhitespace
    }

    static func puòEssereDetta(_ frammento: String) -> Bool {
        pulisci(frammento).count >= minimoPerDire
    }

    private static func pulisci(_ t: String) -> String {
        t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
