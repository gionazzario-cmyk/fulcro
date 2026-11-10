import Foundation

/// Che passo deve tenere l'app, in base a corrente e calore.
///
/// La sua regola, detta il 2026-10-21: **a batteria consuma zero**, e **all'alimentatore
/// scalda il meno possibile**. "Zero" non è una cifra che si ottiene dimezzando
/// l'hardware (i core non si spengono da un'app: si vedano i numeri in PROGETTO-2.md
/// §4-quater): si ottiene **non svegliandosi**. I timer che giravano ogni 5 e 20 secondi
/// anche a staccato facevano esattamente il contrario — controllavano lo stato dentro la
/// callback, cioè dopo essersi già svegliati.
///
/// Qui la decisione è una funzione pura: si può provare senza staccare il cavo.
enum Risparmio {
    /// Cosa vuole l'utente quando il Mac è staccato. Si sceglie con
    /// `~/.jarvis/passo.txt`: una riga tra `dormi`, `esci`, `lavora`.
    ///
    /// Il file si chiama `passo.txt` e NON `batteria.txt`: quello esiste già dal
    /// 2026-10-19 e contiene `gemini`/`locale` — cioè *dove* ragiona a batteria, non
    /// *quanto gira* l'app. Leggere lo stesso file voleva dire che una domanda sul
    /// cervello avrebbe spento la sorveglianza.
    enum Modo: String {
        case dormi      // default: niente sorveglianza, si sveglia solo quando lo chiami
        case esci       // l'app proprio si chiude (consumo zero vero)
        case lavora     // opt-in: continua come alla corrente
    }

    static var fileScelta: URL { AppPaths.jarvisRoot.appendingPathComponent("passo.txt") }

    static var modalita: Modo {
        guard let raw = try? String(contentsOf: fileScelta, encoding: .utf8) else { return .dormi }
        return Modo(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .dormi
    }

    /// La scelta scritta a voce (strumento `cervello`) o dalla barra laterale.
    static func imposta(_ nuovo: Modo) -> String {
        do { try nuovo.rawValue.write(to: fileScelta, atomically: true, encoding: .utf8) }
        catch { return "Non sono riuscito a scrivere \(fileScelta.path): \(error.localizedDescription)" }
        switch nuovo {
        case .dormi: return "A corrente staccata \(Marca.nome) dorme: niente sorveglianza, niente timer, "
            + "niente anelli che girano. ⌥ Spazio lo sveglia per la domanda che fai."
        case .esci: return "A corrente staccata \(Marca.nome) si chiude proprio: consumo zero. "
            + "Riattacca e riparte da solo."
        case .lavora: return "A corrente staccata \(Marca.nome) continua a lavorare: sorveglianza e letture "
            + "restano accese, a passo lento. E' la scelta che costa batteria."
        }
    }

    static func descrizione(_ m: Modo) -> String {
        switch m {
        case .dormi: return "dormi (default: zero sveglie, ⌥ Spazio lo risveglia)"
        case .esci: return "esci (l'app si chiude)"
        case .lavora: return "lavora (continua, a passo lento)"
        }
    }

    struct Piano: Equatable {
        var sorveglianza = true      // orecchio messaggi, watchdog compiti, riunioni
        var inventario = true        // conto dei bundle ogni 10 minuti
        var diagnostica = true       // i timer che leggono CPU e RAM
        var diagnosticaLenta = false // ...ma a passo lungo (30 s invece di 5)
        var animazioni = true        // gli anelli che girano
        var server = true            // la pagina dell'iPad in ascolto sulla rete
        var siChiude = false         // l'app si autochiude
        var priorita: DispatchQoS = .utility
        var perche: String = ""

        static let attivo = Piano()
    }

    /// La regola, separata da tutto il resto: è questa che ci sono i controlli nel test.
    /// - Parameter termica: lo stato del calore letto da `ProcessInfo.thermalState`.
    /// - Parameter risparmioSistema: la Modalità Risparmio Energetico di macOS, che
    ///   Apple la fa dal livello del sistema (frequenza CPU, luminosità, ventola) e noi
    ///   non possiamo nemmeno impostare: possiamo solo **ascoltarla**.
    static func decidi(carica: Bool, termica: ProcessInfo.ThermalState,
                       risparmioSistema: Bool, modo: Modo) -> Piano {
        let calda = termica == .serious || termica == .critical

        if !carica {
            switch modo {
            case .esci:
                return Piano(sorveglianza: false, inventario: false, diagnostica: false,
                             animazioni: false, server: false, siChiude: true,
                             priorita: .background,
                             perche: "a batteria: l'app si chiude (passo.txt = esci)")
            case .dormi:
                return Piano(sorveglianza: false, inventario: false, diagnostica: false,
                             animazioni: false, server: false, priorita: .background,
                             perche: "a batteria: dorme, ⌥ Spazio la sveglia")
            case .lavora:
                return Piano(sorveglianza: true, inventario: false, diagnostica: true,
                             diagnosticaLenta: true, animazioni: true, server: false,
                             priorita: .background,
                             perche: "a batteria: lavori scelti da te (passo.txt = lavora)")
            }
        }

        // All'alimentatore: si lavora, ma se scotta si tira indietro il lavoro
        // volontario e si rallenta quello di misura.
        if calda || risparmioSistema {
            return Piano(sorveglianza: true, inventario: false, diagnostica: true,
                         diagnosticaLenta: true, animazioni: true, server: true,
                         priorita: .utility,
                         perche: calda
                            ? "caldo: niente scansione app, letture a passo lento"
                            : "risparmio energetico del sistema: passo lento")
        }
        return Piano(priorita: .utility, perche: "corrente: tutto attivo")
    }

    /// Lo stato del Mac letto insieme, in un punto solo. Non serve il main actor:
    /// IOKit, thermalState e la Modalità Risparmio Energetico si leggono da qualsiasi
    /// filo, e lo strumento `cervello` deve poter rispondere anche da un Task.
    static func leggi() -> Piano {
        decidi(carica: Alimentazione.inCarica,
               termica: ProcessInfo.processInfo.thermalState,
               risparmioSistema: ProcessInfo.processInfo.isLowPowerModeEnabled,
               modo: modalita)
    }
}
