import Foundation

/// Chi sta usando Jarvis.
///
/// Prima il nome del padrone di casa era scritto **94 volte dentro il binario** (e
/// la sua città 7, l'host del Raspberry 5): uno che scaricava Jarvis si trovava un
/// assistente che lo chiamavall'utente e sapeva dove abita un altro. Adesso non c'è
/// più niente di nessuno nel programma: nome, città e host del Raspberry si leggono
/// da tre file in `~/.jarvis/`, e finché quei file non ci sono le frasi restano
/// generiche e gli strumenti che ne hanno bisogno lo dicono invece di indovinare.
///
/// Chi installa Jarvis si costruisce la memoria da solo: `profilo.md`, `compiti.md`,
/// `orario.md` e `cose.txt` nascono vuoti sul suo Mac (`AppPaths.prepare()` crea solo
/// le cartelle, non copia nessun dato di chicchessia).
enum Identita {
    /// Letto una volta all'avvio: i file cambiano raramente e il prompt si costruisce
    /// a ogni giro.
    private static let grezzo: [String: String] = {
        var letto: [String: String] = [:]
        for file in ["nome.txt", "citta.txt", "raspberry.txt"] {
            let url = AppPaths.jarvisRoot.appendingPathComponent(file)
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                letto[file] = raw.split(whereSeparator: { $0.isNewline }).first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            } else {
                letto[file] = ""
            }
        }
        return letto
    }()

    private static func valore(_ file: String) -> String { grezzo[file] ?? "" }

    /// Il nome dentro una frase. "chi usa Jarvis" regge anche dopo una preposizione
    /// ("l'assistente di chi usa Jarvis", "chi usa Jarvis ha chiesto..."), e non e'
    /// il nome di nessuno.
    static var nome: String { valore("nome.txt").isEmpty ? "chi usa \(Marca.nome)" : valore("nome.txt") }

    /// Il nome nudo, per i saluti e per l'intestazione: "Ciao" + "tu" suona meglio
    /// di "Ciao l'utente".
    static var nomeBreve: String { valore("nome.txt").isEmpty ? "tu" : valore("nome.txt") }

    /// La città da dare al meteo. `nil` quando non è configurata: in quel caso lo
    /// strumento deve dirlo, non tirare a indovinare la città di chi ha scritto il codice.
    static var citta: String? { valore("citta.txt").isEmpty ? nil : valore("citta.txt") }

    /// Come si chiama la città nel prompt e nei pulsanti.
    static var cittaInFrase: String { citta ?? "la tua città" }

    /// L'host del Raspberry: `nil` = non configurato, e lo strumento risponde di quello.
    static var raspberry: String? { valore("raspberry.txt").isEmpty ? nil : valore("raspberry.txt") }

    /// Vero quando non c'è ancora niente: la prima cosa da fare è chiedere il nome.
    static var daConfigurare: Bool { valore("nome.txt").isEmpty }

    /// La riga che finisce in cima al prompt quando l'utente non si è ancora presentato.
    /// Dice anche dove scrivere, così la memoria se la costruisce da sola al primo giro.
    static let notaPrimoAvvio = """
    NON HAI ANCORA UNA MEMORIA: non conosci il nome di chi ti parla, la sua città e \
    non c'è nessun profilo. Alla prima risposta chiedigli come vuole che lo chiami, \
    poi salva il nome in ~/.jarvis/nome.txt (una riga sola) e le sue preferenze in \
    ~/.jarvis/profilo.md. Se ti chiede il meteo e non sai dove abita, chiediglielo: \
    non tirare a indovinare una città.
    """
}
