import Foundation
import CoreGraphics
import AVFoundation
import ApplicationServices
import AppKit

/// Cosa puo fare davvero il Mac adesso, misurato e non supposto.
/// Serve perche' altrimenti Jarvis si "dimentica" i permessi e li chiede ogni volta.
enum Capacita {
    /// True se il permesso Registrazione schermo e gia' stato dato all'app.
    static var schermo: Bool { CGPreflightScreenCaptureAccess() }

    /// True se il microfono e' autorizzato (senza farlo chiedere).
    static var microfono: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// True se Jarvis ha "Accesso completo al disco": si prova con un file che
    /// macOS protegge, perche' il database dei messaggi e' li' che si vede.
    /// `isReadableFile` non basta: guarda solo i permessi POSIX, e chat.db e' 644,
    /// quindi dice "dato" anche quando il blocco TCC c'e' ancora. Qui si apre davvero.
    static var discoCompleto: Bool {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Messages/chat.db")
        guard let maniglia = try? FileHandle(forReadingFrom: url) else { return false }
        let pezzo = try? maniglia.read(upToCount: 1)
        try? maniglia.close()
        return pezzo?.isEmpty == false
    }

    /// Accessibilita': serve solo per premere tasti, cioe' per l'invio automatico.
    static var accessibilita: Bool { AXIsProcessTrusted() }

    /// Chiede il permesso una volta sola; dopo, il Mac se lo ricorda.
    static func chiediSchermo() -> Bool {
        if schermo { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Fa comparire Jarvis nella lista di Accessibilita' (senza questo non appare mai).
    @discardableResult
    static func chiediAccessibilita() -> Bool {
        if accessibilita { return true }
        let chiave = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([chiave: true] as CFDictionary)
    }

    static func apriPannello(_ cosa: String) -> String {
        let url: String
        switch cosa.lowercased() {
        case "disco", "accesso completo", "full disk":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case "accessibilita", "accessibilitá", "tasti":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case "schermo", "registrazione":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case "microfono":
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        default:
            url = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }
        guard let u = URL(string: url) else { return "Pannello non trovato." }
        NSWorkspace.shared.open(u)
        return "Ho aperto la schermata giusta nelle Impostazioni di Sistema: cerca \(Marca.nome) e attiva la levetta, poi dimmi «riavviati»."
    }

    /// Dopo un permesso nuovo il binario in esecuzione deve ripartire: TCC si legge all'avvio.
    static func statoPermessi() -> String {
        var righe = ["Registrazione schermo: \(schermo ? "dato" : "MANCANTE")",
                     "Microfono: \(microfono ? "dato" : "MANCANTE")",
                     "Accesso completo al disco: \(discoCompleto ? "dato" : "MANCANTE (serve per leggere i messaggi)")",
                     "Accessibilita' (invio automatico): \(accessibilita ? "data" : "MANCANTE")"]
        if righe.contains(where: { $0.contains("MANCANTE") }) {
            righe.append("Dopo aver attivato un permesso serve riavviare \(Marca.nome).")
        }
        return righe.joined(separator: "\n")
    }

    static func rigaStato() -> String {
        var parti: [String] = []
        parti.append(schermo ? "schermo: PERMESSO, puoi usare leggi_schermo e schermo senza chiedere niente"
                             : "schermo: NEGATO, non offerirlo: di' a \(Identita.nome) una riga sola su come attivarlo")
        parti.append(microfono ? "microfono: permesso" : "microfono: non ancora autorizzato")
        parti.append(discoCompleto
            ? "accesso al disco: PERMESSO, messaggi(azione:ultimi) e mail funzionano"
            : "accesso al disco: NEGATO, iMessage non si legge: di' a \(Identita.nome) di dare Accesso completo al disco a \(Marca.nome)")
        parti.append(accessibilita
            ? "accessibilita': PERMESSA, puoi premere Invio per l'invio automatico"
            : "accessibilita': NEGATA, per l'invio automatico usa permessi azione=chiedi_accessibilita")
        return "Permessi gia' controllati adesso (" + dateBreve() + "): " + parti.joined(separator: "; ") +
            ". Questi stati sono veri: non chiedere il permesso che hai gia', non dire di non poter fare quello che puoi fare."
    }

    private static func dateBreve() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
