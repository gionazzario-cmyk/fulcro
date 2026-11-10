import Foundation

/// Il marchio con cui Jarvis si presenta al mondo.
///
/// Il nome "J.A.R.V.I.S." viene dal personaggio di Marvel: sul Mac di chi l'ha
/// scritto resta il suo nomignolo affettivo, ma **in una pagina pubblica da cui la
/// gente scarica un'app non ha senso esporsi a un marchio che non è il proprio**.
/// Quindi il nome visibile non è più cablato dappertutto: si legge da
/// `~/.jarvis/marca.txt` e il default (quello che trova chi installa l'app da zero)
/// è **Fulcro**: perno, punto d'appoggio, e anche il nome onesto di quel cerchio che
/// gira al centro della finestra.
///
/// Chi ha già `marca.txt` = "Jarvis" non vede cambiare niente: cambia solo il nome
/// con cui l'app si presenta, non i comandi che riconosce.
enum Marca {
    static let nome: String = {
        let url = AppPaths.jarvisRoot.appendingPathComponent("marca.txt")
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            let primo = raw.split(whereSeparator: { $0.isNewline }).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !primo.isEmpty { return primo }
        }
        return "Fulcro"
    }()

    /// Il nome tutto maiuscolo spaziato, quello dell'intestazione.
    static var marchio: String { nome.uppercased().map(String.init).joined(separator: ".") + "." }

    /// "Fulcro" e "Jarvis" hanno lo stesso numero di sillabe? Non serve: questo è il
    /// nome corto da dire a voce, usato nei saluti e nei pulsanti.
    static var breve: String { nome }
    /// Il codice che dimostra che Fulcro è installato su questo Mac: serve per
    /// scrivere nei commenti del sito. Otto caratteri scelti senza O/0 e I/1, così
    /// si possono dettare a voce. Nasce la prima volta che l'app parte e poi resta
    /// lo stesso: è in `~/.jarvis/codice-app.txt`, ed è l'unica cosa dell'installazione
    /// che finisce pubblica (non dice chi sei, dice che hai l'app).
    static var codiceApp: String {
        let url = AppPaths.jarvisRoot.appendingPathComponent("codice-app.txt")
        if let letto = try? String(contentsOf: url, encoding: .utf8) {
            let pulito = letto.trimmingCharacters(in: .whitespacesAndNewlines)
            if pulito.count == 8 { return pulito }
        }
        let alfabeto = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var nuovo = ""
        for _ in 0..<8 { nuovo.append(alfabeto[Int.random(in: 0..<alfabeto.count)]) }
        try? FileManager.default.createDirectory(at: AppPaths.jarvisRoot, withIntermediateDirectories: true)
        try? nuovo.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return nuovo
    }

}
